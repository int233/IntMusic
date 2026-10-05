part of '../intmusic_client.dart';

extension _DashboardRendererCommands on _CoreDashboardState {
  Future<void> _refreshSettingsCache() async {
    try {
      final settings = _asMap(await _api.getJson('/settings'));
      if (mounted) {
        _mutate(() {
          _serverSettings = _asMap(settings['server']);
          _favoriteSettings = _asMap(settings['favorites']);
          _metadataSettings = _asMap(settings['metadata']);
          _songDisplaySettings = _asMap(settings['song_display']);
        });
      }
      await _persistOverviewValues({'settings': settings});
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Future<void> _handleRendererCommand(
    Map<String, dynamic> command,
    int operationGeneration,
  ) async {
    final action = command['action']?.toString();
    final outputId = command['target_output_id']?.toString() ?? _clientOutputId;
    if (action == 'play' || action == 'resume') {
      _desiredTransportStateByZone[outputId] = 'playing';
    } else if (action == 'pause') {
      _desiredTransportStateByZone[outputId] = 'paused';
    } else if (action == 'stop') {
      _desiredTransportStateByZone[outputId] = 'stopped';
    }
    try {
      if (action == 'volume' &&
          command['volume_mode']?.toString() == 'system') {
        final volume =
            (command['volume'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 1.0;
        final muted = command['muted'] == true;
        final state = await _setSystemVolumeForOutput(outputId, volume, muted);
        if (!state.supported || !state.writable) {
          throw StateError(
            'System volume is not writable for ${_rendererAudioDeviceLabel(_rendererAudioDevicesByOutput[outputId] ?? AudioDevice.auto())}',
          );
        }
        unawaited(
          _reportRendererSystemVolume(
            outputId,
            state,
            commandSequence: _intValue(command['sequence']),
          ).catchError((Object _) {}),
        );
        return;
      }
      final player = await _playerForOutput(outputId);
      if (action == 'play' || action == 'resume') {
        final zone = _zoneById(outputId);
        final playerVolume =
            (zone?['player_volume'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 1.0;
        final playerMuted = zone?['player_muted'] == true;
        await _runRendererAudioOperation(
          outputId,
          'restore_player_volume',
          () => player.setVolume(playerMuted ? 0.0 : playerVolume),
        );
      }
      if (action != 'volume') {
        _rendererActiveCommandByOutput[outputId] = Map.of(command);
      }
      switch (action) {
        case 'play':
          final streamPath = command['stream_path']?.toString();
          if (streamPath == null || streamPath.isEmpty) {
            throw StateError('missing stream path');
          }
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final trackId = _intValue(command['track_id']);
          final source = await _rendererSource(trackId, streamPath);
          final openWatch = Stopwatch()..start();
          ClientLog.event(
            'renderer.player.open.start',
            data: <String, Object?>{
              'track_id': trackId,
              'output_id': outputId,
              'source': source.localFile ? 'local' : 'core_stream',
            },
          );
          if (trackId != null) {
            _rendererLoadedTrackByOutput[outputId] = trackId;
          }
          await _runRendererAudioOperation(
            outputId,
            'open',
            () => player.open(source.uri, localFile: source.localFile),
            timeout: const Duration(seconds: 15),
          );
          _rendererLocalFileByOutput[outputId] = source.localFile;
          ClientLog.event(
            'renderer.player.open.end',
            data: <String, Object?>{
              'track_id': trackId,
              'output_id': outputId,
              'source': source.localFile ? 'local' : 'core_stream',
              'elapsed_ms': openWatch.elapsedMilliseconds,
            },
          );
          if (positionMs > 0) {
            await _runRendererAudioOperation(
              outputId,
              'seek_after_open',
              () => player.seek(Duration(milliseconds: positionMs)),
            );
          }
          if (_rendererOperationGenerationByOutput[outputId] !=
                  operationGeneration ||
              !_rendererCommandStillExecutable(command)) {
            _dropRendererCommand(command, 'superseded_during_open');
            break;
          }
          if (player.snapshot.phase == RendererPhase.completed) break;
          _reportRendererStateInBackground(
            player.snapshot.transport,
            outputId: outputId,
            command: command,
            positionMs: positionMs,
          );
          break;
        case 'resume':
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final loaded = await _ensureRendererSource(
            player,
            outputId,
            command,
            positionMs,
          );
          if (!loaded) {
            await _runRendererAudioOperation(outputId, 'resume', player.play);
          }
          if (_rendererOperationGenerationByOutput[outputId] !=
                  operationGeneration ||
              !_rendererCommandStillExecutable(command)) {
            _dropRendererCommand(command, 'superseded_during_resume');
            break;
          }
          if (player.snapshot.phase == RendererPhase.completed) break;
          _reportRendererStateInBackground(
            player.snapshot.transport,
            outputId: outputId,
            command: command,
            positionMs: loaded ? positionMs : null,
          );
          break;
        case 'pause':
          await _runRendererAudioOperation(outputId, 'pause', player.pause);
          _reportRendererStateInBackground(
            'paused',
            outputId: outputId,
            command: command,
          );
          break;
        case 'stop':
          await _runRendererAudioOperation(outputId, 'stop', player.stop);
          _rendererLoadedTrackByOutput.remove(outputId);
          _rendererLocalFileByOutput.remove(outputId);
          _reportRendererStateInBackground(
            'stopped',
            outputId: outputId,
            command: command,
          );
          break;
        case 'seek':
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final loaded = await _ensureRendererSource(
            player,
            outputId,
            command,
            positionMs,
          );
          if (!loaded) {
            await _runRendererAudioOperation(
              outputId,
              'seek',
              () => player.seek(Duration(milliseconds: positionMs)),
            );
          }
          if (player.snapshot.phase == RendererPhase.completed) break;
          _reportRendererStateInBackground(
            player.snapshot.transport,
            outputId: outputId,
            command: command,
            positionMs: positionMs,
          );
          break;
        case 'volume':
          final volume =
              (command['volume'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 1.0;
          final muted = command['muted'] == true;
          await _runRendererAudioOperation(
            outputId,
            'volume',
            () => player.setVolume(muted ? 0.0 : volume),
          );
          break;
      }
    } catch (error, stackTrace) {
      _rendererLoadedTrackByOutput.remove(outputId);
      _rendererLocalFileByOutput.remove(outputId);
      ClientLog.error(
        'renderer.command.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'action': action,
          'track_id': _intValue(command['track_id']),
          'output_id': outputId,
        },
      );
      if (mounted) {
        _mutate(() => _error = 'Renderer playback failed: $error');
      }
      if (error is TimeoutException) {
        await _disposeRendererPlayer(outputId);
      }
      _desiredTransportStateByZone[outputId] = 'stopped';
      _reportRendererStateInBackground(
        'stopped',
        outputId: outputId,
        command: command,
      );
    }
  }
}
