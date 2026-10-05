part of '../intmusic_client.dart';

extension _DashboardPlaybackQueue on _CoreDashboardState {
  String _beginPlaybackIntent(String zoneId, String action) {
    final intentId = _newPlaybackCommandId();
    ClientLog.event(
      'playback.intent.created',
      data: <String, Object?>{
        'action': action,
        'zone_id': zoneId,
        'intent_id': intentId,
      },
    );
    return intentId;
  }

  Map<String, dynamic> _playbackCommandBody(
    Map<String, dynamic> body, {
    required String intentId,
  }) {
    return <String, dynamic>{
      ...body,
      'origin_client_id': _clientId,
      'intent_id': intentId,
    };
  }

  Future<void> _playTrack(int trackId) async {
    ClientLog.event(
      'playback.user.play_track',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': _activeZoneId(),
        'offline': _localPlaybackFallbackActive,
      },
    );
    if (_localPlaybackFallbackActive) {
      final trackIds = _tracks
          .map((track) => _intValue((track as Map)['id']))
          .whereType<int>()
          .toList(growable: false);
      await _playOfflineTrack(trackId, sourceTrackIds: trackIds);
      return;
    }
    final queueItems = (_playbackQueue?['items'] as List?) ?? const [];
    final queued = queueItems.any((item) {
      final queueItem = (item as Map).cast<String, dynamic>();
      final track = (queueItem['track'] as Map?)?.cast<String, dynamic>();
      return _intValue(track?['id']) == trackId;
    });
    if (!queued) {
      await _playTrackFromCollection(trackId, _tracks);
      return;
    }
    final playback = await _playTrackOnZone(trackId, _selectedZoneId);
    if (mounted && playback != null) {
      _mutatePlayback(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<void> _playTrackFromCollection(
    int trackId,
    List<dynamic> sourceTracks, {
    Map<String, dynamic>? source,
  }) async {
    final trackIds = sourceTracks
        .map((track) => _intValue((track as Map)['id']))
        .whereType<int>()
        .toList(growable: false);
    final startIndex = trackIds.indexOf(trackId);
    if (_localPlaybackFallbackActive) {
      await _playOfflineTrack(
        trackId,
        sourceTrackIds: trackIds,
        queueSource: source,
      );
      return;
    }
    if (startIndex < 0) {
      await _playTrack(trackId);
      return;
    }
    final zoneId = _activeZoneId();
    final items = _newPlaybackQueueItems(trackIds);
    final playback = await _postPlaybackSessionActionV3(zoneId, {
      'type': 'replace_queue_and_play',
      'source': ?source,
      'items': items,
      'start_item_id': items[startIndex]['item_id'],
      'position_ms': 0,
    }, commandId: _beginPlaybackIntent(zoneId, 'play_collection'));
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  Future<Map<String, dynamic>?> _playTrackOnZone(
    int trackId,
    String zoneId, {
    String? intentId,
  }) async {
    if (_localPlaybackFallbackActive) {
      await _playOfflineTrack(trackId);
      return _playback;
    }
    if (!await _refreshPlaybackSessionV3(zoneId: zoneId)) return null;
    final agent =
        _playbackAgentsByOutput[_clientOutputForZone(zoneId) ?? zoneId]!;
    final matches = agent.items.where((item) => item.trackId == trackId);
    final items = matches.isEmpty ? _newPlaybackQueueItems([trackId]) : null;
    return _postPlaybackSessionActionV3(
      zoneId,
      items == null
          ? {'type': 'play', 'item_id': matches.first.itemId, 'position_ms': 0}
          : {
              'type': 'replace_queue_and_play',
              'items': items,
              'start_item_id': items.first['item_id'],
              'position_ms': 0,
            },
      commandId: intentId ?? _beginPlaybackIntent(zoneId, 'play_track'),
    );
  }

  Future<void> _playPreviousTrack() async {
    if (_localPlaybackFallbackActive) {
      await _finishOfflinePlayback('previous');
      await _playPreviousOfflineTrack();
      return;
    }
    await _postZoneAction(_activeZoneId(), 'previous');
  }

  Future<void> _playNextTrack({bool automatic = false}) async {
    if (_localPlaybackFallbackActive) {
      await _finishOfflinePlayback(automatic ? 'completed' : 'next');
      await _playNextOfflineTrack(completed: automatic);
      return;
    }
    // Online EOF is handled only by the decoder's bound completion command.
    await _postZoneAction(_activeZoneId(), 'next');
  }

  Future<void> _refreshPlaybackQueue({String? zoneId}) async {
    final targetZoneId = zoneId ?? _activeZoneId();
    if (_localPlaybackFallbackActive) {
      _playbackQueue = <String, dynamic>{
        ...?_playbackQueue,
        'zone_id': targetZoneId,
      };
      return;
    }
    await _refreshPlaybackSessionV3(zoneId: targetZoneId);
  }

  void _applyPlaybackQueue(Map<String, dynamic> queue) {
    _playbackQueue = queue;
    _playbackMode = _PlaybackMode.fromApi(queue['mode']?.toString());
    _restorePlaybackAgentQueue();
    _decoratePlaybackQueueAvailability();
    _schedulePlaybackCheckpoint(immediate: true);
  }

  List<Map<String, dynamic>> _queueItems() =>
      ((_playbackQueue?['items'] as List?) ?? const [])
          .map((item) => (item as Map).cast<String, dynamic>())
          .toList(growable: false);

  PlaybackAgent _restorePlaybackAgentQueue({String? outputId}) {
    final queue = _playbackQueue ?? const <String, dynamic>{};
    final queueZoneId = queue['zone_id']?.toString() ?? _activeZoneId();
    final targetOutputId =
        outputId ?? _clientOutputForZone(queueZoneId) ?? queueZoneId;
    final agent = _playbackAgentsByOutput.putIfAbsent(
      targetOutputId,
      () => PlaybackAgent(targetOutputId),
    );
    if (_localPlaybackFallbackActive || !agent.hasSession) agent.restore(queue);
    if (!agent.hasSession && agent.currentIndex == null) {
      final currentTrackId = _intValue(_playback?['track_id']);
      if (currentTrackId != null && agent.selectTrack(currentTrackId)) {
        _playbackQueue = agent.checkpoint(queue);
      }
    }
    return agent;
  }

  List<PlaybackAgentItem> _playbackAgentCandidates({
    required bool next,
    required bool automatic,
  }) {
    final agent = _restorePlaybackAgentQueue();
    return next
        ? agent.nextCandidates(automatic: automatic)
        : agent.previousCandidates();
  }

  void _selectPlaybackAgentItem(PlaybackAgentItem item) {
    final agent = _restorePlaybackAgentQueue();
    if (!agent.selectIndex(item.index)) return;
    _playbackQueue = agent.checkpoint(
      _playbackQueue ?? const <String, dynamic>{},
    );
    _schedulePlaybackCheckpoint(immediate: true);
  }

  Future<bool> _playAvailableLocalAgentCandidate({
    required bool next,
    required bool automatic,
    required String reason,
  }) async {
    final candidates = _playbackAgentCandidates(
      next: next,
      automatic: automatic,
    );
    for (final candidate in candidates) {
      final copy = await _availableOfflineCopy(candidate.trackId);
      if (copy == null) {
        ClientLog.event(
          'playback.agent.candidate_skipped',
          data: <String, Object?>{
            'track_id': candidate.trackId,
            'queue_index': candidate.index,
            'reason': 'local_copy_unavailable',
          },
        );
        continue;
      }
      _selectPlaybackAgentItem(candidate);
      await _playOfflineTrack(candidate.trackId);
      ClientLog.event(
        'playback.agent.local_advance',
        data: <String, Object?>{
          'track_id': candidate.trackId,
          'queue_index': candidate.index,
          'reason': reason,
        },
      );
      return true;
    }
    ClientLog.event(
      'playback.agent.exhausted',
      level: 'warning',
      data: <String, Object?>{'reason': reason},
    );
    return false;
  }

  Future<void> _playCollection(List<int> trackIds, bool shuffle) async {
    if (trackIds.isEmpty) {
      return;
    }
    if (_localPlaybackFallbackActive) {
      final offlineIds = List<int>.of(trackIds);
      if (shuffle) offlineIds.shuffle(Random.secure());
      _playbackMode = shuffle
          ? _PlaybackMode.shuffle
          : _PlaybackMode.sequential;
      await _playOfflineTrack(offlineIds.first, sourceTrackIds: offlineIds);
      return;
    }
    await _setPlaybackMode(
      shuffle ? _PlaybackMode.shuffle : _PlaybackMode.sequential,
    );
    await _playTrackFromCollection(trackIds.first, [
      for (final id in trackIds) {'id': id},
    ]);
  }

  Future<Map<String, dynamic>?> _clearUpcomingQueue() {
    final items = _queueItems();
    final currentIndex = _intValue(_playbackQueue?['current_index']);
    if (currentIndex == null || currentIndex < 0) {
      return _replaceQueue(const []);
    }
    if (!_localPlaybackFallbackActive) {
      final agent = _restorePlaybackAgentQueue();
      final retained = agent.items.take(currentIndex + 1).toList();
      return _postPlaybackSessionActionV3(_activeZoneId(), {
        'type': 'replace_queue',
        'items': [
          for (final item in retained)
            {
              'item_id': item.itemId,
              'track_id': item.trackId,
              'added_by_device_id': _clientId,
              'added_at': DateTime.now().toUtc().toIso8601String(),
            },
        ],
        'start_item_id': retained.isEmpty ? null : retained.last.itemId,
      }).then((_) => _playbackQueue);
    }
    final retainedIds = items
        .take(min(currentIndex + 1, items.length))
        .map((item) => _intValue(_asMap(item['track'])['id']))
        .whereType<int>()
        .toList(growable: false);
    return _replaceQueue(
      retainedIds,
      startIndex: retainedIds.isEmpty ? null : retainedIds.length - 1,
    );
  }

  Future<Map<String, dynamic>?> _clearEntireQueue() async {
    final queue = await _replaceQueue(const []);
    if (queue != null) {
      await _stopZone(_activeZoneId());
    }
    return queue;
  }

  Future<Map<String, dynamic>?> _moveQueueItem(
    String itemId,
    String? beforeItemId,
  ) async {
    if (_localPlaybackFallbackActive) {
      final items = _queueItems();
      final currentIndex = _intValue(_playbackQueue?['current_index']);
      final currentId = currentIndex == null ? null : items[currentIndex]['id'];
      final from = items.indexWhere((item) => item['id'] == itemId);
      if (from < 0) return _playbackQueue;
      final moved = items.removeAt(from);
      final target = beforeItemId == null
          ? items.length
          : items.indexWhere((item) => item['id'] == beforeItemId);
      if (target < 0) return _playbackQueue;
      items.insert(target, moved);
      _applyPlaybackQueue({
        ...?_playbackQueue,
        'items': items,
        'current_index': items.indexWhere((item) => item['id'] == currentId),
      });
      return _playbackQueue;
    }
    await _postPlaybackSessionActionV3(_activeZoneId(), {
      'type': 'move_queue_item',
      'item_id': itemId,
      'before_item_id': ?beforeItemId,
    });
    return _playbackQueue;
  }

  Future<Map<String, dynamic>?> _removeQueueItem(String itemId) async {
    if (_localPlaybackFallbackActive) {
      final items = _queueItems();
      final ids = items
          .where((item) => item['id']?.toString() != itemId)
          .map((item) => _intValue(_asMap(item['track'])['id']))
          .whereType<int>()
          .toList(growable: false);
      final currentTrackId = _intValue(_playback?['track_id']);
      final currentIndex = ids.indexOf(currentTrackId ?? -1);
      if (mounted) {
        _mutatePlayback(() => _setOfflineQueue(ids, startIndex: currentIndex));
      }
      return _playbackQueue;
    }
    await _postPlaybackSessionActionV3(_activeZoneId(), {
      'type': 'remove_queue_item',
      'item_id': itemId,
    });
    return _playbackQueue;
  }

  void _cyclePlaybackMode() {
    final nextIndex =
        (_PlaybackMode.values.indexOf(_playbackMode) + 1) %
        _PlaybackMode.values.length;
    unawaited(_setPlaybackMode(_PlaybackMode.values[nextIndex]));
  }

  Future<void> _setPlaybackMode(_PlaybackMode mode) async {
    if (_localPlaybackFallbackActive) {
      if (mounted) {
        _mutatePlayback(() {
          _playbackMode = mode;
          _playbackQueue = <String, dynamic>{
            ...?_playbackQueue,
            'mode': mode.nameForApi,
          };
        });
      }
      return;
    }
    final v3Mode = <String, dynamic>{
      'repeat': mode == _PlaybackMode.repeatOne
          ? 'one'
          : mode == _PlaybackMode.repeatAll
          ? 'all'
          : 'off',
      'shuffle': mode == _PlaybackMode.shuffle,
      'stop_after_current': mode == _PlaybackMode.single,
    };
    final v3Playback = await _postPlaybackSessionActionV3(
      _activeZoneId(),
      <String, dynamic>{'type': 'set_mode', 'mode': v3Mode},
    );
    if (v3Playback != null) {
      if (mounted) {
        _mutatePlayback(() {
          _playbackMode = mode;
          _playbackQueue = <String, dynamic>{
            ...?_playbackQueue,
            'mode': mode.nameForApi,
          };
        });
      }
      unawaited(_refreshPlaybackQueue());
      return;
    }
  }
}
