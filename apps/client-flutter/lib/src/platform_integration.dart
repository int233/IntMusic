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
    this.titlebarSafeInset = 0,
  });

  final bool systemTray;
  final bool mediaSession;
  final bool nativeBackdrop;
  final bool backgroundPlayback;
  final double titlebarSafeInset;

  factory _PlatformCapabilities.fromMap(Map<dynamic, dynamic>? value) {
    final map = value ?? const <dynamic, dynamic>{};
    return _PlatformCapabilities(
      systemTray: map['systemTray'] == true,
      mediaSession: map['mediaSession'] == true,
      nativeBackdrop: map['nativeBackdrop'] == true,
      backgroundPlayback: map['backgroundPlayback'] == true,
      titlebarSafeInset:
          (map['titlebarSafeInset'] as num?)?.toDouble().clamp(0, 200) ?? 0,
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
  final ValueNotifier<double> titlebarSafeInset = ValueNotifier(0);
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
      titlebarSafeInset.value = capabilities.titlebarSafeInset;
    } on MissingPluginException {
      capabilities = const _PlatformCapabilities();
    } on PlatformException {
      capabilities = const _PlatformCapabilities();
    }
    return capabilities;
  }

  Future<void> _handleNativeMethod(MethodCall call) async {
    if (call.method == 'windowMetricsChanged') {
      final raw = call.arguments;
      final value = raw is Map ? raw['titlebarSafeInset'] : null;
      if (value is num) {
        titlebarSafeInset.value = value.toDouble().clamp(0, 200);
      }
      return;
    }
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

  Future<({String path, String? token})> persistFolderAccess(
    String path,
  ) async {
    if (!Platform.isMacOS) {
      return (path: path, token: null);
    }
    try {
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'createSecurityScopedBookmark',
        <String, dynamic>{'path': path},
      );
      return (
        path: result?['path']?.toString() ?? path,
        token: result?['bookmark']?.toString(),
      );
    } catch (_) {
      return (path: path, token: null);
    }
  }

  Future<({String path, String? token})> restoreFolderAccess(
    String path,
    String? token,
  ) async {
    if ((!Platform.isMacOS && !Platform.isAndroid) ||
        token == null ||
        token.isEmpty) {
      return (path: path, token: token);
    }
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMapMethod<dynamic, dynamic>(
          'restoreClientLibraryFolder',
          <String, dynamic>{'path': path, 'bookmark': token},
        );
        return (
          path: result?['path']?.toString() ?? path,
          token: result?['bookmark']?.toString() ?? token,
        );
      }
      final result = await _channel.invokeMapMethod<dynamic, dynamic>(
        'resolveSecurityScopedBookmark',
        <String, dynamic>{'path': path, 'bookmark': token},
      );
      return (
        path: result?['path']?.toString() ?? path,
        token: result?['bookmark']?.toString() ?? token,
      );
    } catch (_) {
      return (path: path, token: token);
    }
  }

  Future<({String path, String token, String displayName})?>
  selectClientLibraryFolder() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'selectClientLibraryFolder',
    );
    final path = result?['path']?.toString();
    final token = result?['bookmark']?.toString();
    if (path == null ||
        path.trim().isEmpty ||
        token == null ||
        token.trim().isEmpty) {
      return null;
    }
    return (
      path: path,
      token: token,
      displayName:
          result?['displayName']?.toString() ?? _localRootDisplayName(path),
    );
  }

  Future<_DistributionDownloadResult> downloadDistributionTask({
    required String apiUrl,
    required String taskId,
    required String? rootToken,
    required String relativePath,
    required int expectedSize,
    required String? expectedQuickHash,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Native distribution download is only used on Android',
      );
    }
    if (rootToken == null || rootToken.isEmpty) {
      throw const FileSystemException(
        'The Android destination folder permission is missing',
      );
    }
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'downloadDistributionTask',
      <String, dynamic>{
        'apiUrl': apiUrl,
        'taskId': taskId,
        'bookmark': rootToken,
        'relativePath': relativePath,
        'expectedSize': expectedSize,
        'expectedQuickHash': expectedQuickHash,
      },
    );
    final bytes = _intValue(result?['bytes']);
    final quickHash = result?['quickHash']?.toString();
    if (bytes == null || quickHash == null || quickHash.isEmpty) {
      throw const FileSystemException(
        'Android did not return a verified distribution result',
      );
    }
    return _DistributionDownloadResult(bytes: bytes, quickHash: quickHash);
  }

  Future<int> uploadDistributionSource({
    required String apiUrl,
    required String taskId,
    required String? rootToken,
    required String relativePath,
    required int expectedSize,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Native distribution upload is only used on Android',
      );
    }
    if (rootToken == null || rootToken.isEmpty) {
      throw const FileSystemException(
        'The Android source folder permission is missing',
      );
    }
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'uploadDistributionSource',
      <String, dynamic>{
        'apiUrl': apiUrl,
        'taskId': taskId,
        'bookmark': rootToken,
        'relativePath': relativePath,
        'expectedSize': expectedSize,
      },
    );
    final bytes = _intValue(result?['bytes']);
    if (bytes == null || bytes != expectedSize) {
      throw const FileSystemException(
        'Android did not upload the expected source size',
      );
    }
    return bytes;
  }
}
