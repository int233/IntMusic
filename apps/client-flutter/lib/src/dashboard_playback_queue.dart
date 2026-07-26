part of '../intmusic_client.dart';

extension _DashboardPlaybackQueue on _CoreDashboardState {
  String _beginPlaybackIntent(String zoneId, String action) {
    final intents = action == 'volume'
        ? _latestVolumeIntentByZone
        : _latestPlaybackIntentByZone;
    final previousIntent = intents[zoneId];
    if (previousIntent != null) {
      _locallyAppliedPlaybackIntents.remove(previousIntent);
    }
    final intentId =
        '$_clientId-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_playbackIntentSequence}';
    intents[zoneId] = intentId;
    if (action != 'volume') {
      _latestPlaybackIntentAtByZone[zoneId] = DateTime.now().toUtc();
      _desiredTransportStateByZone[zoneId] = switch (action) {
        'pause' => 'paused',
        'stop' => 'stopped',
        _ => 'playing',
      };
      final outputId = _clientOutputForZone(zoneId);
      if (outputId != null) {
        _rendererOperationGenerationByOutput[outputId] =
            (_rendererOperationGenerationByOutput[outputId] ?? 0) + 1;
      }
    }
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

  void _markPlaybackIntentAppliedLocally(String intentId) {
    _locallyAppliedPlaybackIntents.add(intentId);
  }

  Future<void> _playTrack(int trackId) async {
    ClientLog.event(
      'playback.user.play_track',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': _activeZoneId(),
        'offline': _offlineMode,
      },
    );
    if (_offlineMode) {
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
    List<dynamic> sourceTracks,
  ) async {
    final trackIds = sourceTracks
        .map((track) => _intValue((track as Map)['id']))
        .whereType<int>()
        .toList(growable: false);
    final startIndex = trackIds.indexOf(trackId);
    if (_offlineMode) {
      await _playOfflineTrack(trackId, sourceTrackIds: trackIds);
      return;
    }
    if (startIndex < 0) {
      await _playTrack(trackId);
      return;
    }
    final zoneId = _activeZoneId();
    final intentId = _beginPlaybackIntent(zoneId, 'play_collection');
    final requestWatch = Stopwatch()..start();
    ClientLog.event(
      'playback.user.play_collection',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': zoneId,
        'collection_size': trackIds.length,
        'start_index': startIndex,
      },
    );
    final optimisticTrack = _findEntity(_tracks, trackId);
    if (mounted) {
      _mutatePlayback(() {
        _applyPlayback(<String, dynamic>{
          'zone_id': zoneId,
          'state': 'loading',
          'track_id': trackId,
          'track_title': optimisticTrack?['title'],
          'position_ms': 0,
          'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
          'origin_client_id': _clientId,
          'intent_id': intentId,
        });
      });
    }
    final localStarted = await _tryStartLocalPlayback(
      trackId,
      zoneId: zoneId,
      sourceTrackIds: trackIds,
      intentId: intentId,
    );
    try {
      final result = _asMap(
        await _serializePlaybackRequest<dynamic>(
          zoneId,
          intentId,
          () => _api.postControlJson(
            '/zones/${Uri.encodeComponent(zoneId)}/play-collection',
            _playbackCommandBody(<String, dynamic>{
              'track_ids': trackIds,
              'start_index': startIndex,
              'mode': _PlaybackMode.sequential.nameForApi,
            }, intentId: intentId),
          ),
        ),
      );
      final queue = _asMap(result['queue']);
      final playback = _asMap(result['playback']);
      if (mounted) {
        _mutatePlayback(() {
          if (queue.isNotEmpty) _applyPlaybackQueue(queue);
          if (playback.isNotEmpty && _acceptIncomingPlayback(playback)) {
            _applyPlayback(playback);
          }
        });
      }
      ClientLog.event(
        'playback.core.play_collection.applied',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': requestWatch.elapsedMilliseconds,
          'local_fast_start': localStarted,
          'core_timing_ms': _asMap(result['timing_ms']),
        },
      );
    } on _SupersededPlaybackIntent {
      ClientLog.event(
        'playback.core.play_collection.superseded',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'intent_id': intentId,
        },
      );
    } on HttpException catch (error) {
      final unsupported =
          error.message.contains('HTTP 404') ||
          error.message.contains('HTTP 405');
      if (!unsupported) {
        ClientLog.error(
          'playback.core.play_collection.failed',
          error,
          data: <String, Object?>{
            'track_id': trackId,
            'zone_id': zoneId,
            'elapsed_ms': requestWatch.elapsedMilliseconds,
            'local_fast_start': localStarted,
          },
        );
        if (mounted && localStarted) {
          _mutate(
            () => _rendererStatus = _tr(
              context,
              'Weak connection · local playback continues',
            ),
          );
        } else if (mounted) {
          _mutate(() => _error = error.toString());
        }
        return;
      }
      final queue = await _replaceQueue(
        trackIds,
        startIndex: startIndex,
        mode: _PlaybackMode.sequential,
      );
      if (queue == null) return;
      final playback = await _playTrackOnZone(
        trackId,
        zoneId,
        tryLocalFastStart: false,
        intentId: intentId,
      );
      if (mounted && playback != null) {
        _mutatePlayback(() => _applyPlayback(playback));
      }
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.core.play_collection.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': requestWatch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      if (mounted && localStarted) {
        _mutate(
          () => _rendererStatus = _tr(
            context,
            'Weak connection · local playback continues',
          ),
        );
      } else if (mounted) {
        _mutate(() => _error = error.toString());
      }
    }
  }

  Future<Map<String, dynamic>?> _playTrackOnZone(
    int trackId,
    String zoneId, {
    bool tryLocalFastStart = true,
    String? intentId,
  }) async {
    if (_offlineMode) {
      await _playOfflineTrack(trackId);
      return _playback;
    }
    final playbackIntentId =
        intentId ?? _beginPlaybackIntent(zoneId, 'play_track');
    final watch = Stopwatch()..start();
    final localStarted =
        tryLocalFastStart &&
        await _tryStartLocalPlayback(
          trackId,
          zoneId: zoneId,
          intentId: playbackIntentId,
        );
    try {
      final playback = _asMap(
        await _serializePlaybackRequest<dynamic>(
          zoneId,
          playbackIntentId,
          () => _api.postControlJson(
            '/zones/${Uri.encodeComponent(zoneId)}/play',
            _playbackCommandBody(<String, dynamic>{
              'track_id': trackId,
            }, intentId: playbackIntentId),
          ),
        ),
      );
      ClientLog.event(
        'playback.core.play_track.applied',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': watch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      return _acceptIncomingPlayback(playback) ? playback : null;
    } on _SupersededPlaybackIntent {
      ClientLog.event(
        'playback.core.play_track.superseded',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'intent_id': playbackIntentId,
        },
      );
      return null;
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.core.play_track.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': watch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      if (mounted && localStarted) {
        _mutate(
          () => _rendererStatus = _tr(
            context,
            'Weak connection · local playback continues',
          ),
        );
      } else if (mounted) {
        _mutate(() => _error = error.toString());
      }
      return null;
    }
  }

  Future<void> _playPreviousTrack() async {
    if (_offlineMode) {
      await _finishOfflinePlayback('previous');
      await _playPreviousOfflineTrack();
      return;
    }
    final zoneId = _activeZoneId();
    final intentId = _beginPlaybackIntent(zoneId, 'previous');
    await _tryStartAdjacentLocalPlayback(next: false, intentId: intentId);
    final playback = await _postPlaybackControl(
      zoneId,
      '/zones/${Uri.encodeComponent(zoneId)}/previous',
      _playbackCommandBody(const <String, dynamic>{}, intentId: intentId),
    );
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  Future<void> _playNextTrack() async {
    if (_offlineMode) {
      await _finishOfflinePlayback('next');
      await _playNextOfflineTrack();
      return;
    }
    final zoneId = _activeZoneId();
    final intentId = _beginPlaybackIntent(zoneId, 'next');
    await _tryStartAdjacentLocalPlayback(next: true, intentId: intentId);
    final playback = await _postPlaybackControl(
      zoneId,
      '/zones/${Uri.encodeComponent(zoneId)}/next',
      _playbackCommandBody(const <String, dynamic>{}, intentId: intentId),
    );
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  Future<bool> _tryStartAdjacentLocalPlayback({
    required bool next,
    required String intentId,
  }) async {
    if (_playbackMode == _PlaybackMode.shuffle ||
        _playbackMode == _PlaybackMode.repeatOne ||
        !_zoneUsesThisClient(_activeZoneId())) {
      return false;
    }
    final items = _queueItems();
    if (items.isEmpty) return false;
    var index = _intValue(_playbackQueue?['current_index']);
    if (index == null || index < 0 || index >= items.length) {
      final currentTrackId = _intValue(_playback?['track_id']);
      index = items.indexWhere(
        (item) => _intValue(_asMap(item['track'])['id']) == currentTrackId,
      );
    }
    if (index < 0) return false;
    index += next ? 1 : -1;
    if (index < 0 || index >= items.length) {
      if (_playbackMode != _PlaybackMode.repeatAll) return false;
      index = next ? 0 : items.length - 1;
    }
    final trackId = _intValue(_asMap(items[index]['track'])['id']);
    if (trackId == null) return false;
    return _tryStartLocalPlayback(
      trackId,
      zoneId: _activeZoneId(),
      intentId: intentId,
    );
  }

  Future<void> _refreshPlaybackQueue({String? zoneId}) async {
    final targetZoneId = zoneId ?? _activeZoneId();
    try {
      final queue = _asMap(
        await _api.getJson('/zones/${Uri.encodeComponent(targetZoneId)}/queue'),
      );
      if (!mounted || targetZoneId != _activeZoneId()) {
        return;
      }
      _mutatePlayback(() => _applyPlaybackQueue(queue));
      unawaited(
        _persistOverviewValues(<String, dynamic>{'playback_queue': queue}),
      );
    } catch (_) {
      // Zone refresh and the event stream will retry the queue snapshot.
    }
  }

  void _applyPlaybackQueue(Map<String, dynamic> queue) {
    _playbackQueue = queue;
    _playbackMode = _PlaybackMode.fromApi(queue['mode']?.toString());
  }

  List<Map<String, dynamic>> _queueItems() =>
      ((_playbackQueue?['items'] as List?) ?? const [])
          .map((item) => (item as Map).cast<String, dynamic>())
          .toList(growable: false);

  Future<void> _addTrackToQueue(int trackId, {bool playNext = false}) {
    return _addTracksToQueue(<int>[trackId], playNext: playNext);
  }

  Future<void> _addTracksToQueue(
    List<int> trackIds, {
    bool playNext = false,
  }) async {
    if (trackIds.isEmpty) {
      return;
    }
    if (_offlineMode) {
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
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/items',
          <String, dynamic>{'track_ids': trackIds, 'position': ?position},
        ),
      ),
    );
    if (!mounted || queue == null) {
      return;
    }
    _mutatePlayback(() => _applyPlaybackQueue(queue));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(
          playNext
              ? '${trackIds.length} track(s) will play next'
              : '${trackIds.length} track(s) added to queue',
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _replaceQueue(
    List<int> trackIds, {
    int? startIndex,
    _PlaybackMode? mode,
  }) async {
    if (_offlineMode) {
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

  Future<void> _playCollection(List<int> trackIds, bool shuffle) async {
    if (trackIds.isEmpty) {
      return;
    }
    if (_offlineMode) {
      final offlineIds = List<int>.of(trackIds);
      if (shuffle) offlineIds.shuffle(Random.secure());
      _playbackMode = shuffle
          ? _PlaybackMode.shuffle
          : _PlaybackMode.sequential;
      await _playOfflineTrack(offlineIds.first, sourceTrackIds: offlineIds);
      return;
    }
    final queue = await _replaceQueue(
      trackIds,
      startIndex: 0,
      mode: shuffle ? _PlaybackMode.shuffle : _PlaybackMode.sequential,
    );
    if (queue == null) {
      return;
    }
    final playback = await _playTrackOnZone(trackIds.first, _activeZoneId());
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  Future<Map<String, dynamic>?> _clearUpcomingQueue() {
    final items = _queueItems();
    final currentIndex = _intValue(_playbackQueue?['current_index']);
    if (currentIndex == null || currentIndex < 0) {
      return _replaceQueue(const []);
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

  Future<Map<String, dynamic>?> _moveQueueItem(int from, int to) async {
    if (_offlineMode) {
      final ids = _queueItems()
          .map((item) => _intValue(_asMap(item['track'])['id']))
          .whereType<int>()
          .toList();
      if (from < 0 || from >= ids.length || to < 0 || to >= ids.length) {
        return _playbackQueue;
      }
      final currentTrackId = _intValue(_playback?['track_id']);
      final moved = ids.removeAt(from);
      ids.insert(to, moved);
      final currentIndex = ids.indexOf(currentTrackId ?? -1);
      if (mounted) {
        _mutatePlayback(() => _setOfflineQueue(ids, startIndex: currentIndex));
      }
      return _playbackQueue;
    }
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/move',
          <String, dynamic>{'from': from, 'to': to},
        ),
      ),
    );
    if (mounted && queue != null) {
      _mutatePlayback(() => _applyPlaybackQueue(queue));
    }
    return queue;
  }

  Future<Map<String, dynamic>?> _removeQueueItem(int itemId) async {
    if (_offlineMode) {
      final items = _queueItems();
      final ids = items
          .where((item) => _intValue(item['id']) != itemId)
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
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.deleteJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/items/$itemId',
        ),
      ),
    );
    if (mounted && queue != null) {
      _mutatePlayback(() => _applyPlaybackQueue(queue));
    }
    return queue;
  }

  void _cyclePlaybackMode() {
    final nextIndex =
        (_PlaybackMode.values.indexOf(_playbackMode) + 1) %
        _PlaybackMode.values.length;
    unawaited(_setPlaybackMode(_PlaybackMode.values[nextIndex]));
  }

  Future<void> _setPlaybackMode(_PlaybackMode mode) async {
    if (_offlineMode) {
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
    final queue = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson(
          '/zones/${Uri.encodeComponent(_activeZoneId())}/queue/mode',
          <String, dynamic>{'mode': mode.nameForApi},
        ),
      ),
    );
    if (mounted && queue != null) {
      _mutatePlayback(() => _applyPlaybackQueue(queue));
    }
  }
}
