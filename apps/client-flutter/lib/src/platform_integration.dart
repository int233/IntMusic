part of '../main.dart';

enum _PlatformCommand {
  play,
  pause,
  togglePlayPause,
  previous,
  next,
  stop,
  showWindow,
  quit,
}

@immutable
class _PlatformCapabilities {
  const _PlatformCapabilities({
    this.systemTray = false,
    this.mediaSession = false,
    this.nativeBackdrop = false,
    this.backgroundPlayback = false,
  });

  final bool systemTray;
  final bool mediaSession;
  final bool nativeBackdrop;
  final bool backgroundPlayback;

  factory _PlatformCapabilities.fromMap(Map<dynamic, dynamic>? value) {
    final map = value ?? const <dynamic, dynamic>{};
    return _PlatformCapabilities(
      systemTray: map['systemTray'] == true,
      mediaSession: map['mediaSession'] == true,
      nativeBackdrop: map['nativeBackdrop'] == true,
      backgroundPlayback: map['backgroundPlayback'] == true,
    );
  }
}

class _IntMusicPlatform {
  _IntMusicPlatform._();

  static final instance = _IntMusicPlatform._();
  static const _channel = MethodChannel('dev.intmusic/platform');

  Future<void> Function(_PlatformCommand command)? _onCommand;
  Future<void> Function(int positionMs)? _onSeek;
  _PlatformCapabilities capabilities = const _PlatformCapabilities();
  bool _initialized = false;

  Future<_PlatformCapabilities> initialize({
    required Future<void> Function(_PlatformCommand command) onCommand,
    required Future<void> Function(int positionMs) onSeek,
  }) async {
    _onCommand = onCommand;
    _onSeek = onSeek;
    _channel.setMethodCallHandler(_handleNativeMethod);
    if (_initialized) {
      return capabilities;
    }
    _initialized = true;
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'initialize',
        const <String, dynamic>{
          'appName': 'IntMusic',
          'trayEnabled': true,
          'hideOnClose': true,
        },
      );
      capabilities = _PlatformCapabilities.fromMap(result);
    } on MissingPluginException {
      capabilities = const _PlatformCapabilities();
    } on PlatformException {
      capabilities = const _PlatformCapabilities();
    }
    return capabilities;
  }

  Future<void> _handleNativeMethod(MethodCall call) async {
    if (call.method == 'seek') {
      final raw = call.arguments;
      final positionMs = raw is num
          ? raw.toInt()
          : _intValue(raw is Map ? raw['positionMs'] : null);
      if (positionMs != null) {
        await _onSeek?.call(positionMs.clamp(0, 1 << 53));
      }
      return;
    }
    final command = switch (call.method) {
      'play' => _PlatformCommand.play,
      'pause' => _PlatformCommand.pause,
      'togglePlayPause' => _PlatformCommand.togglePlayPause,
      'previous' => _PlatformCommand.previous,
      'next' => _PlatformCommand.next,
      'stop' => _PlatformCommand.stop,
      'showWindow' => _PlatformCommand.showWindow,
      'quit' => _PlatformCommand.quit,
      _ => null,
    };
    if (command != null) {
      await _onCommand?.call(command);
    }
  }

  Future<void> updatePlayback({
    required Map<String, dynamic>? playback,
    required Map<String, dynamic>? detail,
  }) async {
    if (!_initialized) {
      return;
    }
    final track = detail == null ? null : _asMap(detail['track']);
    final durationMs = _intValue(track?['duration_ms']) ?? 0;
    final payload = <String, dynamic>{
      'state': playback?['state']?.toString() ?? 'stopped',
      'trackId': _intValue(playback?['track_id']),
      'title':
          track?['title']?.toString() ??
          playback?['track_title']?.toString() ??
          'IntMusic',
      'artist': track?['artist_display']?.toString() ?? '',
      'album': track?['album_title']?.toString() ?? '',
      'durationMs': durationMs,
      'positionMs': _estimatedPlaybackPositionMs(playback),
      'artworkUrl': _trackArtworkUrl(
        _activeCoreBaseUrlForPlatform,
        playback?['track_id'],
      ),
      'canPrevious': true,
      'canNext': true,
    };
    try {
      await _channel.invokeMethod<void>('updatePlayback', payload);
    } on MissingPluginException {
      // Platform integration is optional on unsupported Flutter targets.
    } on PlatformException {
      // Native presentation must never interrupt playback control.
    }
  }

  // Set by the app before publishing media metadata. Keeping the URL in the
  // bridge avoids passing app state through every native sync call.
  String _activeCoreBaseUrlForPlatform = '';

  Future<void> updateVolume(double volume, {required bool muted}) async {
    try {
      await _channel.invokeMethod<void>('updateVolume', <String, dynamic>{
        'volume': volume.clamp(0.0, 1.0),
        'muted': muted,
      });
    } on MissingPluginException {
      // Optional integration.
    } on PlatformException {
      // Optional integration.
    }
  }

  Future<void> moveToBackground() async {
    try {
      await _channel.invokeMethod<void>('moveToBackground');
    } on MissingPluginException {
      if (Platform.isAndroid) {
        await SystemNavigator.pop();
      }
    } on PlatformException {
      if (Platform.isAndroid) {
        await SystemNavigator.pop();
      }
    }
  }

  Future<void> showWindow() async {
    try {
      await _channel.invokeMethod<void>('showWindow');
    } catch (_) {
      // Desktop-only operation.
    }
  }
}
