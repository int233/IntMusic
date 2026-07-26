part of '../intmusic_client.dart';

extension _DashboardEventRouter on _CoreDashboardState {
  void _handleCoreEvent(dynamic message, {required int connectionGeneration}) {
    if (message is! String) {
      return;
    }
    if (connectionGeneration != _eventConnectionGeneration) {
      return;
    }

    try {
      final envelope = _asMap(jsonDecode(message));
      final eventType = envelope['type']?.toString();
      final payload = envelope['payload'];

      if (eventType == 'connection.pong') {
        _eventLastPongAt = DateTime.now();
        return;
      }

      if (eventType == 'renderer.resync_required') {
        unawaited(_restartEventStream('renderer_resync_required'));
        return;
      }

      if (eventType == 'connection.snapshot_required') {
        unawaited(_refreshZonesSilently());
        unawaited(_refreshPlaybackQueue());
        return;
      }

      if (eventType == 'renderer.command') {
        final commandEnvelope = _asMap(payload);
        if (commandEnvelope['renderer_id']?.toString() != _clientId) {
          return;
        }
        final command = _asMap(commandEnvelope['command']);
        final targetOutputId = command['target_output_id']?.toString();
        if (!_isClientOutputId(targetOutputId)) {
          return;
        }
        final issuedAt = _rendererCommandIssuedAt(command);
        final ageMs = issuedAt == null
            ? null
            : DateTime.now().toUtc().difference(issuedAt).inMilliseconds;
        ClientLog.event(
          'renderer.command.received',
          data: <String, Object?>{
            'action': command['action']?.toString(),
            'command_id': command['command_id']?.toString(),
            'sequence': _intValue(command['sequence']),
            'issued_at': issuedAt?.toIso8601String(),
            'age_ms': ageMs,
            'expires_after_ms': _intValue(command['expires_after_ms']),
            'origin_client_id': command['origin_client_id']?.toString(),
            'intent_id': command['intent_id']?.toString(),
            'track_id': _intValue(command['track_id']),
            'output_id': targetOutputId,
          },
        );
        if (_acceptRendererCommand(command)) {
          _enqueueRendererCommand(command, connectionGeneration);
        }
        return;
      }

      if ((eventType == 'playback.state_changed' ||
              eventType == 'playback.position') &&
          payload is Map) {
        final playback = payload.cast<String, dynamic>();
        if (!_acceptIncomingPlayback(playback)) {
          return;
        }
        _mutatePlayback(() {
          _mergePlaybackEvent(playback);
        });
        return;
      }

      if (eventType == 'playback.queue_changed' && payload is Map) {
        final queue = payload.cast<String, dynamic>();
        if (queue['zone_id']?.toString() == _activeZoneId()) {
          _mutatePlayback(() => _applyPlaybackQueue(queue));
          unawaited(
            _persistOverviewValues(<String, dynamic>{'playback_queue': queue}),
          );
        }
        return;
      }

      if (eventType == 'zone.volume_changed' && payload is Map) {
        final volume = payload.cast<String, dynamic>();
        final zoneId = volume['zone_id']?.toString();
        if (zoneId == null) {
          return;
        }
        _mutatePlayback(() {
          _zones = _zones
              .map((item) {
                final zone = (item as Map).cast<String, dynamic>();
                if (zone['id']?.toString() != zoneId) {
                  return zone;
                }
                return <String, dynamic>{
                  ...zone,
                  'volume': volume['volume'],
                  'muted': volume['muted'],
                  'volume_mode': volume['mode'],
                  'player_volume': volume['player_volume'],
                  'player_muted': volume['player_muted'],
                  'system_volume': volume['system_volume'],
                  'system_muted': volume['system_muted'],
                };
              })
              .toList(growable: false);
        });
      }
      if (eventType == 'distribution.created' ||
          eventType == 'distribution.updated') {
        unawaited(_refreshDistributionJobs());
        unawaited(_pollDistributionTasks());
      }
      if (eventType == 'library.changed' ||
          eventType == 'client.mutations_applied') {
        unawaited(_backgroundLibrarySync());
      }
      if (eventType == 'core.settings_changed') {
        unawaited(_refreshSettingsCache());
      }
    } catch (error, stackTrace) {
      ClientLog.error('renderer.event.invalid', error, stackTrace: stackTrace);
      if (mounted) {
        _mutate(() => _rendererStatus = 'Renderer event error');
      }
    }
  }

