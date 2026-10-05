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

  String? _clientOutputForZone(String zoneId) {
    if (_isClientOutputId(zoneId)) return zoneId;
    final outputId = _zoneById(zoneId)?['output_id']?.toString();
    return _isClientOutputId(outputId) ? outputId : null;
  }

  String _offlineOutputForZone([String? zoneId]) =>
      _clientOutputForZone(zoneId ?? _activeZoneId()) ?? _clientOutputId;

  bool _hasActiveRendererSource(String zoneId) {
    final outputId = _clientOutputForZone(zoneId);
    return outputId != null &&
        _audioPlayers.containsKey(outputId) &&
        _rendererLoadedTrackByOutput[outputId] != null;
  }

  void _setOfflineQueue(List<int> trackIds, {int? startIndex, String? zoneId}) {
    final summaries = <int, Map<String, dynamic>>{
      for (final value in _tracks.whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    final validIds = trackIds
        .where((trackId) => summaries.containsKey(trackId))
        .toList(growable: false);
    final targetZoneId = _offlineOutputForZone(zoneId);
    _playbackQueue = <String, dynamic>{
      'zone_id': targetZoneId,
      'revision': (_intValue(_playbackQueue?['revision']) ?? 0) + 1,
      'mode': _playbackMode.nameForApi,
      'shuffle_seed': (_intValue(_playbackQueue?['shuffle_seed']) ?? 1) + 1,
      'current_index':
          startIndex == null || startIndex < 0 || startIndex >= validIds.length
          ? null
          : startIndex,
      'items': <dynamic>[
        for (var index = 0; index < validIds.length; index += 1)
          <String, dynamic>{
            'id': _newPlaybackCommandId(),
            'position': index,
            'track': summaries[validIds[index]],
          },
      ],
    };
    _restorePlaybackAgentQueue(outputId: targetZoneId);
  }

  Future<void> _playOfflineTrack(
    int trackId, {
    List<int>? sourceTrackIds,
    Map<String, dynamic>? queueSource,
    String? zoneId,
  }) async {
    final outputId = _offlineOutputForZone(zoneId);
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
    final summary = _findEntity(_tracks, trackId);
    final cachedDetail =
        _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
    if (summary == null || cachedDetail == null) {
      if (mounted) {
        _mutate(
          () => _error = _tr(
            context,
            'Track metadata is not available in the local projection.',
          ),
        );
      }
      return;
    }
    if (sourceTrackIds != null) {
      _setOfflineQueue(
        sourceTrackIds,
        startIndex: sourceTrackIds.indexOf(trackId),
        zoneId: outputId,
      );
      _playbackQueue = {...?_playbackQueue, 'queue_source': queueSource};
    } else {
      final items = _queueItems();
      final selected = _intValue(_playbackQueue?['current_index']);
      final existingIndex =
          selected != null &&
              selected >= 0 &&
              selected < items.length &&
              _intValue(_asMap(items[selected]['track'])['id']) == trackId
          ? selected
          : items.indexWhere(
              (item) => _intValue(_asMap(item['track'])['id']) == trackId,
            );

      if (existingIndex < 0) {
        _setOfflineQueue(<int>[trackId], startIndex: 0, zoneId: outputId);
      } else {
        _playbackQueue = <String, dynamic>{
          ...?_playbackQueue,
          'current_index': existingIndex,
        };
      }
    }
    final previousOutputId = _offlineOutputForZone(
      _playback?['zone_id']?.toString(),
    );
    await _finishOfflinePlayback('replaced');
    if (previousOutputId != outputId &&
        _rendererLoadedTrackByOutput.containsKey(previousOutputId)) {
      await (await _playerForOutput(previousOutputId)).stop();
      _rendererLoadedTrackByOutput.remove(previousOutputId);
      _rendererLocalFileByOutput.remove(previousOutputId);
      _rendererPlaybackByOutput.remove(previousOutputId);
    }
    final path = _offlineCopyPath(copy, _clientLibraryRoots);
    if (path == null) return;
    _rendererActiveCommandByOutput.remove(outputId);
    final player = await _playerForOutput(outputId);
    await player.stop();
    _rendererLoadedTrackByOutput[outputId] = trackId;
    await player.open(path, localFile: true);
    _rendererLocalFileByOutput[outputId] = true;
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
    final detail = _detailWithLocalCopy(cachedDetail, copy, path);
    final playback = <String, dynamic>{
      'zone_id': outputId,
      'state': 'playing',
      'track_id': trackId,
      'track_title': summary['title'],
      'position_ms': 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
    };
    _rendererPlaybackByOutput[outputId] = playback;
    if (!mounted) return;
    _mutate(() {
      _activeTrackDetailId = trackId;
      _activeTrackDetail = detail;
      _trackDetailCache[trackId] = detail;
      _applyPlayback(playback);
      _error = null;
    });
  }

  Future<void> _finishOfflinePlayback(String reason) async {
    if (!_localPlaybackFallbackActive || _offlinePlaybackStartedAt == null) {
      return;
    }
    final trackId = _intValue(_playback?['track_id']);
    if (trackId == null) return;
    final outputId = _offlineOutputForZone(_playback?['zone_id']?.toString());
    _rendererActiveCommandByOutput.remove(outputId);
    final player = await _playerForOutput(outputId);
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
    final played = await _playAvailableLocalAgentCandidate(
      next: true,
      automatic: completed,
      reason: completed ? 'local_completion' : 'local_next',
    );
    if (!played) {
      await _setOfflineStopped();
    }
  }

  Future<void> _playPreviousOfflineTrack() async {
    await _playAvailableLocalAgentCandidate(
      next: false,
      automatic: false,
      reason: 'local_previous',
    );
  }

  Future<void> _setOfflineStopped({String? zoneId}) async {
    final outputId = _offlineOutputForZone(zoneId);
    _rendererActiveCommandByOutput.remove(outputId);
    final player = await _playerForOutput(outputId);
    await player.stop();
    _rendererLoadedTrackByOutput.remove(outputId);
    _rendererLocalFileByOutput.remove(outputId);
    _rendererPlaybackByOutput.remove(outputId);
    if (!mounted) return;
    _mutatePlayback(() {
      _applyPlayback(<String, dynamic>{
        'zone_id': outputId,
        'state': 'stopped',
        'track_id': null,
        'track_title': null,
        'position_ms': 0,
        'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
      });
    });
  }
}
