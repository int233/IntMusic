part of '../intmusic_client.dart';

extension _DashboardRendererCommands on _CoreDashboardState {
  Future<void> _refreshSettingsCache() async {
    try {
      final values = await Future.wait<dynamic>([
        _api.getJson('/settings/server'),
        _api.getJson('/settings/favorites'),
        _api.getJson('/settings/metadata'),
      ]);
      if (mounted) {
        _mutate(() {
          _serverSettings = _asMap(values[0]);
          _favoriteSettings = _asMap(values[1]);
          _metadataSettings = _asMap(values[2]);
        });
      }
      await _persistOverviewValues(<String, dynamic>{
        'settings': <String, dynamic>{
          'server': values[0],
          'favorites': values[1],
          'metadata': values[2],
        },
      });
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
      final intentId = command['intent_id']?.toString();
      if (intentId != null && _locallyAppliedPlaybackIntents.remove(intentId)) {
        _acknowledgeLocallyAppliedRendererCommand(command, outputId);
        return;
      }
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
      switch (action) {
        case 'play':
          final streamPath = command['stream_path']?.toString();
          if (streamPath == null || streamPath.isEmpty) {
            throw StateError('missing stream path');
          }
          final positionMs = _intValue(command['position_ms']) ?? 0;
          final trackId = _intValue(command['track_id']);
          final optimisticTrack = _optimisticLocalTrackByOutput[outputId];
          final optimisticStarted = _optimisticLocalStartedAtByOutput[outputId];
          final reuseOptimisticLocal =
              trackId != null &&
              optimisticTrack == trackId &&
              optimisticStarted != null &&
              DateTime.now().difference(optimisticStarted) <
                  const Duration(seconds: 30) &&
              _rendererLocalFileByOutput[outputId] == true &&
              _desiredTransportStateByZone[outputId] == 'playing' &&
              _rendererCommandStillExecutable(command);
          if (reuseOptimisticLocal) {
            _optimisticLocalTrackByOutput.remove(outputId);
            _optimisticLocalStartedAtByOutput.remove(outputId);
            ClientLog.event(
              'renderer.command.reused_local_fast_start',
              data: <String, Object?>{
                'track_id': trackId,
                'output_id': outputId,
                'command_delay_ms': DateTime.now()
                    .difference(optimisticStarted)
                    .inMilliseconds,
              },
            );
            _reportRendererStateInBackground(
              'playing',
              outputId: outputId,
              command: command,
            );
            break;
          }
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
          await _runRendererAudioOperation(
            outputId,
            'stop_before_open',
            player.stop,
          );
          if (trackId != null) {
            _rendererLoadedTrackByOutput[outputId] = trackId;
          }
          await _runRendererAudioOperation(
            outputId,
            'open',
            () => player.open(source.uri, localFile: source.localFile),
            timeout: source.localFile
                ? const Duration(seconds: 6)
                : const Duration(seconds: 10),
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
          _reportRendererStateInBackground(
            'playing',
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
          _reportRendererStateInBackground(
            'playing',
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
          _optimisticLocalTrackByOutput.remove(outputId);
          _optimisticLocalStartedAtByOutput.remove(outputId);
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
          _reportRendererStateInBackground(
            'playing',
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
      _reportRendererStateInBackground('stopped', outputId: outputId);
    }
  }
}