  bool _acceptRendererCommand(Map<String, dynamic> command) {
    final outputId = command['target_output_id']?.toString();
    if (!_isClientOutputId(outputId)) return false;

    final issuedAt = _rendererCommandIssuedAt(command);
    final ageMs = issuedAt == null
        ? null
        : DateTime.now().toUtc().difference(issuedAt).inMilliseconds;
    final configuredTtl = _intValue(command['expires_after_ms']);
    final effectiveTtl =
        configuredTtl ??
        (command['action']?.toString() == 'volume' ? 4000 : 8000);
    if (ageMs != null && ageMs > effectiveTtl + 2000) {
      _dropRendererCommand(
        command,
        'expired',
        extra: <String, Object?>{
          'age_ms': ageMs,
          'expires_after_ms': effectiveTtl,
          'legacy_ttl': configuredTtl == null,
        },
      );
      unawaited(_restartEventStream('expired_renderer_command'));
      return false;
    }

    final sequence = _intValue(command['sequence']) ?? 0;
    final previousSequence = _rendererCommandSequenceByOutput[outputId];
    final latestStateSequence = _playbackStateSequenceByZone[outputId];
    final previousIssuedAt = _latestRendererCommandIssuedAtByOutput[outputId];
    if (sequence <= 0 &&
        issuedAt != null &&
        previousIssuedAt != null &&
        !issuedAt.isAfter(previousIssuedAt)) {
      _dropRendererCommand(command, 'stale_legacy_timestamp');
      return false;
    }
    if (sequence > 0) {
      if (latestStateSequence != null && sequence < latestStateSequence) {
        _dropRendererCommand(command, 'stale_state_sequence');
        return false;
      }
      if (previousSequence != null && sequence <= previousSequence) {
        _dropRendererCommand(
          command,
          'stale_sequence',
          extra: <String, Object?>{'last_sequence': previousSequence},
        );
        return false;
      }
      if (previousSequence != null && sequence > previousSequence + 1) {
        ClientLog.event(
          'renderer.command.sequence_gap',
          level: 'warning',
          data: <String, Object?>{
            'output_id': outputId,
            'sequence': sequence,
            'last_sequence': previousSequence,
          },
        );
        unawaited(_restartEventStream('renderer_command_gap'));
        return false;
      }
      _rendererCommandSequenceByOutput[outputId!] = sequence;
    }

    if (!_rendererCommandMatchesLatestIntent(command)) {
      _dropRendererCommand(command, 'superseded_local_intent');
      return false;
    }
    if (issuedAt != null) {
      _latestRendererCommandIssuedAtByOutput[outputId!] = issuedAt;
    }
    return true;
  }

  bool _rendererCommandMatchesLatestIntent(Map<String, dynamic> command) {
    final outputId = command['target_output_id']?.toString();
    if (outputId == null) return true;
    final action = command['action']?.toString();
    final intentId = command['intent_id']?.toString();
    final originClientId = command['origin_client_id']?.toString();
    final latestIntent = action == 'volume'
        ? _latestVolumeIntentByZone[outputId]
        : _latestPlaybackIntentByZone[outputId];
    if (originClientId == _clientId &&
        intentId != null &&
        latestIntent != null) {
      return intentId == latestIntent;
    }

    // Compatibility with an older Core which does not echo origin/intent:
    // UUIDv7 still lets us reject a command issued before a newer local click.
    if (action != 'volume') {
      final localIntentAt = _latestPlaybackIntentAtByZone[outputId];
      final issuedAt = _rendererCommandIssuedAt(command);
      if (localIntentAt != null &&
          issuedAt != null &&
          issuedAt.isBefore(localIntentAt)) {
        return false;
      }
      if (localIntentAt != null &&
          issuedAt == null &&
          DateTime.now().toUtc().difference(localIntentAt) <
              const Duration(seconds: 10)) {
        final desired = _desiredTransportStateByZone[outputId];
        final commanded = _transportStateForAction(action);
        if (desired != null && commanded != desired) return false;
      }
    }
    return true;
  }

