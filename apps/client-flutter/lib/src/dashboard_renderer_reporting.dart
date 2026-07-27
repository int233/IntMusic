part of '../intmusic_client.dart';

extension _DashboardRendererReporting on _CoreDashboardState {
  Future<T> _runRendererAudioOperation<T>(
    String outputId,
    String operation,
    Future<T> Function() run, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final watch = Stopwatch()..start();
    try {
      final result = await run().timeout(timeout);
      if (watch.elapsed >= const Duration(milliseconds: 500)) {
        ClientLog.event(
          'renderer.player.operation.slow',
          level: 'warning',
          data: <String, Object?>{
            'output_id': outputId,
            'operation': operation,
            'elapsed_ms': watch.elapsedMilliseconds,
          },
        );
      }
      return result;
    } on TimeoutException {
      ClientLog.event(
        'renderer.player.operation.timeout',
        level: 'warning',
        data: <String, Object?>{
          'output_id': outputId,
          'operation': operation,
          'timeout_ms': timeout.inMilliseconds,
        },
      );
      rethrow;
    }
  }

  void _acknowledgeLocallyAppliedRendererCommand(
    Map<String, dynamic> command,
    String outputId,
  ) {
    final action = command['action']?.toString();
    if (action == 'volume') return;
    final state = switch (action) {
      'pause' => 'paused',
      'stop' => 'stopped',
      _ => 'playing',
    };
    _reportRendererStateInBackground(
      state,
      outputId: outputId,
      command: command,
      positionMs: _intValue(command['position_ms']),
    );
    ClientLog.event(
      'renderer.command.local_intent_acknowledged',
      data: <String, Object?>{
        'action': action,
        'output_id': outputId,
        'sequence': _intValue(command['sequence']),
        'intent_id': command['intent_id']?.toString(),
      },
    );
  }

  void _reportRendererStateInBackground(
    String state, {
    String? outputId,
    Map<String, dynamic>? command,
    int? positionMs,
  }) {
    final targetOutputId = outputId ?? _clientOutputId;
    if (command != null) {
      _applyRendererCommandStateLocally(
        state,
        outputId: targetOutputId,
        command: command,
        positionMs: positionMs,
      );
    }
    unawaited(
      _reportRendererStateSafely(
        state,
        outputId: targetOutputId,
        command: command,
        positionMs: positionMs,
      ),
    );
  }

  void _applyRendererCommandStateLocally(
    String state, {
    required String outputId,
    required Map<String, dynamic> command,
    int? positionMs,
  }) {
    final rendererPrevious = _rendererPlaybackByOutput[outputId];
    final visiblePrevious = _playback?['zone_id']?.toString() == outputId
        ? _playback
        : null;
    final previous = rendererPrevious ?? visiblePrevious;
    final snapshot = _withPlaybackTimestamp(<String, dynamic>{
      ...?previous,
      'zone_id': outputId,
      'state': state,
      'track_id': state == 'stopped'
          ? null
          : command['track_id'] ?? previous?['track_id'],
      'track_title': state == 'stopped'
          ? null
          : command['track_title'] ?? previous?['track_title'],
      'position_ms': state == 'stopped'
          ? 0
          : positionMs ??
                _intValue(command['position_ms']) ??
                (previous == null ? 0 : _estimatedPlaybackPositionMs(previous)),
      'queue_revision':
          _intValue(previous?['queue_revision']) ??
          _intValue(_playbackQueue?['revision']) ??
          0,
      'command_sequence': _intValue(command['sequence']),
      'origin_client_id': command['origin_client_id'],
      'intent_id': command['intent_id'],
    });
    if (!_acceptIncomingPlayback(snapshot)) {
      return;
    }
    if (state == 'stopped') {
      _rendererPlaybackByOutput.remove(outputId);
    } else {
      _rendererPlaybackByOutput[outputId] = snapshot;
    }
    if (mounted) {
      _mutatePlayback(() {
        final activeState = _playback?['state']?.toString();
        final activeTrackId = _intValue(_playback?['track_id']);
        final shouldFollowRemotePlay =
            command['action']?.toString() == 'play' &&
            command['origin_client_id']?.toString() != _clientId &&
            outputId != _activeZoneId() &&
            (activeTrackId == null || activeState == 'stopped');
        if (shouldFollowRemotePlay) {
          _selectedZoneId = outputId;
          _selectedZoneLabel = _zoneLabelById(outputId);
        }
        _mergePlaybackEvent(snapshot);
      });
      if (command['action']?.toString() == 'play' &&
          outputId == _activeZoneId()) {
        unawaited(_refreshPlaybackQueue(zoneId: outputId));
      }
    }
  }

