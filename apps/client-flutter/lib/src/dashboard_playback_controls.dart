part of '../intmusic_client.dart';

extension _DashboardPlaybackControls on _CoreDashboardState {
  void _showPlaybackModeMenu(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 320,
        maxHeight: 340,
        child: _ModeSheet(
          playbackMode: _playbackMode,
          onSelected: (mode) {
            Navigator.of(anchorContext).pop();
            unawaited(_setPlaybackMode(mode));
          },
        ),
      ),
    );
  }

  void _showNavigationSheet(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 320,
        maxHeight: 560,
        child: _NavigationSheet(
          selectedIndex: _selectedDestinationIndex,
          onSelected: (index) {
            Navigator.of(anchorContext).pop();
            _setSelectedIndex(index);
          },
        ),
      ),
    );
  }

  void _showQueueSheet(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 460,
        maxHeight: 560,
        child: ListenableBuilder(
          listenable: _songDisplayState,
          builder: (context, _) => _QueueSheet(
            displayState: _songDisplayState,
            sourceName: _asMap(
              _playbackQueue?['queue_source'],
            )['name']?.toString(),
            mergeSameName: _songDisplaySettings['merge_same_name'] == true,
            coreBaseUrl: _coreUrlController.text,
            items: _queueItems(),
            currentIndex: _intValue(_playbackQueue?['current_index']),
            onPlayTrack: _playQueueItem,
            onMove: _moveQueueItem,
            onRemove: _removeQueueItem,
            onClearUpcoming: _clearUpcomingQueue,
            onClearAll: _clearEntireQueue,
          ),
        ),
      ),
    );
  }

  void _showDeviceSheet(BuildContext anchorContext) {
    unawaited(
      _showAnchoredPopup<void>(
        context: anchorContext,
        anchorContext: anchorContext,
        width: 620,
        maxHeight: 620,
        child: _DeviceSheet(
          snapshot: _currentDeviceSheetSnapshot(),
          currentClientZonePrefix: _clientZonePrefix,
          pinCurrentClientRegion: _pinCurrentClientRegion,
          regionSort: _zoneRegionSort,
          onRefresh: _refreshDeviceSheetSnapshot,
          onSelect: _selectZone,
          onResume: _resumeZone,
          onPause: _pauseZone,
          onStop: _stopZone,
          onMoveHere: (targetZoneId) =>
              _movePlayback(_activeZoneId(), targetZoneId),
          onPlayEverywhere: _playCurrentEverywhere,
          onStopEverywhere: _stopEverywhere,
          onRename: _renameZone,
        ),
      ),
    );
  }

  _DeviceSheetSnapshot _currentDeviceSheetSnapshot() => _DeviceSheetSnapshot(
    zones: _zones,
    selectedZoneId: _selectedZoneId,
    activeZoneId: _activeZoneId(),
    hasActiveTrack: _playback?['track_id'] != null,
  );

  Future<_DeviceSheetSnapshot> _refreshDeviceSheetSnapshot() async {
    if (_localPlaybackFallbackActive) {
      await _refreshOfflineRendererZones();
      return _currentDeviceSheetSnapshot();
    }
    try {
      final zones = await _api.getCriticalJson('/zones') as List<dynamic>;
      if (mounted) {
        _mutatePlayback(() {
          _zones = zones;
          _keepSelectedZoneValid();
          _syncPlaybackFromSelectedZone();
        });
      }
    } catch (_) {
      // Visible connection errors are owned by the main refresh path.
    }
    return _currentDeviceSheetSnapshot();
  }

  Future<void> _pausePlayback() async {
    if (_localPlaybackFallbackActive) {
      await _pauseZone(_activeZoneId());
      return;
    }
    await _pauseZone(_activeZoneId());
  }

  Future<void> _resumePlayback() async {
    if (_localPlaybackFallbackActive) {
      final trackId = _intValue(_playback?['track_id']);
      if (trackId == null) {
        final items = _queueItems();
        if (items.isNotEmpty) {
          final index = _intValue(_playbackQueue?['current_index']) ?? 0;
          final nextTrackId = _intValue(
            _asMap(items[index.clamp(0, items.length - 1)]['track'])['id'],
          );
          if (nextTrackId != null) await _playOfflineTrack(nextTrackId);
        }
        return;
      }
      await _resumeZone(_activeZoneId());
      return;
    }
    await _resumeZone(_activeZoneId());
  }

  Future<void> _pauseZone(String zoneId) async {
    await _postZoneAction(zoneId, 'pause');
  }

  Future<void> _resumeZone(String zoneId) async {
    await _postZoneAction(zoneId, 'play');
  }

  Future<void> _stopZone(String zoneId) async {
    if (_localPlaybackFallbackActive) {
      await _finishOfflinePlayback('stopped');
      await _setOfflineStopped(zoneId: zoneId);
      return;
    }
    await _postZoneAction(zoneId, 'stop');
  }

  Future<void> _postZoneAction(String zoneId, String action) async {
    if (_localPlaybackFallbackActive) {
      final outputId = _offlineOutputForZone(zoneId);
      final player = await _playerForOutput(outputId);
      switch (action) {
        case 'play':
          await player.play();
        case 'pause':
          await player.pause();
        case 'stop':
          await player.stop();
      }
      return;
    }
    final playback = await _postPlaybackSessionActionV3(zoneId, {
      'type': action,
      if (action == 'play') 'position_ms': 0,
    }, commandId: _beginPlaybackIntent(zoneId, action));
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }

  Future<void> _movePlayback(String sourceZoneId, String targetZoneId) async {
    if (sourceZoneId == targetZoneId) {
      return;
    }
    if (_localPlaybackFallbackActive) {
      final trackId = _intValue(_playback?['track_id']);
      if (trackId == null) return;
      final position = _estimatedPlaybackPositionMs(_playback);
      await _playOfflineTrack(trackId, zoneId: targetZoneId);
      await _seekPlayback(position);
      return;
    }
    final states = await _run<List<dynamic>>(
      () async =>
          await _api.postJson(
                '/zones/${Uri.encodeComponent(sourceZoneId)}/transfer',
                <String, dynamic>{'target_zone_id': targetZoneId},
              )
              as List<dynamic>,
    );
    if (!mounted || states == null) {
      return;
    }
    final stateMaps = states
        .map((state) => (state as Map).cast<String, dynamic>())
        .toList(growable: false);
    final targetState = stateMaps.firstWhere(
      (state) => state['zone_id']?.toString() == targetZoneId,
      orElse: () => stateMaps.first,
    );
    _mutatePlayback(() {
      for (final state in stateMaps) {
        _upsertZoneFromPlayback(state);
      }
      _selectedZoneId = targetZoneId;
      _selectedZoneLabel = _zoneLabelById(targetZoneId);
      _applyPlayback(targetState, syncZone: false);
    });
  }

  Future<void> _playCurrentEverywhere() async {
    final trackId = _intValue(_playback?['track_id']);
    if (trackId == null) {
      return;
    }
    if (_localPlaybackFallbackActive) {
      if (mounted) {
        _mutate(
          () => _error =
              'Synchronized multi-output playback requires a Core connection',
        );
      }
      return;
    }
    final zoneIds = _onlineZoneIds();
    if (zoneIds.isEmpty) {
      return;
    }
    final states = await _run<List<dynamic>>(
      () async =>
          await _api.postJson('/zones/play-many', <String, dynamic>{
                'track_id': trackId,
                'zone_ids': zoneIds,
                'position_ms': _estimatedPlaybackPositionMs(_playback),
              })
              as List<dynamic>,
    );
    if (!mounted || states == null || states.isEmpty) {
      return;
    }
    final stateMaps = states
        .map((state) => (state as Map).cast<String, dynamic>())
        .toList(growable: false);
    final preferred = stateMaps.firstWhere(
      (state) => state['zone_id']?.toString() == _selectedZoneId,
      orElse: () => stateMaps.first,
    );
    _mutatePlayback(() {
      for (final state in stateMaps) {
        _upsertZoneFromPlayback(state);
      }
      _applyPlayback(preferred, syncZone: false);
    });
  }

  Future<void> _seekPlayback(int positionMs) async {
    if (_localPlaybackFallbackActive) {
      final outputId = _offlineOutputForZone();
      final player = await _playerForOutput(outputId);
      await player.seek(Duration(milliseconds: positionMs));
      final localPlayback = _withPlaybackTimestamp(<String, dynamic>{
        ...?_playback,
        'position_ms': positionMs,
      });
      _rendererPlaybackByOutput[outputId] = localPlayback;
      if (mounted) {
        _mutatePlayback(() {
          _applyPlayback(localPlayback);
        });
      }
      return;
    }
    final zoneId = _activeZoneId();
    final playback = await _postPlaybackSessionActionV3(zoneId, {
      'type': 'seek',
      'position_ms': positionMs,
    }, commandId: _beginPlaybackIntent(zoneId, 'seek'));
    if (mounted && playback != null) {
      _mutatePlayback(() => _applyPlayback(playback));
    }
  }
}
