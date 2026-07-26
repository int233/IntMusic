part of '../intmusic_client.dart';

extension _DashboardOfflinePlayback on _CoreDashboardState {
  Future<_OfflineTrackCopy?> _availableOfflineCopy(int trackId) async {
    final copies = _offlineLibrary.copies.values.where(
      (copy) => copy.trackId == trackId,
    );
    for (final copy in copies) {
      final path = _offlineCopyPath(copy, _clientLibraryRoots);
      if (path != null && await File(path).exists()) {
        return copy;
      }
    }
    return null;
  }

  bool _zoneUsesThisClient(String zoneId) {
    if (_isClientOutputId(zoneId) || zoneId.startsWith(_clientZonePrefix)) {
      return true;
    }
    final zone = _zoneById(zoneId);
    final outputId = zone?['output_id']?.toString();
    return _isClientOutputId(outputId) ||
        (outputId?.startsWith(_clientZonePrefix) ?? false);
  }

  String? _clientOutputForZone(String zoneId) {
    if (_isClientOutputId(zoneId)) return zoneId;
    final outputId = _zoneById(zoneId)?['output_id']?.toString();
    return _isClientOutputId(outputId) ? outputId : null;
  }

  bool _hasActiveRendererSource(String zoneId) {
    final outputId = _clientOutputForZone(zoneId);
    return outputId != null &&
        _audioPlayers.containsKey(outputId) &&
        _rendererLoadedTrackByOutput[outputId] != null;
  }

  /// Starts an accessible local replica before waiting for Core.
  ///
  /// Core remains authoritative for the shared queue and history. The later
  /// renderer command is reconciled without reopening the already-playing
  /// source.
  Future<bool> _tryStartLocalPlayback(
    int trackId, {
    required String zoneId,
    List<int>? sourceTrackIds,
    String? intentId,
  }) async {
    if (!_zoneUsesThisClient(zoneId)) return false;
    final copy = await _availableOfflineCopy(trackId);
    if (copy == null) {
      ClientLog.event(
        'playback.local_fast_start.unavailable',
        data: <String, Object?>{'track_id': trackId, 'zone_id': zoneId},
      );
      return false;
    }
    final path = _offlineCopyPath(copy, _clientLibraryRoots);
    if (path == null || !await File(path).exists()) {
      ClientLog.event(
        'playback.local_fast_start.missing_file',
        level: 'warning',
        data: <String, Object?>{'track_id': trackId, 'zone_id': zoneId},
      );
      return false;
    }

    if (sourceTrackIds != null) {
      _setOfflineQueue(
        sourceTrackIds,
        startIndex: sourceTrackIds.indexOf(trackId),
      );
    } else {
      final items = _queueItems();
      final existingIndex = items.indexWhere(
        (item) => _intValue(_asMap(item['track'])['id']) == trackId,
      );
      if (existingIndex >= 0) {
        _playbackQueue = <String, dynamic>{
          ...?_playbackQueue,
          'current_index': existingIndex,
        };
      }
    }

    final outputId = _isClientOutputId(zoneId)
        ? zoneId
        : (_zoneById(zoneId)?['output_id']?.toString() ?? _clientOutputId);
    final player = await _playerForOutput(outputId);
    final watch = Stopwatch()..start();
    ClientLog.event(
      'playback.local_fast_start.begin',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': zoneId,
        'output_id': outputId,
      },
    );
    try {
      await player.stop();
      _rendererLoadedTrackByOutput[outputId] = trackId;
      await player.open(path, localFile: true);
    } catch (error, stackTrace) {
      if (_rendererLoadedTrackByOutput[outputId] == trackId) {
        _rendererLoadedTrackByOutput.remove(outputId);
      }
      ClientLog.error(
        'playback.local_fast_start.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'zone_id': zoneId,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      return false;
    }
    _rendererLocalFileByOutput[outputId] = true;
    _optimisticLocalTrackByOutput[outputId] = trackId;
    _optimisticLocalStartedAtByOutput[outputId] = DateTime.now();
    if (intentId != null) {
      _markPlaybackIntentAppliedLocally(intentId);
    }

    final summary = _findEntity(_tracks, trackId) ?? copy.toTrackSummary();
    final cachedDetail =
        _trackDetailCache[trackId] ??
        _trackDetailFromOverview(trackId) ??
        copy.toTrackDetail(path);
    final localDetail = _detailWithLocalCopy(cachedDetail, copy, path);
    final playback = _withPlaybackTimestamp(<String, dynamic>{
      'zone_id': zoneId,
      'state': 'playing',
      'track_id': trackId,
      'track_title': summary['title'],
      'position_ms': 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
      'origin_client_id': intentId == null ? null : _clientId,
      'intent_id': intentId,
    });
    _rendererPlaybackByOutput[outputId] = playback;
    if (mounted) {
      _mutatePlayback(() {
        _activeTrackDetailId = trackId;
        _activeTrackDetail = localDetail;
        _trackDetailCache[trackId] = localDetail;
        _applyPlayback(playback);
        _rendererStatus = _tr(
          context,
          'Playing local copy · syncing with Core',
        );
        _error = null;
      });
    }
    ClientLog.event(
      'playback.local_fast_start.ready',
      data: <String, Object?>{
        'track_id': trackId,
        'zone_id': zoneId,
        'output_id': outputId,
        'elapsed_ms': watch.elapsedMilliseconds,
      },
    );
    return true;
  }