  Future<void> _reportRendererStateSafely(
    String state, {
    String? outputId,
    Map<String, dynamic>? command,
    int? positionMs,
  }) async {
    try {
      await _reportRendererState(
        state,
        outputId: outputId,
        command: command,
        positionMs: positionMs,
      );
    } catch (error, stackTrace) {
      ClientLog.error(
        'renderer.state_report.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{'output_id': outputId},
      );
    }
  }

  Future<bool> _ensureRendererSource(
    _RendererAudioPlayer player,
    String outputId,
    Map<String, dynamic> command,
    int positionMs,
  ) async {
    final trackId = _intValue(command['track_id']);
    if (trackId == null || _rendererLoadedTrackByOutput[outputId] == trackId) {
      return false;
    }
    final streamPath = command['stream_path']?.toString();
    if (streamPath == null || streamPath.isEmpty) {
      throw StateError(
        'renderer has no loaded source and command has no stream path',
      );
    }
    await _runRendererAudioOperation(
      outputId,
      'stop_before_ensure_source',
      player.stop,
    );
    final source = await _rendererSource(trackId, streamPath);
    final openWatch = Stopwatch()..start();
    _rendererLoadedTrackByOutput[outputId] = trackId;
    await _runRendererAudioOperation(
      outputId,
      'ensure_source',
      () => player.open(source.uri, localFile: source.localFile),
      timeout: source.localFile
          ? const Duration(seconds: 6)
          : const Duration(seconds: 10),
    );
    _rendererLocalFileByOutput[outputId] = source.localFile;
    ClientLog.event(
      'renderer.player.ensure_source',
      data: <String, Object?>{
        'track_id': trackId,
        'output_id': outputId,
        'source': source.localFile ? 'local' : 'core_stream',
        'elapsed_ms': openWatch.elapsedMilliseconds,
      },
    );
    _rendererLoadedTrackByOutput[outputId] = trackId;
    if (positionMs > 0) {
      await _runRendererAudioOperation(
        outputId,
        'seek_after_ensure_source',
        () => player.seek(Duration(milliseconds: positionMs)),
      );
    }
    return true;
  }

  Future<({String uri, bool localFile})> _rendererSource(
    int? trackId,
    String streamPath,
  ) async {
    if (trackId != null && _clientLibraryRoots.isNotEmpty) {
      final cachedCopy = await _availableOfflineCopy(trackId);
      final cachedPath = cachedCopy == null
          ? null
          : _offlineCopyPath(cachedCopy, _clientLibraryRoots);
      if (cachedPath != null && await File(cachedPath).exists()) {
        ClientLog.event(
          'renderer.source.selected',
          data: <String, Object?>{
            'track_id': trackId,
            'source': 'offline_manifest',
            'local': true,
          },
        );
        return (uri: cachedPath, localFile: true);
      }
      try {
        final media = _asMap(await _api.getJson('/tracks/$trackId/media'));
        final localPath = _resolveClientReplicaPath(
          _clientLibraryRoots,
          media,
          _clientId,
        );
        if (localPath != null && await File(localPath).exists()) {
          ClientLog.event(
            'renderer.source.selected',
            data: <String, Object?>{
              'track_id': trackId,
              'source': 'core_replica_catalog',
              'local': true,
            },
          );
          return (uri: localPath, localFile: true);
        }
      } catch (error, stackTrace) {
        ClientLog.error(
          'renderer.source.catalog_lookup_failed',
          error,
          stackTrace: stackTrace,
          data: <String, Object?>{'track_id': trackId},
        );
        // A catalog lookup failure must not prevent the normal Core stream.
      }
    }
    ClientLog.event(
      'renderer.source.selected',
      data: <String, Object?>{
        'track_id': trackId,
        'source': 'core_stream',
        'local': false,
      },
    );
    return (uri: _api.apiUrl(streamPath), localFile: false);
  }

