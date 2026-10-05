part of '../intmusic_client.dart';

bool get _usesDesktopRendererBackend => Platform.isMacOS || Platform.isWindows;

class _MediaKitRendererAudioPlayer implements AudioEngine {
  _MediaKitRendererAudioPlayer(this.player);

  final Player player;

  @override
  Stream<bool> get completed => player.stream.completed;

  @override
  Stream<bool> get playing => player.stream.playing;
  @override
  Stream<bool> get buffering => player.stream.buffering;
  @override
  Stream<Duration> get position => player.stream.position;
  @override
  Stream<String> get errors => player.stream.error;

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> open(String uri, {bool localFile = false}) =>
      player.open(Media(localFile ? Uri.file(uri).toString() : uri));

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
  Future<int?> durationMs() async => player.state.duration.inMilliseconds;

  @override
  Future<void> dispose() => player.dispose();
}

class _MobileRendererAudioPlayer implements AudioEngine {
  _MobileRendererAudioPlayer(this.player);

  final ap.AudioPlayer player;

  @override
  Stream<bool> get completed => player.onPlayerComplete.map((_) => true);

  @override
  Stream<bool> get playing => player.onPlayerStateChanged.map(
    (state) => state == ap.PlayerState.playing,
  );

  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<Duration> get position => player.onPositionChanged;
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> open(String uri, {bool localFile = false}) =>
      player.play(localFile ? ap.DeviceFileSource(uri) : ap.UrlSource(uri));

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
  Future<int?> durationMs() async =>
      (await player.getDuration())?.inMilliseconds;

  @override
  Future<void> dispose() => player.dispose();
}