  String _transportStateForAction(String? action) => switch (action) {
    'pause' => 'paused',
    'stop' => 'stopped',
    _ => 'playing',
  };

  DateTime? _rendererCommandIssuedAt(Map<String, dynamic> command) {
    final explicit = DateTime.tryParse(
      command['issued_at']?.toString() ?? '',
    )?.toUtc();
    if (explicit != null) return explicit;
    final commandId = command['command_id']?.toString().replaceAll('-', '');
    if (commandId == null || commandId.length < 12) return null;
    final milliseconds = int.tryParse(commandId.substring(0, 12), radix: 16);
    if (milliseconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  void _dropRendererCommand(
    Map<String, dynamic> command,
    String reason, {
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    ClientLog.event(
      'renderer.command.dropped',
      level: 'warning',
      data: <String, Object?>{
        'reason': reason,
        'action': command['action']?.toString(),
        'command_id': command['command_id']?.toString(),
        'output_id': command['target_output_id']?.toString(),
        'sequence': _intValue(command['sequence']),
        'intent_id': command['intent_id']?.toString(),
        ...extra,
      },
    );
  }

  bool _acceptIncomingPlayback(Map<String, dynamic> playback) {
    final zoneId = playback['zone_id']?.toString();
    if (zoneId == null) return true;
    final sequence = _intValue(playback['command_sequence']);
    final previousSequence = _playbackStateSequenceByZone[zoneId];
    final commandSequence = _rendererCommandSequenceByOutput[zoneId];
    if (sequence != null &&
        commandSequence != null &&
        sequence < commandSequence) {
      return false;
    }
    if (sequence != null &&
        previousSequence != null &&
        sequence < previousSequence) {
      return false;
    }
    if (sequence != null &&
        sequence > 0 &&
        (previousSequence == null || sequence > previousSequence)) {
      _playbackStateSequenceByZone[zoneId] = sequence;
    }
    if (playback['origin_client_id']?.toString() == _clientId) {
      final intentId = playback['intent_id']?.toString();
      final latestIntent = _latestPlaybackIntentByZone[zoneId];
      if (intentId != null &&
          latestIntent != null &&
          intentId != latestIntent) {
        return false;
      }
    }
    return true;
  }

  void _enqueueRendererCommand(
    Map<String, dynamic> command,
    int connectionGeneration,
  ) {
    final outputId = command['target_output_id']?.toString();
    if (outputId == null) return;
    final action = command['action']?.toString();
    final operationGeneration = action == 'volume'
        ? _rendererOperationGenerationByOutput[outputId] ?? 0
        : (_rendererOperationGenerationByOutput[outputId] ?? 0) + 1;
    if (action != 'volume') {
      _rendererOperationGenerationByOutput[outputId] = operationGeneration;
    }
    final previous =
        _rendererCommandQueueByOutput[outputId] ?? Future<void>.value();
    final execution = previous.catchError((Object _) {}).then<void>((_) async {
      if (!mounted ||
          connectionGeneration != _eventConnectionGeneration ||
          !_rendererCommandStillExecutable(command)) {
        _dropRendererCommand(command, 'superseded_while_queued');
        return;
      }
      await _handleRendererCommand(command, operationGeneration);
    });
    late final Future<void> queued;
    queued = execution.whenComplete(() {
      if (identical(_rendererCommandQueueByOutput[outputId], queued)) {
        _rendererCommandQueueByOutput.remove(outputId);
      }
    });
    _rendererCommandQueueByOutput[outputId] = queued;
  }

  bool _rendererCommandStillExecutable(Map<String, dynamic> command) {
    if (!_rendererCommandMatchesLatestIntent(command)) return false;
    final issuedAt = _rendererCommandIssuedAt(command);
    if (issuedAt == null) return true;
    final ttl =
        _intValue(command['expires_after_ms']) ??
        (command['action']?.toString() == 'volume' ? 4000 : 8000);
    return DateTime.now().toUtc().difference(issuedAt).inMilliseconds <=
        ttl + 2000;
  }
}
