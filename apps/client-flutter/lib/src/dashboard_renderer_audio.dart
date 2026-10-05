part of '../intmusic_client.dart';

extension _DashboardRendererAudio on _CoreDashboardState {
  Future<RendererSession> _playerForOutput(String outputId) async {
    final existing = _audioPlayers[outputId];
    if (existing != null) {
      return existing;
    }
    final future = _createRendererPlayer(outputId);
    _audioPlayers[outputId] = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_audioPlayers[outputId], future)) {
        _audioPlayers.remove(outputId);
      }
      rethrow;
    }
  }

  Future<RendererSession> _createRendererPlayer(String outputId) async {
    final device = _rendererAudioDevicesByOutput[outputId];
    if (device == null) {
      throw StateError('audio output is no longer available: $outputId');
    }
    final session = RendererSession(
      createEngine: () async {
        if (_usesDesktopRendererBackend) {
          final player = Player(
            configuration: const PlayerConfiguration(title: 'IntMusic'),
          );
          try {
            await player.setAudioDevice(device);
            await _configureDesktopRendererAudio(player, outputId);
            return _MediaKitRendererAudioPlayer(player);
          } catch (_) {
            await player.dispose();
            rethrow;
          }
        }
        final player = ap.AudioPlayer();
        await player.setAudioContext(
          ap.AudioContext(
            android: const ap.AudioContextAndroid(stayAwake: true),
          ),
        );
        await player.setReleaseMode(ap.ReleaseMode.stop);
        return _MobileRendererAudioPlayer(player);
      },
    );
    String? reportedTransport;
    _rendererSessionSubscriptions[outputId] = session.states.listen((snapshot) {
      _rendererSnapshotsByOutput[outputId] = snapshot;
      final command = _rendererActiveCommandByOutput[outputId];
      _rendererPlayingByOutput[outputId] =
          snapshot.phase == RendererPhase.playing;
      if (snapshot.phase == RendererPhase.completed) {
        if (command != null) {
          _applyRendererCommandStateLocally(
            'loading',
            outputId: outputId,
            command: command,
            positionMs: snapshot.positionMs,
          );
        }
        unawaited(
          _handleOutputComplete(outputId, command).catchError((
            Object error,
            StackTrace stack,
          ) {
            ClientLog.error(
              'renderer.completion.failed',
              error,
              stackTrace: stack,
            );
            if (mounted) {
              _mutate(() => _error = 'Could not advance playback: $error');
            }
          }),
        );
        return;
      }
      if (snapshot.phase == RendererPhase.failed) {
        _desiredTransportStateByZone[outputId] = 'stopped';
        if (mounted) {
          _mutate(() => _error = 'Playback failed: ${snapshot.error}');
        }
        ClientLog.event(
          'renderer.decoder.failed',
          level: 'error',
          data: {
            'output_id': outputId,
            'track_id': command?['track_id'],
            'error': snapshot.error,
          },
        );
      }
      // Positions come exclusively from this decoder, including after seeking.
      if (command != null) {
        _applyRendererCommandStateLocally(
          snapshot.transport,
          outputId: outputId,
          command: command,
          positionMs: snapshot.positionMs,
        );
      } else if (_localPlaybackFallbackActive) {
        final previous = _rendererPlaybackByOutput[outputId];
        if (previous != null && mounted) {
          final playback = _withPlaybackTimestamp({
            ...previous,
            'state': snapshot.transport,
            'position_ms': snapshot.positionMs,
          });
          _rendererPlaybackByOutput[outputId] = playback;
          _mutatePlayback(() => _mergePlaybackEvent(playback));
        }
      }
      if (snapshot.transport != reportedTransport) {
        reportedTransport = snapshot.transport;
        if (command != null && !_localPlaybackFallbackActive) {
          _reportRendererStateInBackground(
            snapshot.transport,
            outputId: outputId,
            command: command,
            positionMs: snapshot.positionMs,
          );
        }
      }
    });
    return session;
  }

  Future<void> _configureDesktopRendererAudio(
    Player player,
    String outputId,
  ) async {
    final nativePlayer = player.platform;
    if (nativePlayer is! NativePlayer) {
      ClientLog.event(
        'renderer.player.channel_policy_unavailable',
        level: 'warning',
        data: <String, Object?>{'output_id': outputId},
      );
      return;
    }
    for (final property in rendererAudioOutputPolicy.nativeProperties.entries) {
      await nativePlayer.setProperty(property.key, property.value);
    }
    ClientLog.event(
      'renderer.player.channel_policy_configured',
      data: <String, Object?>{
        'output_id': outputId,
        'channel_layout': rendererAudioOutputPolicy.channelLayout,
        'normalize_downmix': rendererAudioOutputPolicy.normalizeDownmix,
      },
    );
  }

  Future<void> _disposeRendererPlayer(String outputId) async {
    await _rendererSessionSubscriptions.remove(outputId)?.cancel();
    _rendererActiveCommandByOutput.remove(outputId);
    _rendererSnapshotsByOutput.remove(outputId);
    final paramsSubscription = _audioParamsSubscriptions.remove(outputId);
    await paramsSubscription?.cancel();
    _rendererPlayingByOutput.remove(outputId);
    _rendererAudioOperationDepthByOutput.remove(outputId);
    _rendererFailoverBusy.remove(outputId);
    final playerFuture = _audioPlayers.remove(outputId);
    if (playerFuture == null) {
      return;
    }
    try {
      final player = await playerFuture;
      await player.stop();
      await player.dispose();
    } catch (_) {
      // The renderer may already have failed because the device disappeared.
    }
  }

  Future<void> _handleOutputComplete(
    String outputId,
    Map<String, dynamic>? command,
  ) async {
    if (_localPlaybackFallbackActive) {
      await _finishOfflinePlayback('completed');
      await _playNextTrack(automatic: true);
      return;
    }
    final sequence = _intValue(command?['sequence']);
    if (sequence == null) throw StateError('Decoder has no command identity');
    final playback = await _postPlaybackSessionActionV3(outputId, {
      'type': 'complete',
      'command_sequence': sequence,
    });
    if (mounted && playback != null) {
      _mutatePlayback(() => _mergePlaybackEvent(playback));
    }
  }

  Future<void> _failoverActiveCoreStreams(
    String reason, {
    bool requireInactive = false,
  }) async {
    final outputs = _rendererLoadedTrackByOutput.keys
        .where((outputId) => _rendererLocalFileByOutput[outputId] != true)
        .toList(growable: false);
    for (final outputId in outputs) {
      await _failoverRendererSource(
        outputId,
        reason: reason,
        requireInactive: requireInactive,
      );
    }
  }

  Future<bool> _failoverRendererSource(
    String outputId, {
    required String reason,
    required bool requireInactive,
  }) async {
    if (_rendererFailoverBusy.contains(outputId) ||
        (_rendererAudioOperationDepthByOutput[outputId] ?? 0) > 0 ||
        _rendererLocalFileByOutput[outputId] == true ||
        (requireInactive && _rendererPlayingByOutput[outputId] == true)) {
      return false;
    }
    final trackId = _rendererLoadedTrackByOutput[outputId];
    if (trackId == null) return false;
    final desiredState =
        _desiredTransportStateByZone[outputId] ??
        _playback?['state']?.toString();
    if (desiredState != 'playing' && desiredState != 'loading') {
      return false;
    }
    final copy = await _availableOfflineCopy(trackId);
    final path = copy == null
        ? null
        : _offlineCopyPath(copy, _clientLibraryRoots);
    if (path == null || !await File(path).exists()) {
      ClientLog.event(
        'playback.failover.unavailable',
        level: 'warning',
        data: <String, Object?>{
          'track_id': trackId,
          'output_id': outputId,
          'reason': reason,
        },
      );
      return false;
    }

    _rendererFailoverBusy.add(outputId);
    final player = await _playerForOutput(outputId);
    final positionMs =
        await player.currentPositionMs() ??
        _estimatedPlaybackPositionMs(
          _rendererPlaybackByOutput[outputId] ?? _playback,
        );
    final durationMs = await player.durationMs();
    if (durationMs != null &&
        durationMs > 0 &&
        durationMs - positionMs <= 1500) {
      _rendererFailoverBusy.remove(outputId);
      return false;
    }
    ClientLog.event(
      'playback.failover.started',
      level: 'warning',
      data: <String, Object?>{
        'track_id': trackId,
        'output_id': outputId,
        'position_ms': positionMs,
        'reason': reason,
      },
    );
    try {
      await _runRendererAudioOperation(
        outputId,
        'failover_open_local',
        () => player.open(path, localFile: true),
        timeout: const Duration(seconds: 15),
      );
      if (positionMs > 0) {
        await _runRendererAudioOperation(
          outputId,
          'failover_seek',
          () => player.seek(Duration(milliseconds: positionMs)),
        );
      }
      _rendererLocalFileByOutput[outputId] = true;
      _rendererPlayingByOutput[outputId] = true;
      final previous = _rendererPlaybackByOutput[outputId] ?? _playback;
      final playback = _withPlaybackTimestamp(<String, dynamic>{
        ...?previous,
        'zone_id': outputId,
        'state': 'playing',
        'track_id': trackId,
        'position_ms': positionMs,
      });
      _rendererPlaybackByOutput[outputId] = playback;
      if (mounted) {
        _mutatePlayback(() {
          _applyPlayback(playback);
          _rendererStatus = _tr(
            context,
            'Weak connection · switched to local copy',
          );
        });
      }
      ClientLog.event(
        'playback.failover.completed',
        data: <String, Object?>{
          'track_id': trackId,
          'output_id': outputId,
          'position_ms': positionMs,
          'reason': reason,
        },
      );
      return true;
    } catch (error, stackTrace) {
      ClientLog.error(
        'playback.failover.failed',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'track_id': trackId,
          'output_id': outputId,
          'position_ms': positionMs,
          'reason': reason,
        },
      );
      return false;
    } finally {
      _rendererFailoverBusy.remove(outputId);
    }
  }

  bool _isClientOutputId(String? outputId) =>
      outputId != null && _rendererAudioDevicesByOutput.containsKey(outputId);
}
