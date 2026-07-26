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
        child: _QueueSheet(
          coreBaseUrl: _coreUrlController.text,
          items: _queueItems(),
          currentIndex: _intValue(_playbackQueue?['current_index']),
          onPlayTrack: (trackId) async {
            final playback = await _playTrackOnZone(trackId, _activeZoneId());
            if (mounted && playback != null) {
              _mutatePlayback(() => _applyPlayback(playback));
            }
          },
          onMove: _moveQueueItem,
          onRemove: _removeQueueItem,
          onClearUpcoming: _clearUpcomingQueue,
          onClearAll: _clearEntireQueue,
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
    if (_offlineMode) {
      await _refreshOfflineRendererZones();
      return _currentDeviceSheetSnapshot();
    }
    try {
      final zones = await _api.getJson('/zones') as List<dynamic>;
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
    if (_offlineMode) {
      await _pauseZone(_activeZoneId());
      return;
    }
    await _pauseZone(_activeZoneId());
  }

  Future<void> _resumePlayback() async {
    if (_offlineMode) {
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
    if (_offlineMode) {
      await _finishOfflinePlayback('stopped');
      await _setOfflineStopped(zoneId: zoneId);
      return;
    }
    await _postZoneAction(zoneId, 'stop');
  }

  Future<void> _postZoneAction(String zoneId, String action) async {
    final intentId = _beginPlaybackIntent(zoneId, action);
    final outputId = _clientOutputForZone(zoneId);
    if (outputId != null && _hasActiveRendererSource(zoneId)) {
      final player = await _playerForOutput(outputId);
      final position =
          await player.currentPositionMs() ??
          _estimatedPlaybackPositionMs(_playback);
      switch (action) {
        case 'pause':
          await _runRendererAudioOperation(
            outputId,
            'local_pause',
            player.pause,
          );
        case 'play':
          await _runRendererAudioOperation(
            outputId,
            'local_resume',
            player.play,
          );
        case 'stop':
          await _runRendererAudioOperation(outputId, 'local_stop', player.stop);
          _rendererLoadedTrackByOutput.remove(outputId);
          _rendererLocalFileByOutput.remove(outputId);
          _optimisticLocalTrackByOutput.remove(outputId);
          _optimisticLocalStartedAtByOutput.remove(outputId);
      }
      _markPlaybackIntentAppliedLocally(intentId);
      final localPlayback = _withPlaybackTimestamp(<String, dynamic>{
        ...?_playback,
        'zone_id': zoneId,
        'state': action == 'play'
            ? 'playing'
            : action == 'pause'
            ? 'paused'
            : 'stopped',
        if (action == 'stop') 'track_id': null,
        if (action == 'stop') 'track_title': null,
        'position_ms': action == 'stop' ? 0 : position,
        'origin_client_id': _clientId,
        'intent_id': intentId,
      });
      if (action == 'stop') {
        _rendererPlaybackByOutput.remove(outputId);
      } else {
        _rendererPlaybackByOutput[outputId] = localPlayback;
      }
      if (mounted) {
        _mutatePlayback(() {
          _applyPlayback(localPlayback);
        });
      }
      ClientLog.event(
        'playback.local_control.applied',
        data: <String, Object?>{
          'action': action,
          'zone_id': zoneId,
          'position_ms': position,
        },
      );
    }
    if (_offlineMode) {
      return;
    }
    final playback = await _postPlaybackControl(
      zoneId,
      '/zones/${Uri.encodeComponent(zoneId)}/$action',
      _playbackCommandBody(const <String, dynamic>{}, intentId: intentId),
    );
    if (mounted && playback != null) {
      _mutatePlayback(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<void> _movePlayback(String sourceZoneId, String targetZoneId) async {
    if (sourceZoneId == targetZoneId) {
      return;
    }
    if (_offlineMode) {
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
    if (_offlineMode) {
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
    if (_offlineMode) {
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
    final intentId = _beginPlaybackIntent(zoneId, 'seek');
    final outputId = _clientOutputForZone(zoneId);
    if (outputId != null && _hasActiveRendererSource(zoneId)) {
      final player = await _playerForOutput(outputId);
      await _runRendererAudioOperation(
        outputId,
        'local_seek',
        () => player.seek(Duration(milliseconds: positionMs)),
      );
      _markPlaybackIntentAppliedLocally(intentId);
      final localPlayback = _withPlaybackTimestamp(<String, dynamic>{
        ...?_playback,
        'position_ms': positionMs,
        'origin_client_id': _clientId,
        'intent_id': intentId,
      });
      _rendererPlaybackByOutput[outputId] = localPlayback;
      if (mounted) {
        _mutatePlayback(() {
          _applyPlayback(localPlayback);
        });
      }
    }
    final playback = await _postPlaybackControl(
      zoneId,
      '/zones/${Uri.encodeComponent(zoneId)}/seek',
      _playbackCommandBody(<String, dynamic>{
        'position_ms': positionMs,
      }, intentId: intentId),
    );
    if (mounted && playback != null) {
      _mutatePlayback(() {
        _applyPlayback(playback);
      });
    }
  }

  Future<T> _serializePlaybackRequest<T>(
    String zoneId,
    String intentId,
    Future<T> Function() request,
  ) {
    final previous =
        _playbackRequestQueueByZone[zoneId] ?? Future<void>.value();
    final completer = Completer<T>();
    late final Future<void> queued;
    queued =
        (() async {
          try {
            try {
              await previous;
            } catch (_) {
              // A failed older request must not block a newer user intent.
            }
            final latestIntent = _latestPlaybackIntentByZone[zoneId];
            if (latestIntent != null && latestIntent != intentId) {
              throw _SupersededPlaybackIntent(intentId);
            }
            completer.complete(await request());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        })().whenComplete(() {
          if (identical(_playbackRequestQueueByZone[zoneId], queued)) {
            _playbackRequestQueueByZone.remove(zoneId);
          }
        });
    _playbackRequestQueueByZone[zoneId] = queued;
    return completer.future;
  }

  Future<Map<String, dynamic>?> _postPlaybackControl(
    String zoneId,
    String path,
    Map<String, dynamic> body,
  ) async {
    final watch = Stopwatch()..start();
    ClientLog.event(
      'playback.control.start',
      data: <String, Object?>{'path': path},
    );
    try {
      final result = _asMap(
        await _serializePlaybackRequest<dynamic>(
          zoneId,
          body['intent_id']?.toString() ?? '',
          () => _api.postControlJson(path, body),
        ),
      );
      ClientLog.event(
        'playback.control.end',
        data: <String, Object?>{
          'path': path,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      return _acceptIncomingPlayback(result) ? result : null;
    } on _SupersededPlaybackIntent catch (error) {
      ClientLog.event(
        'playback.control.superseded',
        data: <String, Object?>{
          'path': path,
          'intent_id': error.intentId,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      return null;
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.control.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'path': path,
          'elapsed_ms': watch.elapsedMilliseconds,
        },
      );
      if (mounted) _mutate(() => _rendererStatus = 'Playback link is slow');
      return null;
    }
  }
}
