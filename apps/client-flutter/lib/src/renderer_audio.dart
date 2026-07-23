part of '../main.dart';

bool get _usesDesktopRendererBackend => Platform.isMacOS || Platform.isWindows;

abstract class _RendererAudioPlayer {
  Stream<bool> get completed;

  Future<void> stop();

  Future<void> open(String uri);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);

  Future<int?> currentPositionMs();

  Future<void> dispose();
}

class _MediaKitRendererAudioPlayer implements _RendererAudioPlayer {
  _MediaKitRendererAudioPlayer(this.player);

  final Player player;

  @override
  Stream<bool> get completed => player.stream.completed;

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> open(String uri) => player.open(Media(uri));

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      player.setVolume(volume.clamp(0.0, 1.0) * 100.0);

  @override
  Future<int?> currentPositionMs() async =>
      player.state.position.inMilliseconds;

  @override
  Future<void> dispose() => player.dispose();
}

class _MobileRendererAudioPlayer implements _RendererAudioPlayer {
  _MobileRendererAudioPlayer(this.player);

  final ap.AudioPlayer player;

  @override
  Stream<bool> get completed => player.onPlayerComplete.map((_) => true);

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> open(String uri) => player.play(ap.UrlSource(uri));

  @override
  Future<void> play() => player.resume();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<int?> currentPositionMs() async =>
      (await player.getCurrentPosition())?.inMilliseconds;

  @override
  Future<void> dispose() => player.dispose();
}
