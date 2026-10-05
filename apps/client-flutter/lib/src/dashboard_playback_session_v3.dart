part of '../intmusic_client.dart';

/// One revisioned protocol for queue display, control, retry and decoder EOF.
extension _DashboardPlaybackSessionV3 on _CoreDashboardState {
  static const Duration _pendingPlaybackCommandTtl = Duration(seconds: 30);

  Future<void> _playQueueItem(String itemId, int trackId) async {
    if (_localPlaybackFallbackActive) {
      final agent = _restorePlaybackAgentQueue();
      final item = agent.items
          .where((item) => item.itemId == itemId)
          .firstOrNull;
      if (item != null) _selectPlaybackAgentItem(item);
      await _playOfflineTrack(trackId);
      return;
    }
    final zoneId = _activeZoneId();
    final playback = await _postPlaybackSessionActionV3(zoneId, {
      'type': 'play',
      'item_id': itemId,
      'position_ms': 0,
    }, commandId: _beginPlaybackIntent(zoneId, 'play_queue_item'));
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  PlaybackAgent _sessionAgent(String zoneId) =>
      _playbackAgentsByOutput.putIfAbsent(
        _clientOutputForZone(zoneId) ?? zoneId,
        () => PlaybackAgent(zoneId),
      );

  void _projectSessionQueue(String zoneId, PlaybackAgent agent) {
    if (!mounted || zoneId != _activeZoneId()) return;
    final tracks = {
      for (final raw in _tracks) _intValue(_asMap(raw)['id']): _asMap(raw),
    };
    _mutatePlayback(
      () => _applyPlaybackQueue({
        'zone_id': zoneId,
        'queue_source': agent.queueSource,
        'revision': agent.sessionRevision,
        'shuffle_seed': agent.shuffleSeed,
        'mode': agent.mode,
        'current_index': agent.currentIndex,
        'items': [
          for (final item in agent.items)
            {
              'id': item.itemId,
              'position': item.index,
              'track':
                  tracks[item.trackId] ??
                  {'id': item.trackId, 'title': 'Track ${item.trackId}'},
            },
        ],
      }),
    );
  }

  Future<bool> _refreshPlaybackSessionV3({String? zoneId}) async {
    if (_localPlaybackFallbackActive) return false;
    final target = zoneId ?? _activeZoneId();
    try {
      final snapshot = _asMap(
        await _api.getCriticalJson(
          '/playback-v3/zones/${Uri.encodeComponent(target)}/session',
        ),
      );
      if (snapshot.isEmpty) throw StateError('Missing playback session');
      final agent = _sessionAgent(target)..restoreSession(snapshot);
      _projectSessionQueue(target, agent);
      unawaited(_reconcilePendingPlaybackCommandsV3(zoneId: target));
      return true;
    } catch (error, stack) {
      ClientLog.error(
        'playback.session.restore_failed',
        error,
        stackTrace: stack,
      );
      if (mounted) {
        _mutate(() => _error = 'Playback connection unavailable: $error');
      }
      return false;
    }
  }

  Future<Map<String, dynamic>?> _postPlaybackSessionActionV3(
    String zoneId,
    Map<String, dynamic> action, {
    String? commandId,
    bool reconcilingPending = false,
  }) {
    return _playbackRequestsByZone.putIfAbsent(zoneId, SerialTaskQueue.new).run(
      () {
        if (reconcilingPending &&
            !_pendingPlaybackCommandsV3.containsKey(commandId)) {
          return Future<Map<String, dynamic>?>.value(null);
        }
        return _sendPlaybackSessionAction(
          zoneId,
          action,
          commandId: commandId,
          retry: reconcilingPending,
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _sendPlaybackSessionAction(
    String zoneId,
    Map<String, dynamic> action, {
    String? commandId,
    required bool retry,
  }) async {
    final agent = _sessionAgent(zoneId);
    if (!agent.hasSession && !await _refreshPlaybackSessionV3(zoneId: zoneId)) {
      return null;
    }
    var id = commandId ?? _newPlaybackCommandId();
    for (var attempt = 0; attempt < 2; attempt++) {
      final pending = _pendingPlaybackCommandsV3[id];
      final envelope = pending == null
          ? agent.command(
              commandId: id,
              originDeviceId: _clientId,
              action: action,
            )
          : _asMap(pending['command']);
      _pendingPlaybackCommandsV3[id] = {
        'command_id': id,
        'zone_id': zoneId,
        'command': envelope,
        'created_at':
            pending?['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
      };
      await _persistPendingPlaybackCommandsV3();
      try {
        final ack = _asMap(
          await _api.postControlJson(
            '/playback-v3/zones/${Uri.encodeComponent(zoneId)}/commands',
            envelope,
          ),
        );
        final status = agent.applyAck(ack);
        _projectSessionQueue(zoneId, agent);
        await _forgetPendingPlaybackCommandV3(id);
        if (!retry &&
            status == 'conflict' &&
            ack['error_code'] == 'revision_conflict' &&
            attempt == 0) {
          final newId = _newPlaybackCommandId();
          id = newId;
          continue;
        }
        if (status != 'applied' && status != 'duplicate') {
          throw StateError('Playback command rejected: ${ack['error_code']}');
        }
        final snapshot = _asMap(ack['snapshot']);
        final index = agent.currentIndex;
        final trackId = index == null ? null : agent.items[index].trackId;
        final local =
            await _audioPlayers[_clientOutputForZone(zoneId) ?? zoneId];
        final activeCommand = _rendererActiveCommandByOutput[zoneId];
        final localMatches =
            local != null &&
            activeCommand?['sequence'] == snapshot['command_sequence'];
        return _withPlaybackTimestamp({
          'zone_id': zoneId,
          'state': localMatches
              ? local.snapshot.transport
              : snapshot['transport'],
          'track_id': trackId,
          'track_title': trackId == null
              ? null
              : _findEntity(_tracks, trackId)?['title'],
          'position_ms': localMatches
              ? local.snapshot.positionMs
              : snapshot['position_ms'],
          'command_sequence': snapshot['command_sequence'],
          'queue_revision': agent.sessionRevision,
          '_v3_command_delivery': 'acknowledged',
        });
      } catch (error, stack) {
        ClientLog.error(
          'playback.session.command_failed',
          error,
          stackTrace: stack,
          data: {'zone_id': zoneId, 'command_id': id, 'action': action['type']},
        );
        if (mounted) _mutate(() => _error = 'Playback command failed: $error');
        if (!_pendingPlaybackCommandsV3.containsKey(id)) return null;
        // An uncertain response never invokes another endpoint or invents a
        // playing state. Retry exactly this envelope and idempotency key.
        return {
          'zone_id': zoneId,
          'state': 'loading',
          '_v3_command_delivery': 'pending',
        };
      }
    }
    return null;
  }

  bool _playbackSessionCommandAcknowledgedV3(Map<String, dynamic> playback) =>
      playback['_v3_command_delivery'] == 'acknowledged';

  void _restorePendingPlaybackCommandsV3(Object? value) {
    _pendingPlaybackCommandsV3.clear();
    for (final raw in (value as List?) ?? const []) {
      final pending = _asMap(raw);
      final command = _asMap(pending['command']);
      final created = DateTime.tryParse(
        pending['created_at']?.toString() ?? '',
      );
      final id = command['command_id']?.toString();
      if (id == null ||
          created == null ||
          pending['zone_id'] == null ||
          DateTime.now().toUtc().difference(created) >
              _pendingPlaybackCommandTtl) {
        continue;
      }
      _pendingPlaybackCommandsV3[id] = pending;
    }
  }

  Future<void> _forgetPendingPlaybackCommandV3(String id) async {
    _pendingPlaybackCommandsV3.remove(id);
    await _persistPendingPlaybackCommandsV3();
  }

  Future<void> _persistPendingPlaybackCommandsV3() async {
    try {
      await _persistOverviewValues({
        'pending_playback_commands_v3': _pendingPlaybackCommandsV3.values
            .toList(growable: false),
      });
    } catch (error, stack) {
      ClientLog.error(
        'playback.session.outbox_failed',
        error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _reconcilePendingPlaybackCommandsV3({String? zoneId}) async {
    if (_reconcilingPendingPlaybackCommandsV3 || _localPlaybackFallbackActive) {
      return;
    }
    _reconcilingPendingPlaybackCommandsV3 = true;
    try {
      for (final pending in _pendingPlaybackCommandsV3.values.toList()) {
        final id = pending['command_id'] as String;
        final target = pending['zone_id'] as String;
        if (zoneId != null && target != zoneId) continue;
        final created = DateTime.parse(pending['created_at'] as String);
        if (DateTime.now().toUtc().difference(created) >
            _pendingPlaybackCommandTtl) {
          await _forgetPendingPlaybackCommandV3(id);
          continue;
        }
        if (!_pendingPlaybackCommandsV3.containsKey(id)) continue;
        await _postPlaybackSessionActionV3(
          target,
          _asMap(_asMap(pending['command'])['action']),
          commandId: id,
          reconcilingPending: true,
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
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  List<Map<String, dynamic>> _newPlaybackQueueItems(Iterable<int> trackIds) {
    final addedAt = DateTime.now().toUtc().toIso8601String();
    return [
      for (final trackId in trackIds)
        {
          'item_id': _newPlaybackCommandId(),
          'track_id': trackId,
          'added_by_device_id': _clientId,
          'added_at': addedAt,
        },
    ];
  }
}
