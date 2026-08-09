part of '../intmusic_client.dart';

/// Coordinates the revisioned v3 playback session protocol.
///
/// Queue presentation and legacy compatibility remain in
/// [dashboard_playback_queue.dart]; this extension owns session negotiation,
/// resume, idempotent command submission, and one-shot conflict rebasing.
extension _DashboardPlaybackSessionV3 on _CoreDashboardState {
  static const Duration _pendingPlaybackCommandTtl = Duration(seconds: 30);

  Future<void> _playQueueItem(int index, int trackId) async {
    if (_localPlaybackFallbackActive) {
      final agent = _restorePlaybackAgentQueue();
      if (index >= 0 && index < agent.items.length) {
        _selectPlaybackAgentItem(agent.items[index]);
      }
      await _playOfflineTrack(trackId);
      return;
    }

    final zoneId = _activeZoneId();
    final outputId = _clientOutputForZone(zoneId) ?? zoneId;
    var agent = _playbackAgentsByOutput.putIfAbsent(
      outputId,
      () => PlaybackAgent(outputId),
    );
    if (!agent.hasSession && await _refreshPlaybackSessionV3(zoneId: zoneId)) {
      agent = _playbackAgentsByOutput[outputId]!;
    }
    if (agent.hasSession && index >= 0 && index < agent.items.length) {
      final item = agent.items[index];
      final intentId = _beginPlaybackIntent(zoneId, 'play_queue_item');
      final localStarted = await _tryStartLocalPlayback(
        trackId,
        zoneId: zoneId,
        intentId: intentId,
      );
      if (localStarted) _selectPlaybackAgentItem(item);
      final playback = await _postPlaybackSessionActionV3(
        zoneId,
        <String, dynamic>{
          'type': 'play',
          'item_id': item.itemId,
          'position_ms': 0,
        },
        commandId: intentId,
      );
      if (mounted && playback != null) {
        _mutatePlayback(() => _applyPlayback(playback));
        return;
      }
      final legacyPlayback = await _playTrackOnZone(
        trackId,
        zoneId,
        tryLocalFastStart: false,
        intentId: intentId,
      );
      if (mounted && legacyPlayback != null) {
        _mutatePlayback(() => _applyPlayback(legacyPlayback));
      }
      return;
    }

    final playback = await _playTrackOnZone(trackId, zoneId);
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  Future<bool> _refreshPlaybackSessionV3({String? zoneId}) async {
    if (_localPlaybackFallbackActive) return false;
    final targetZoneId = zoneId ?? _activeZoneId();
    final outputId = _clientOutputForZone(targetZoneId) ?? targetZoneId;
    final agent = _playbackAgentsByOutput.putIfAbsent(
      outputId,
      () => PlaybackAgent(outputId),
    );
    try {
      final response = agent.hasSession
          ? _asMap(
              await _api.postControlJson(
                '/playback-v3/zones/${Uri.encodeComponent(targetZoneId)}/resume',
                <String, dynamic>{
                  'device_id': _clientId,
                  'session_id': agent.sessionId,
                  'known_epoch': agent.sessionEpoch,
                  'known_revision': agent.sessionRevision,
                  'after_cursor': agent.eventCursor,
                },
              ),
            )
          : <String, dynamic>{
              'snapshot': _asMap(
                await _api.getCriticalJson(
                  '/playback-v3/zones/${Uri.encodeComponent(targetZoneId)}/session',
                ),
              ),
            };
      final snapshot = _asMap(response['snapshot']);
      if (snapshot.isEmpty) return false;
      agent.restoreSession(snapshot);
      ClientLog.event(
        'playback.session_v3.restored',
        data: <String, Object?>{
          'zone_id': targetZoneId,
          'session_id': agent.sessionId,
          'epoch': agent.sessionEpoch,
          'revision': agent.sessionRevision,
          'event_cursor': agent.eventCursor,
          'replayed_events': (response['events'] as List?)?.length ?? 0,
        },
      );
      unawaited(_reconcilePendingPlaybackCommandsV3(zoneId: targetZoneId));
      return true;
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.session_v3.restore_failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{'zone_id': targetZoneId},
      );
      return false;
    }
  }

