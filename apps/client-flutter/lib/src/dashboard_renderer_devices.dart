part of '../intmusic_client.dart';

extension _DashboardRendererDevices on _CoreDashboardState {
  Future<void> _sendRendererRegistration({
    bool resetPlayback = false,
    bool requestPlaybackSync = false,
  }) async {
    await _rendererAudioInitialization;
    final outputPrefix = 'renderer:$_clientId:';
    final rendererOutputs = await Future.wait(
      _rendererAudioDevicesByOutput.entries.map((entry) async {
        final device = entry.value;
        final localOutputId = entry.key.startsWith(outputPrefix)
            ? entry.key.substring(outputPrefix.length)
            : entry.key;
        final systemVolume = await _readSystemVolumeForOutput(entry.key);
        return <String, dynamic>{
          'id': localOutputId,
          'name': _rendererAudioDeviceLabel(device),
          'backend': _usesDesktopRendererBackend
              ? 'media-kit-libmpv'
              : 'flutter-audioplayers',
          'is_default': localOutputId == 'default',
          'sample_rates': <int>[],
          'channels': <int>[],
          ...systemVolume.toJson(),
        };
      }),
    );
    await _api.postJson('/renderers/register', <String, dynamic>{
      'client_id': _clientId,
      'name': _clientAlias(),
      'platform': Platform.operatingSystem,
      'reset_playback': resetPlayback,
      'request_playback_sync': requestPlaybackSync,
      'outputs': rendererOutputs,
    });
    _rendererStatus = 'Renderer online';
  }

  bool get _supportsIndependentAudioOutputs => _usesDesktopRendererBackend;

  Future<void> _initializeRendererAudio() async {
    _rendererAudioDevicesByOutput[_clientOutputId] = AudioDevice.auto();
    if (!_supportsIndependentAudioOutputs) {
      return;
    }

    final ready = Completer<void>();
    final probe = Player(
      configuration: PlayerConfiguration(
        title: 'IntMusic audio device discovery',
        ready: () {
          if (!ready.isCompleted) {
            ready.complete();
          }
        },
      ),
    );
    _rendererDeviceProbe = probe;
    _rendererDeviceSubscription = probe.stream.audioDevices.listen(
      _updateRendererAudioDevices,
      onError: (_) {
        // The default output remains available if native discovery fails.
      },
    );

    try {
      await ready.future.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      // Some libmpv builds publish the device list without invoking ready.
    }
    _updateRendererAudioDevices(probe.state.audioDevices);
  }

  void _updateRendererAudioDevices(List<AudioDevice> devices) {
    final next = <String, AudioDevice>{_clientOutputId: AudioDevice.auto()};
    final seenNativeNames = <String>{};
    for (final device in devices) {
      final nativeName = device.name.trim();
      final normalizedName = nativeName.toLowerCase();
      if (nativeName.isEmpty ||
          normalizedName == 'auto' ||
          normalizedName == 'no' ||
          !_isNativeRendererAudioDevice(normalizedName) ||
          !seenNativeNames.add(nativeName)) {
        continue;
      }
      next[_rendererOutputIdForDevice(device)] = device;
    }

    final previousSignature = _rendererDeviceSignature(
      _rendererAudioDevicesByOutput,
    );
    final nextSignature = _rendererDeviceSignature(next);
    if (previousSignature == nextSignature) {
      return;
    }

    final removedOutputIds = _rendererAudioDevicesByOutput.keys
        .where((outputId) => !next.containsKey(outputId))
        .toList(growable: false);
    _rendererAudioDevicesByOutput
      ..clear()
      ..addAll(next);
    for (final outputId in removedOutputIds) {
      unawaited(_disposeRendererPlayer(outputId));
      _rendererPlaybackByOutput.remove(outputId);
      _rendererLoadedTrackByOutput.remove(outputId);
      _rendererSystemVolumeByOutput.remove(outputId);
    }

    if (_rendererRegisteredCoreUrl != null) {
      unawaited(
        _sendRendererRegistration()
            .then((_) => _refreshZonesSilently())
            .catchError((Object _) {}),
      );
    }
  }

  bool _isNativeRendererAudioDevice(String normalizedName) {
    if (Platform.isWindows) {
      return normalizedName.startsWith('wasapi/');
    }
    if (Platform.isMacOS) {
      return normalizedName.startsWith('coreaudio/');
    }
    return true;
  }

  String _rendererDeviceSignature(Map<String, AudioDevice> devices) {
    final entries =
        devices.entries
            .map(
              (entry) =>
                  '${entry.key}\u0000${entry.value.name}\u0000'
                  '${entry.value.description}',
            )
            .toList()
          ..sort();
    return entries.join('\u0001');
  }

