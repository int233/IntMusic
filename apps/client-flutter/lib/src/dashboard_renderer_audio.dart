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
      } else {
        final mobilePlayer = ap.AudioPlayer();
        await mobilePlayer.setReleaseMode(ap.ReleaseMode.stop);
        player = _MobileRendererAudioPlayer(mobilePlayer);
      }
      _audioCompleteSubscriptions[outputId] = player.completed
          .where((completed) => completed)
          .listen((_) {
            unawaited(_handleOutputComplete(outputId).catchError((_) {}));
          });
      _audioPlayingSubscriptions[outputId] = player.playing.distinct().listen((
        playing,
      ) {
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
      await player?.dispose();
      rethrow;
    }
  }

  Future<void> _disposeRendererPlayer(String outputId) async {
    final subscription = _audioCompleteSubscriptions.remove(outputId);
    await subscription?.cancel();
    final playingSubscription = _audioPlayingSubscriptions.remove(outputId);
    await playingSubscription?.cancel();
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
    if (_offlineMode &&
        outputId == _offlineOutputForZone(_playback?['zone_id']?.toString())) {
      await _finishOfflinePlayback('completed');
      await _playNextOfflineTrack(completed: true);
      return;
    }
    await _reportRendererState('stopped', outputId: outputId);
  }

  bool _isClientOutputId(String? outputId) =>
      outputId != null && _rendererAudioDevicesByOutput.containsKey(outputId);
}