  Future<Map<String, dynamic>?> _postPlaybackSessionActionV3(
    String zoneId,
    Map<String, dynamic> action, {
    String? commandId,
    bool reconcilingPending = false,
  }) async {
    final outputId = _clientOutputForZone(zoneId) ?? zoneId;
    var agent = _playbackAgentsByOutput.putIfAbsent(
      outputId,
      () => PlaybackAgent(outputId),
    );
    if (!agent.hasSession) {
      if (!await _refreshPlaybackSessionV3(zoneId: zoneId)) return null;
      agent = _playbackAgentsByOutput[outputId]!;
    }
    for (var attempt = 0; attempt < 2; attempt += 1) {
      final activeCommandId = attempt == 0 && commandId != null
          ? commandId
          : _newPlaybackCommandId();
      if (attempt > 0 && commandId != null) {
        _latestPlaybackIntentByZone[zoneId] = activeCommandId;
        if (_locallyAppliedPlaybackIntents.contains(commandId)) {
          _locallyAppliedPlaybackIntents.add(activeCommandId);
        }
      }
      await _rememberPendingPlaybackCommandV3(
        zoneId: zoneId,
        commandId: activeCommandId,
        action: action,
      );
      try {
        final ack = _asMap(
          await _api.postControlJson(
            '/playback-v3/zones/${Uri.encodeComponent(zoneId)}/commands',
            agent.command(
              commandId: activeCommandId,
              originDeviceId: _clientId,
              action: action,
            ),
          ),
        );
        final status = agent.applyAck(ack);
        if (status == 'conflict' && attempt == 0 && !reconcilingPending) {
          await _forgetPendingPlaybackCommandV3(activeCommandId);
          ClientLog.event(
            'playback.session_v3.command_rebased',
            level: 'warning',
            data: <String, Object?>{
              'zone_id': zoneId,
              'command_id': activeCommandId,
              'error_code': ack['error_code']?.toString(),
            },
          );
          continue;
        }
        if (status != 'applied' && status != 'duplicate') {
          await _forgetPendingPlaybackCommandV3(activeCommandId);
          ClientLog.event(
            'playback.session_v3.command_conflict',
            level: 'warning',
            data: <String, Object?>{
              'zone_id': zoneId,
              'command_id': activeCommandId,
              'status': status,
              'error_code': ack['error_code']?.toString(),
            },
          );
          // A typed conflict/rejection confirms that Core did not apply the
          // command, so the compatibility route may safely handle it.
          return null;
        }
        await _forgetPendingPlaybackCommandV3(activeCommandId);
        final snapshot = _asMap(ack['snapshot']);
        final currentItemId = snapshot['current_item_id']?.toString();
        PlaybackAgentItem? currentItem;
        for (final item in agent.items) {
          if (item.itemId == currentItemId) {
            currentItem = item;
            break;
          }
        }
        return _withPlaybackTimestamp(<String, dynamic>{
          ...?_playback,
          'zone_id': zoneId,
          'state': snapshot['transport']?.toString() ?? 'stopped',
          'track_id': currentItem?.trackId,
          'position_ms': _intValue(snapshot['position_ms']) ?? 0,
          'queue_revision': agent.sessionRevision,
          'origin_client_id': _clientId,
          'intent_id': activeCommandId,
          '_v3_command_delivery': 'acknowledged',
        });
      } on HttpException catch (error, stackTrace) {
        ClientLog.error(
          'playback.session_v3.command_failed',
          error,
          stackTrace: stackTrace,
          data: <String, Object?>{
            'zone_id': zoneId,
            'command_id': activeCommandId,
            'action': action['type']?.toString(),
          },
        );
        final definitivelyUnsupported =
            error.message.contains('HTTP 404') ||
            error.message.contains('HTTP 405') ||
            error.message.contains('HTTP 422');
        if (definitivelyUnsupported) {
          await _forgetPendingPlaybackCommandV3(activeCommandId);
          return null;
        }
        // Once a v3 command was sent, falling through to the legacy endpoint
        // could execute next/previous twice if only the ACK was lost.
        return _pendingPlaybackProjectionV3(zoneId, activeCommandId);
      } catch (error, stackTrace) {
        ClientLog.error(
          'playback.session_v3.command_failed',
          error,
          stackTrace: stackTrace,
          data: <String, Object?>{
            'zone_id': zoneId,
            'command_id': activeCommandId,
            'action': action['type']?.toString(),
          },
        );
        return _pendingPlaybackProjectionV3(zoneId, activeCommandId);
      }
    }
    return _pendingPlaybackProjectionV3(
      zoneId,
      commandId ?? _newPlaybackCommandId(),
    );
  }

  bool _playbackSessionCommandAcknowledgedV3(Map<String, dynamic> playback) =>
      playback['_v3_command_delivery'] != 'pending';

  Map<String, dynamic> _pendingPlaybackProjectionV3(
    String zoneId,
    String commandId,
  ) {
    ClientLog.event(
      'playback.session_v3.command_pending',
      level: 'warning',
      data: <String, Object?>{'zone_id': zoneId, 'command_id': commandId},
    );
    return _withPlaybackTimestamp(<String, dynamic>{
      ...?_playback,
      'zone_id': zoneId,
      'state': _playback?['state']?.toString() ?? 'loading',
      'intent_id': commandId,
      '_v3_command_delivery': 'pending',
    });
  }

