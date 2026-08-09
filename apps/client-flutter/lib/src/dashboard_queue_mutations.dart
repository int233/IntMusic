part of '../intmusic_client.dart';

extension _DashboardQueueMutations on _CoreDashboardState {
  Future<void> _addTrackToQueue(int trackId, {bool playNext = false}) {
    return _addTracksToQueue(<int>[trackId], playNext: playNext);
  }

  Future<void> _addTracksToQueue(
    List<int> trackIds, {
    bool playNext = false,
  }) async {
    if (trackIds.isEmpty) return;
    if (_localPlaybackFallbackActive) {
      final ids = _queueItems()
          .map((item) => _intValue(_asMap(item['track'])['id']))
          .whereType<int>()
          .toList();
      final currentIndex = _intValue(_playbackQueue?['current_index']);
      final insertAt = playNext
          ? min((currentIndex ?? -1) + 1, ids.length)
          : ids.length;
      ids.insertAll(insertAt, trackIds);
      if (mounted) {
        _mutatePlayback(() => _setOfflineQueue(ids, startIndex: currentIndex));
      }
      return;
    }

    final currentIndex = _intValue(_playbackQueue?['current_index']);
    final position = playNext ? (currentIndex ?? -1) + 1 : null;
    final agent = _restorePlaybackAgentQueue();
    final beforeItemId = position != null && position < agent.items.length
        ? agent.items[position].itemId
        : null;
    final v3Playback =
        await _postPlaybackSessionActionV3(_activeZoneId(), <String, dynamic>{
          'type': 'add_queue_items',
          'items': _newPlaybackQueueItems(trackIds),
          'before_item_id': ?beforeItemId,
        });
    if (v3Playback != null) {
      unawaited(_refreshPlaybackQueue());
      if (_playbackSessionCommandAcknowledgedV3(v3Playback)) {
        _showQueueAddedMessage(trackIds.length, playNext: playNext);
      } else {
        _showQueueCommandPendingMessage();
      }
      return;
    }

    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/items',
          <String, dynamic>{'track_ids': trackIds, 'position': ?position},
        ),
      ),
    );
    if (!mounted || queue == null) return;
    _mutatePlayback(() => _applyPlaybackQueue(queue));
    _showQueueAddedMessage(trackIds.length, playNext: playNext);
  }

  void _showQueueAddedMessage(int count, {required bool playNext}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          playNext
              ? '$count track(s) will play next'
              : '$count track(s) added to queue',
        ),
      ),
    );
  }

  void _showQueueCommandPendingMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Core response pending · queue will reconcile'),
      ),
    );
  }

  Future<Map<String, dynamic>?> _replaceQueue(
    List<int> trackIds, {
    int? startIndex,
    _PlaybackMode? mode,
  }) async {
    if (_localPlaybackFallbackActive) {
      if (mode != null) _playbackMode = mode;
      if (mounted) {
        _mutatePlayback(
          () => _setOfflineQueue(trackIds, startIndex: startIndex),
        );
      } else {
        _setOfflineQueue(trackIds, startIndex: startIndex);
      }
      return _playbackQueue;
    }

    final items = _newPlaybackQueueItems(trackIds);
    final selectedItemId =
        startIndex != null && startIndex >= 0 && startIndex < items.length
        ? items[startIndex]['item_id']?.toString()
        : null;
    final v3Playback = await _postPlaybackSessionActionV3(
      _activeZoneId(),
      <String, dynamic>{
        'type': 'replace_queue',
        'items': items,
        'start_item_id': ?selectedItemId,
      },
    );
    if (v3Playback != null) {
      if (mode != null && mode != _playbackMode) {
        await _setPlaybackMode(mode);
      }
      unawaited(_refreshPlaybackQueue());
      return _playbackQueue ?? <String, dynamic>{'zone_id': _activeZoneId()};
    }

    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue',
          <String, dynamic>{
            'track_ids': trackIds,
            'start_index': startIndex,
            'mode': (mode ?? _playbackMode).nameForApi,
          },
        ),
      ),
    );
    if (mounted && queue != null) {
      _mutatePlayback(() => _applyPlaybackQueue(queue));
    }
    return queue;
  }
}
