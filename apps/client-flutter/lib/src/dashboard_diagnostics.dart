part of '../intmusic_client.dart';

extension _DashboardDiagnostics on _CoreDashboardState {
  Future<void> _loadLogIdentity(SharedPreferences preferences) async {
    _logClientId =
        preferences.getString('intmusic.diagnostics.client_id') ?? '';
    if (_logClientId.isNotEmpty) return;
    final random = Random.secure();
    final suffix = List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _logClientId = 'flutter-${Platform.operatingSystem}-$suffix';
    await preferences.setString('intmusic.diagnostics.client_id', _logClientId);
  }

  void _configureRemoteLogging(bool enabled) {
    if (!mounted) return;
    if (_frameTimingsCallback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_frameTimingsCallback!);
      _frameTimingsCallback = null;
    }
    _remoteLoggingEnabled = enabled;
    _logUploader ??= LogUploader((events) async {
      await _api.postJson(
        '/diagnostics/clients/${Uri.encodeComponent(_logClientId)}/logs',
        {'events': events},
        requestTimeout: const Duration(seconds: 4),
      );
    });
    _logUploader!.setEnabled(enabled);
    ClientLog.remoteSink = enabled ? _logUploader!.add : null;
    if (enabled) {
      _frameTimingsCallback = _logSlowFrames;
      SchedulerBinding.instance.addTimingsCallback(_frameTimingsCallback!);
      ClientLog.event(
        'client.log.upload_enabled',
        data: {
          'client_id': _logClientId,
          'renderer_id': _clientId,
          'name': _clientAliasController.text,
          'platform': Platform.operatingSystem,
          'screen_width': MediaQuery.maybeSizeOf(context)?.width,
          'screen_height': MediaQuery.maybeSizeOf(context)?.height,
          'pixel_ratio': MediaQuery.maybeDevicePixelRatioOf(context),
        },
      );
    }
  }

  Future<void> _setRemoteLogging(bool enabled) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    await _loadLogIdentity(preferences);
    await preferences.setBool('intmusic.diagnostics.upload', enabled);
    if (!mounted) return;
    _mutate(() => _configureRemoteLogging(enabled));
  }

  void _logSlowFrames(List<FrameTiming> timings) {
    final slow = timings
        .where((t) => t.totalSpan.inMilliseconds >= 100)
        .toList();
    if (slow.isEmpty) return;
    final now = DateTime.now();
    if (_lastSlowFrameLog != null &&
        now.difference(_lastSlowFrameLog!) < const Duration(seconds: 10)) {
      return;
    }
    _lastSlowFrameLog = now;
    ClientLog.event(
      'ui.slow_frames',
      data: {
        'count': slow.length,
        'max_build_ms': slow
            .map((t) => t.buildDuration.inMilliseconds)
            .reduce(max),
        'max_raster_ms': slow
            .map((t) => t.rasterDuration.inMilliseconds)
            .reduce(max),
        'max_total_ms': slow.map((t) => t.totalSpan.inMilliseconds).reduce(max),
      },
    );
  }

  void _disposeRemoteLogging() {
    if (_frameTimingsCallback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_frameTimingsCallback!);
      _frameTimingsCallback = null;
    }
    _remoteLoggingEnabled = false;
    ClientLog.remoteSink = null;
    _logUploader?.dispose();
  }
}