  void _setOfflineQueue(List<int> trackIds, {int? startIndex}) {
    final summaries = <int, Map<String, dynamic>>{
      for (final value in _tracks.whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    for (final value in _offlineTrackSummaries(
      _offlineLibrary,
    ).whereType<Map>()) {
      final trackId = _intValue(value['id']);
      if (trackId != null) {
        summaries.putIfAbsent(trackId, () => value.cast<String, dynamic>());
      }
    }
    final validIds = trackIds
        .where((trackId) => summaries.containsKey(trackId))
        .toList(growable: false);
    _playbackQueue = <String, dynamic>{
      'zone_id': _clientOutputId,
      'revision': (_intValue(_playbackQueue?['revision']) ?? 0) + 1,
      'mode': _playbackMode.nameForApi,
      'current_index':
          startIndex == null || startIndex < 0 || startIndex >= validIds.length
          ? null
          : startIndex,
      'items': <dynamic>[
        for (var index = 0; index < validIds.length; index += 1)
          <String, dynamic>{
            'id': -(index + 1),
            'position': index,
            'track': summaries[validIds[index]],
          },
      ],
    };
  }

  Future<void> _playOfflineTrack(
    int trackId, {
    List<int>? sourceTrackIds,
  }) async {
    var copy = await _availableOfflineCopy(trackId);
    if (copy == null) {
      if (mounted) {
        _mutate(
          () => _error = _tr(
            context,
            'No accessible local copy is available for this track.',
          ),
        );
      }
      return;
    }
    if (sourceTrackIds != null) {
      _setOfflineQueue(
        sourceTrackIds,
        startIndex: sourceTrackIds.indexOf(trackId),
      );
    } else {
      final items = _queueItems();
      final existingIndex = items.indexWhere(
        (item) => _intValue(_asMap(item['track'])['id']) == trackId,
      );
      if (existingIndex < 0) {
        _setOfflineQueue(<int>[trackId], startIndex: 0);
      } else {
        _playbackQueue = <String, dynamic>{
          ...?_playbackQueue,
          'current_index': existingIndex,
        };
      }
    }
    await _finishOfflinePlayback('replaced');
    final path = _offlineCopyPath(copy, _clientLibraryRoots);
    if (path == null) return;
    final player = await _playerForOutput(_clientOutputId);
    await player.stop();
    _rendererLoadedTrackByOutput[_clientOutputId] = trackId;
    await player.open(path, localFile: true);
    _rendererLocalFileByOutput[_clientOutputId] = true;
    final measuredDuration = await player.durationMs();
    if ((_intValue(copy.metadata['duration_ms']) ?? 0) <= 0 &&
        measuredDuration != null &&
        measuredDuration > 0) {
      copy = copy.copyWith(durationMs: measuredDuration);
      _offlineLibrary.upsert(copy);
      unawaited(_OfflineLibraryStore.save(_offlineLibrary));
    }
    _offlinePlaybackStartedAt = DateTime.now().toUtc();
    _offlinePlaybackStartPositionMs = 0;
    final summary = _findEntity(_tracks, trackId) ?? copy.toTrackSummary();
    final cachedDetail =
        _trackDetailCache[trackId] ??
        _trackDetailFromOverview(trackId) ??
        copy.toTrackDetail(path);
    final detail = _detailWithLocalCopy(cachedDetail, copy, path);
    final playback = <String, dynamic>{
      'zone_id': _clientOutputId,
      'state': 'playing',
      'track_id': trackId,
      'track_title': summary['title'],
      'position_ms': 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
    };
    if (!mounted) return;
    _mutate(() {
      _replaceTrackInCollections(<String, dynamic>{
        ...summary,
        '_offline': true,
        '_local_available': true,
      });
      _activeTrackDetailId = trackId;
      _activeTrackDetail = detail;
      _trackDetailCache[trackId] = detail;
      _applyPlayback(playback);
      _error = null;
    });
  }

  Future<void> _finishOfflinePlayback(String reason) async {
    if (!_offlineMode || _offlinePlaybackStartedAt == null) return;
    final trackId = _intValue(_playback?['track_id']);
    if (trackId == null) return;
    final player = await _playerForOutput(_clientOutputId);
    final endPosition =
        await player.currentPositionMs() ??
        _estimatedPlaybackPositionMs(_playback);
    final mutation = _OfflineMutation(
      id: _newClientMutationId(),
      kind: 'playback',
      trackId: trackId,
      occurredAt: DateTime.now().toUtc(),
      payload: <String, dynamic>{
        'started_at': _offlinePlaybackStartedAt!.toIso8601String(),
        'ended_at': DateTime.now().toUtc().toIso8601String(),
        'start_position_ms': _offlinePlaybackStartPositionMs,
        'end_position_ms': endPosition,
        'reason': reason,
      },
    );
    _offlineLibrary.outbox.add(mutation);
    _offlineLibrary.incrementPlayCount(trackId);
    _offlinePlaybackStartedAt = null;
    await _OfflineLibraryStore.save(_offlineLibrary);
  }

  Future<void> _playNextOfflineTrack({bool completed = false}) async {
    final items = _queueItems();
    if (items.isEmpty) {
      await _setOfflineStopped();
      return;
    }
    var currentIndex = _intValue(_playbackQueue?['current_index']) ?? -1;
    if (_playbackMode == _PlaybackMode.repeatOne && completed) {
      // Keep the current index.
    } else if (_playbackMode == _PlaybackMode.shuffle && items.length > 1) {
      var next = currentIndex;
      while (next == currentIndex) {
        next = Random.secure().nextInt(items.length);
      }
      currentIndex = next;
    } else {
      currentIndex += 1;
      if (currentIndex >= items.length) {
        if (_playbackMode == _PlaybackMode.repeatAll) {
          currentIndex = 0;
        } else {
          await _setOfflineStopped();
          return;
        }
      }
    }
    final trackId = _intValue(_asMap(items[currentIndex]['track'])['id']);
    if (trackId == null) {
      await _setOfflineStopped();
      return;
    }
    _playbackQueue = <String, dynamic>{
      ...?_playbackQueue,
      'current_index': currentIndex,
    };
    await _playOfflineTrack(trackId);
  }

  Future<void> _playPreviousOfflineTrack() async {
    final items = _queueItems();
    if (items.isEmpty) return;
    var currentIndex = _intValue(_playbackQueue?['current_index']) ?? 0;
    currentIndex -= 1;
    if (currentIndex < 0) {
      currentIndex = _playbackMode == _PlaybackMode.repeatAll
          ? items.length - 1
          : 0;
    }
    final trackId = _intValue(_asMap(items[currentIndex]['track'])['id']);
    if (trackId == null) return;
    _playbackQueue = <String, dynamic>{
      ...?_playbackQueue,
      'current_index': currentIndex,
    };
    await _playOfflineTrack(trackId);
  }

  Future<void> _setOfflineStopped() async {
    final player = await _playerForOutput(_clientOutputId);
    await player.stop();
    _rendererLoadedTrackByOutput.remove(_clientOutputId);
    _rendererLocalFileByOutput.remove(_clientOutputId);
    if (!mounted) return;
    _mutatePlayback(() {
      _applyPlayback(<String, dynamic>{
        'zone_id': _clientOutputId,
        'state': 'stopped',
        'track_id': null,
        'track_title': null,
        'position_ms': 0,
        'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
      });
    });
  }
}