  Future<void> _reportRendererState(
    String state, {
    String? outputId,
    Map<String, dynamic>? command,
    int? positionMs,
  }) async {
    final targetOutputId = outputId ?? _clientOutputId;
    final previous = _rendererPlaybackByOutput[targetOutputId];
    final operationGenerationBeforeReport =
        _rendererOperationGenerationByOutput[targetOutputId] ?? 0;
    final playerFuture = _audioPlayers[targetOutputId];
    final reportedPosition = playerFuture == null
        ? null
        : await (await playerFuture).currentPositionMs();
    final playerPosition = _stableRendererPositionMs(
      state: state,
      explicitPositionMs: positionMs,
      reportedPositionMs: reportedPosition,
      previous: previous,
    );
    final body = <String, dynamic>{
      'output_id': targetOutputId,
      'state': state,
      'track_id': state == 'stopped'
          ? null
          : command?['track_id'] ??
                previous?['track_id'] ??
                _playback?['track_id'],
      'track_title': state == 'stopped'
          ? null
          : command?['track_title'] ??
                previous?['track_title'] ??
                _playback?['track_title'],
      'position_ms': playerPosition,
      'command_sequence':
          _intValue(command?['sequence']) ??
          _intValue(previous?['command_sequence']),
      'origin_client_id':
          command?['origin_client_id'] ?? previous?['origin_client_id'],
      'intent_id': command?['intent_id'] ?? previous?['intent_id'],
    };
    final playback = _asMap(
      await _api.postJson(
        '/renderers/${Uri.encodeComponent(_clientId)}/state',
        body,
      ),
    );
    final playbackSnapshot = _withPlaybackTimestamp(playback);
    if (!_acceptIncomingPlayback(playbackSnapshot)) {
      return;
    }
    if (state == 'stopped' &&
        (_rendererOperationGenerationByOutput[targetOutputId] ?? 0) ==
            operationGenerationBeforeReport) {
      _rendererLoadedTrackByOutput.remove(targetOutputId);
      _rendererLocalFileByOutput.remove(targetOutputId);
    }
    if (playbackSnapshot['state']?.toString() == 'stopped') {
      _rendererPlaybackByOutput.remove(targetOutputId);
    } else {
      _rendererPlaybackByOutput[targetOutputId] = playbackSnapshot;
    }
    if (mounted) {
      _mutate(() {
        _mergePlaybackEvent(playbackSnapshot);
      });
    }
  }

  int _stableRendererPositionMs({
    required String state,
    required int? explicitPositionMs,
    required int? reportedPositionMs,
    required Map<String, dynamic>? previous,
  }) {
    if (explicitPositionMs != null) {
      return explicitPositionMs;
    }
    if (state == 'stopped') {
      return 0;
    }

    final previousEstimate = previous == null
        ? null
        : _estimatedPlaybackPositionMs(previous);
    final reported = reportedPositionMs;
    if (reported == null) {
      return previousEstimate ?? 0;
    }
    if ((state == 'playing' || state == 'paused') &&
        previousEstimate != null &&
        previousEstimate > 1500 &&
        reported + 1500 < previousEstimate) {
      return previousEstimate;
    }
    return reported;
  }

  Future<void> _reportRendererPositions() async {
    for (final entry in _rendererPlaybackByOutput.entries.toList()) {
      final state = entry.value['state']?.toString();
      final trackId = _intValue(entry.value['track_id']);
      if (trackId == null || (state != 'playing' && state != 'paused')) {
        continue;
      }
      await _reportRendererState(state!, outputId: entry.key);
    }
  }
}