  String _rendererOutputIdForDevice(AudioDevice device) {
    final encodedName = base64Url
        .encode(utf8.encode(device.name))
        .replaceAll('=', '');
    return 'renderer:$_clientId:device-$encodedName';
  }

  String _rendererAudioDeviceLabel(AudioDevice device) {
    if (device.name == 'auto') {
      return 'System Default';
    }
    final description = device.description.trim();
    return description.isEmpty ? device.name : description;
  }

  Future<_SystemVolumeState> _readSystemVolumeForOutput(String outputId) async {
    final device = _rendererAudioDevicesByOutput[outputId];
    if (device == null) {
      return const _SystemVolumeState.unsupported();
    }
    final state = await _IntMusicPlatform.instance.getSystemVolume(
      outputName: device.name,
      outputDescription: device.description,
      isDefault: device.name == 'auto' || outputId == _clientOutputId,
    );
    _rendererSystemVolumeByOutput[outputId] = state;
    return state;
  }

  Future<_SystemVolumeState> _setSystemVolumeForOutput(
    String outputId,
    double volume,
    bool muted,
  ) async {
    final device = _rendererAudioDevicesByOutput[outputId];
    if (device == null) {
      return const _SystemVolumeState.unsupported();
    }
    final state = await _IntMusicPlatform.instance.setSystemVolume(
      outputName: device.name,
      outputDescription: device.description,
      isDefault: device.name == 'auto' || outputId == _clientOutputId,
      volume: volume,
      muted: muted,
    );
    _rendererSystemVolumeByOutput[outputId] = state;
    return state;
  }

  Future<void> _reportRendererSystemVolume(
    String outputId,
    _SystemVolumeState state, {
    int? commandSequence,
  }) async {
    final localOutputId = outputId.startsWith(_clientZonePrefix)
        ? outputId.substring(_clientZonePrefix.length)
        : outputId;
    await _api.postJson(
      '/renderers/${Uri.encodeComponent(_clientId)}/volume-state',
      <String, dynamic>{
        'output_id': localOutputId,
        'volume': state.volume,
        'muted': state.muted,
        'supported': state.supported,
        'readable': state.readable,
        'writable': state.writable,
        if (state.steps != null) 'steps': state.steps,
        'command_sequence': ?commandSequence,
      },
    );
  }

  void _startRendererHeartbeat() {
    _startSystemVolumeMonitor();
    _taskScheduler.schedule(
      'renderer-heartbeat',
      interval: const Duration(seconds: 15),
      runInBackground: true,
      callback: _sendRendererRegistration,
      onError: (_, _) {
        if (mounted) {
          _mutate(() => _rendererStatus = 'Renderer offline');
        }
      },
    );
  }

  void _startSystemVolumeMonitor() {
    _taskScheduler.schedule(
      'system-volume',
      interval: const Duration(seconds: 5),
      runInBackground: true,
      callback: () async {
        if (_offlineMode || !mounted) return;
        final localOutputs = _rendererAudioDevicesByOutput.keys.toSet();
        for (final outputId in localOutputs) {
          final previous = _rendererSystemVolumeByOutput[outputId];
          final current = await _readSystemVolumeForOutput(outputId);
          final changed =
              previous == null ||
              previous.supported != current.supported ||
              previous.writable != current.writable ||
              previous.muted != current.muted ||
              (previous.volume - current.volume).abs() >= 0.005;
          if (changed) {
            await _reportRendererSystemVolume(outputId, current);
          }
        }
      },
      onError: (_, _) {
        // Endpoint polling is best-effort and must not affect playback.
      },
    );
  }

  void _startRendererPositionReporter() {
    _taskScheduler.schedule(
      'renderer-position',
      interval: const Duration(seconds: 5),
      runInBackground: true,
      callback: _reportRendererPositions,
    );
  }

  void _startZoneRefresh() {
    _taskScheduler.schedule(
      'zone-refresh',
      interval: const Duration(seconds: 6),
      callback: _refreshZonesSilently,
    );
  }

  void _startDistributionWorker() {
    _taskScheduler.schedule(
      'distribution',
      interval: const Duration(seconds: 5),
      runImmediately: true,
      runInBackground: true,
      callback: _pollDistributionTasks,
    );
  }

  Future<void> _refreshDistributionJobs() async {
    try {
      final jobs =
          await _api.getJson('/distributions?limit=100') as List<dynamic>;
      if (mounted) {
        _mutate(() => _distributionJobs = jobs);
      } else {
        _distributionJobs = jobs;
      }
    } catch (_) {
      // Distribution is additive; older Core versions can still be controlled.
    }
  }
}
