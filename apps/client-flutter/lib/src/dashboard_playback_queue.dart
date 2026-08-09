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
    final intentId = _newPlaybackCommandId();
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
    List<dynamic> sourceTracks,
  ) async {
    final trackIds = sourceTracks
        .map((track) => _intValue((track as Map)['id']))
        .whereType<int>()
        .toList(growable: false);
    final startIndex = trackIds.indexOf(trackId);
    if (_localPlaybackFallbackActive) {
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
    final v3Items = _newPlaybackQueueItems(trackIds);
    final v3Playback =
        await _postPlaybackSessionActionV3(zoneId, <String, dynamic>{
          'type': 'replace_queue_and_play',
          'items': v3Items,
          'start_item_id': v3Items[startIndex]['item_id'],
          'position_ms': 0,
        }, commandId: intentId);
    if (v3Playback != null) {
      if (mounted) {
        _mutatePlayback(() => _applyPlayback(v3Playback));
      }
      unawaited(_refreshPlaybackQueue(zoneId: zoneId));
      ClientLog.event(
        _playbackSessionCommandAcknowledgedV3(v3Playback)
            ? 'playback.session_v3.play_collection.applied'
            : 'playback.session_v3.play_collection.pending',
        level: _playbackSessionCommandAcknowledgedV3(v3Playback)
            ? 'info'
            : 'warning',
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': requestWatch.elapsedMilliseconds,
          'local_fast_start': localStarted,
        },
      );
      return;
    }
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
    if (_localPlaybackFallbackActive) {
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
    final outputId = _clientOutputForZone(zoneId) ?? zoneId;
    var agent = _playbackAgentsByOutput.putIfAbsent(
      outputId,
      () => PlaybackAgent(outputId),
    );
    if (!agent.hasSession && await _refreshPlaybackSessionV3(zoneId: zoneId)) {
      agent = _playbackAgentsByOutput[outputId]!;
    }
    PlaybackAgentItem? queueItem;
    for (final item in agent.items) {
      if (item.trackId == trackId) {
        queueItem = item;
        break;
      }
    }
    if (queueItem != null) {
      final v3Playback = await _postPlaybackSessionActionV3(
        zoneId,
        <String, dynamic>{
          'type': 'play',
          'item_id': queueItem.itemId,
          'position_ms': 0,
        },
        commandId: playbackIntentId,
      );
      if (v3Playback != null) {
        ClientLog.event(
          _playbackSessionCommandAcknowledgedV3(v3Playback)
              ? 'playback.session_v3.play_track.applied'
              : 'playback.session_v3.play_track.pending',
          level: _playbackSessionCommandAcknowledgedV3(v3Playback)
              ? 'info'
              : 'warning',
          data: <String, Object?>{
            'track_id': trackId,
            'zone_id': zoneId,
            'elapsed_ms': watch.elapsedMilliseconds,
            'local_fast_start': localStarted,
          },
        );
        return _acceptIncomingPlayback(v3Playback) ? v3Playback : null;
      }
    }
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
    if (_localPlaybackFallbackActive) {
      await _finishOfflinePlayback('previous');
      await _playPreviousOfflineTrack();
      return;
    }
    final zoneId = _activeZoneId();
    final intentId = _beginPlaybackIntent(zoneId, 'previous');
    final localStarted = await _tryStartAdjacentLocalPlayback(
      next: false,
      automatic: false,
      intentId: intentId,
    );
    final playback =
        await _postPlaybackSessionActionV3(zoneId, <String, dynamic>{
          'type': 'previous',
        }, commandId: intentId) ??
        await _postPlaybackControl(
          zoneId,
          '/zones/${Uri.encodeComponent(zoneId)}/previous',
          _playbackCommandBody(const <String, dynamic>{}, intentId: intentId),
        );
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    } else if (!localStarted &&
        _latestPlaybackIntentByZone[zoneId] == intentId) {
      await _playAvailableLocalAgentCandidate(
        next: false,
        automatic: false,
        reason: 'previous_control_failed',
      );
    }
  }

  Future<void> _playNextTrack({bool automatic = false}) async {
    if (_localPlaybackFallbackActive) {
      await _finishOfflinePlayback('next');
      await _playNextOfflineTrack(completed: automatic);
      return;
    }
    final zoneId = _activeZoneId();
    final intentId = _beginPlaybackIntent(zoneId, 'next');
    final localStarted = await _tryStartAdjacentLocalPlayback(
      next: true,
      automatic: automatic,
      intentId: intentId,
    );
    if (automatic &&
        !localStarted &&
        _playbackAgentCandidates(next: true, automatic: true).isEmpty) {
      await _setOfflineStopped(zoneId: zoneId);
      unawaited(_reportRendererStateSafely('stopped'));
      return;
    }
    final currentTrackId = _intValue(_playback?['track_id']);
    final v3Playback = await _postPlaybackSessionActionV3(
      zoneId,
      <String, dynamic>{'type': 'next', 'automatic': automatic},
      commandId: intentId,
    );
    final playback =
        v3Playback ??
        (automatic &&
                _playbackMode == _PlaybackMode.repeatOne &&
                currentTrackId != null
            ? await _playTrackOnZone(
                currentTrackId,
                zoneId,
                tryLocalFastStart: false,
                intentId: intentId,
              )
            : await _postPlaybackControl(
                zoneId,
                '/zones/${Uri.encodeComponent(zoneId)}/next',
                _playbackCommandBody(
                  const <String, dynamic>{},
                  intentId: intentId,
                ),
              ));
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    } else if (!localStarted &&
        _latestPlaybackIntentByZone[zoneId] == intentId) {
      final recovered = await _playAvailableLocalAgentCandidate(
        next: true,
        automatic: automatic,
        reason: automatic ? 'completion_control_failed' : 'next_control_failed',
      );
      if (!recovered && automatic) {
        await _setOfflineStopped(zoneId: zoneId);
      }
    }
  }

  Future<bool> _tryStartAdjacentLocalPlayback({
    required bool next,
    required bool automatic,
    required String intentId,
  }) async {
    if (!_zoneUsesThisClient(_activeZoneId())) {
      return false;
    }
    final candidates = _playbackAgentCandidates(
      next: next,
      automatic: automatic,
    );
    if (candidates.isEmpty) return false;
    final candidate = candidates.first;
    final started = await _tryStartLocalPlayback(
      candidate.trackId,
      zoneId: _activeZoneId(),
      intentId: intentId,
    );
    if (started) {
      _selectPlaybackAgentItem(candidate);
    }
    return started;
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
    try {
      final queue = _asMap(
        await _api.getJson('/zones/${Uri.encodeComponent(targetZoneId)}/queue'),
      );
      if (!mounted || targetZoneId != _activeZoneId()) {
        return;
      }
      _mutatePlayback(() => _applyPlaybackQueue(queue));
      unawaited(_refreshPlaybackSessionV3(zoneId: targetZoneId));
    } catch (_) {
      // Zone refresh and the event stream will retry the queue snapshot.
    }
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
    if (!agent.hasSession) agent.restore(queue);
    if (agent.currentIndex == null) {
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
    if (_localPlaybackFallbackActive) {
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
    final agent = _restorePlaybackAgentQueue();
    if (from >= 0 &&
        from < agent.items.length &&
        to >= 0 &&
        to < agent.items.length) {
      final movedItemId = agent.items[from].itemId;
      final beforeIndex = from < to ? to + 1 : to;
      final beforeItemId = beforeIndex >= 0 && beforeIndex < agent.items.length
          ? agent.items[beforeIndex].itemId
          : null;
      final v3Playback =
          await _postPlaybackSessionActionV3(_activeZoneId(), <String, dynamic>{
            'type': 'move_queue_item',
            'item_id': movedItemId,
            'before_item_id': ?beforeItemId,
          });
      if (v3Playback != null) {
        unawaited(_refreshPlaybackQueue());
        return _playbackQueue;
      }
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
    if (_localPlaybackFallbackActive) {
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
    final legacyItems = _queueItems();
    final legacyIndex = legacyItems.indexWhere(
      (item) => _intValue(item['id']) == itemId,
    );
    final agent = _restorePlaybackAgentQueue();
    if (legacyIndex >= 0 && legacyIndex < agent.items.length) {
      final v3Playback = await _postPlaybackSessionActionV3(
        _activeZoneId(),
        <String, dynamic>{
          'type': 'remove_queue_item',
          'item_id': agent.items[legacyIndex].itemId,
        },
      );
      if (v3Playback != null) {
        unawaited(_refreshPlaybackQueue());
        return _playbackQueue;
      }
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
