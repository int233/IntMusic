part of '../intmusic_client.dart';

extension _DashboardRendererAudio on _CoreDashboardState {
  Future<_RendererAudioPlayer> _playerForOutput(String outputId) async {
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

  Future<_RendererAudioPlayer> _createRendererPlayer(String outputId) async {
    final device = _rendererAudioDevicesByOutput[outputId];
    if (device == null) {
      throw StateError('audio output is no longer available: $outputId');
    }
    _RendererAudioPlayer? player;
    try {
      if (_usesDesktopRendererBackend) {
        final mediaKitPlayer = Player(
          configuration: const PlayerConfiguration(title: 'IntMusic'),
        );
        player = _MediaKitRendererAudioPlayer(mediaKitPlayer);
        await mediaKitPlayer.setAudioDevice(device);
        await _configureDesktopRendererAudio(mediaKitPlayer, outputId);
        _audioParamsSubscriptions[outputId] = mediaKitPlayer.stream.audioParams
            .distinct()
            .listen((params) {
              ClientLog.event(
                'renderer.player.audio_params',
                data: <String, Object?>{
                  'output_id': outputId,
                  'track_id': _rendererLoadedTrackByOutput[outputId],
                  'format': params.format,
                  'sample_rate': params.sampleRate,
                  'channels': params.channels,
                  'channel_count': params.channelCount,
                  'human_readable_channels': params.hrChannels,
                },
              );
            });
      } else {
        final mobilePlayer = ap.AudioPlayer();
        await mobilePlayer.setReleaseMode(ap.ReleaseMode.stop);
        player = _MobileRendererAudioPlayer(mobilePlayer);
      }
      _audioCompleteSubscriptions[outputId] = player.completed
          .where((completed) => completed)
          .listen((_) {
            _rendererFailoverTimers.remove(outputId)?.cancel();
            unawaited(_handleOutputComplete(outputId).catchError((_) {}));
          });
      _audioPlayingSubscriptions[outputId] = player.playing.distinct().listen((
        playing,
      ) {
        _rendererPlayingByOutput[outputId] = playing;
        if (playing) {
          _rendererFailoverTimers.remove(outputId)?.cancel();
        } else {
          _scheduleRendererSourceFailover(
            outputId,
            reason: 'core_stream_inactive',
          );
        }
        ClientLog.event(
          playing
              ? 'renderer.player.audio_started'
              : 'renderer.player.audio_inactive',
          data: <String, Object?>{
            'output_id': outputId,
            'track_id': _rendererLoadedTrackByOutput[outputId],
          },
        );
      });
      return player;
    } catch (_) {
      await _audioCompleteSubscriptions.remove(outputId)?.cancel();
      await _audioPlayingSubscriptions.remove(outputId)?.cancel();
      await _audioParamsSubscriptions.remove(outputId)?.cancel();
      await player?.dispose();
      rethrow;
    }
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
    final subscription = _audioCompleteSubscriptions.remove(outputId);
    await subscription?.cancel();
    final playingSubscription = _audioPlayingSubscriptions.remove(outputId);
    await playingSubscription?.cancel();
    final paramsSubscription = _audioParamsSubscriptions.remove(outputId);
    await paramsSubscription?.cancel();
    _rendererFailoverTimers.remove(outputId)?.cancel();
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

  Future<void> _handleOutputComplete(String outputId) async {
    final ownsActivePlayback =
        outputId == _offlineOutputForZone(_playback?['zone_id']?.toString());
    if (ownsActivePlayback) {
      if (_localPlaybackFallbackActive &&
          _rendererLocalFileByOutput[outputId] == true) {
        await _finishOfflinePlayback('completed');
      }
      await _playNextTrack(automatic: true);
      return;
    }
    await _reportRendererState('stopped', outputId: outputId);
  }

  void _scheduleRendererSourceFailover(
    String outputId, {
    required String reason,
    Duration delay = const Duration(milliseconds: 800),
  }) {
    if (_rendererLocalFileByOutput[outputId] == true ||
        _rendererLoadedTrackByOutput[outputId] == null) {
      return;
    }
    _rendererFailoverTimers.remove(outputId)?.cancel();
    _rendererFailoverTimers[outputId] = Timer(delay, () {
      _rendererFailoverTimers.remove(outputId);
      unawaited(
        _failoverRendererSource(
          outputId,
          reason: reason,
          requireInactive: true,
        ),
      );
    });
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
      await _runRendererAudioOperation(outputId, 'failover_stop', player.stop);
      await _runRendererAudioOperation(
        outputId,
        'failover_open_local',
        () => player.open(path, localFile: true),
        timeout: const Duration(seconds: 6),
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