  void _restorePendingPlaybackCommandsV3(Object? value) {
    _pendingPlaybackCommandsV3.clear();
    final now = DateTime.now().toUtc();
    for (final raw in (value as List?) ?? const <dynamic>[]) {
      final command = _asMap(raw);
      final commandId = command['command_id']?.toString();
      final zoneId = command['zone_id']?.toString();
      final action = _asMap(command['action']);
      final createdAt = DateTime.tryParse(
        command['created_at']?.toString() ?? '',
      )?.toUtc();
      if (commandId == null ||
          commandId.isEmpty ||
          zoneId == null ||
          zoneId.isEmpty ||
          action.isEmpty ||
          createdAt == null ||
          now.difference(createdAt) > _pendingPlaybackCommandTtl) {
        continue;
      }
      _pendingPlaybackCommandsV3[commandId] = <String, dynamic>{
        'command_id': commandId,
        'zone_id': zoneId,
        'action': action,
        'created_at': createdAt.toIso8601String(),
      };
    }
  }

  Future<void> _rememberPendingPlaybackCommandV3({
    required String zoneId,
    required String commandId,
    required Map<String, dynamic> action,
  }) async {
    final existing = _pendingPlaybackCommandsV3[commandId];
    _pendingPlaybackCommandsV3[commandId] = <String, dynamic>{
      'command_id': commandId,
      'zone_id': zoneId,
      'action': Map<String, dynamic>.from(action),
      'created_at':
          existing?['created_at']?.toString() ??
          DateTime.now().toUtc().toIso8601String(),
    };
    try {
      await _persistPendingPlaybackCommandsV3();
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.session_v3.outbox_persist_failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{'command_id': commandId},
      );
    }
  }

  Future<void> _forgetPendingPlaybackCommandV3(String commandId) async {
    if (_pendingPlaybackCommandsV3.remove(commandId) == null) return;
    try {
      await _persistPendingPlaybackCommandsV3();
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.session_v3.outbox_persist_failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{'command_id': commandId, 'removing': true},
      );
    }
  }

  Future<void> _persistPendingPlaybackCommandsV3() =>
      _persistOverviewValues(<String, dynamic>{
        'pending_playback_commands_v3': _pendingPlaybackCommandsV3.values
            .toList(growable: false),
      });

  Future<void> _reconcilePendingPlaybackCommandsV3({String? zoneId}) async {
    if (_reconcilingPendingPlaybackCommandsV3 ||
        _localPlaybackFallbackActive ||
        _pendingPlaybackCommandsV3.isEmpty) {
      return;
    }
    _reconcilingPendingPlaybackCommandsV3 = true;
    try {
      final now = DateTime.now().toUtc();
      final pending = _pendingPlaybackCommandsV3.values
          .map(Map<String, dynamic>.from)
          .toList(growable: false);
      for (final command in pending) {
        final commandId = command['command_id']?.toString();
        final targetZoneId = command['zone_id']?.toString();
        final createdAt = DateTime.tryParse(
          command['created_at']?.toString() ?? '',
        )?.toUtc();
        if (commandId == null ||
            targetZoneId == null ||
            createdAt == null ||
            now.difference(createdAt) > _pendingPlaybackCommandTtl) {
          if (commandId != null) {
            await _forgetPendingPlaybackCommandV3(commandId);
          }
          continue;
        }
        if (zoneId != null && targetZoneId != zoneId) continue;
        final result = await _postPlaybackSessionActionV3(
          targetZoneId,
          _asMap(command['action']),
          commandId: commandId,
          reconcilingPending: true,
        );
        ClientLog.event(
          'playback.session_v3.pending_reconciled',
          level: result != null && _playbackSessionCommandAcknowledgedV3(result)
              ? 'info'
              : 'warning',
          data: <String, Object?>{
            'zone_id': targetZoneId,
            'command_id': commandId,
            'acknowledged':
                result != null && _playbackSessionCommandAcknowledgedV3(result),
          },
        );
      }
    } finally {
      _reconcilingPendingPlaybackCommandsV3 = false;
    }
  }

  String _newPlaybackCommandId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  List<Map<String, dynamic>> _newPlaybackQueueItems(Iterable<int> trackIds) {
    final addedAt = DateTime.now().toUtc().toIso8601String();
    return <Map<String, dynamic>>[
      for (final trackId in trackIds)
        <String, dynamic>{
          'item_id': _newPlaybackCommandId(),
          'track_id': trackId,
          'added_by_device_id': _clientId,
          'added_at': addedAt,
        },
    ];
  }
}
