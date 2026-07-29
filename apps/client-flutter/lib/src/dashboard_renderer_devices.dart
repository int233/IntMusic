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
        // Registration is the renderer liveness heartbeat. Never block it on
        // native audio endpoint probing; the independent volume monitor
        // refreshes and reports these capabilities every five seconds.
        final systemVolume =
            _rendererSystemVolumeByOutput[entry.key] ??
            const _SystemVolumeState.unsupported();
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
    await _api.postCriticalJson('/renderers/register', <String, dynamic>{
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

    if (_offlineMode) {
      unawaited(_refreshOfflineRendererZones());
    } else if (_rendererRegisteredCoreUrl != null) {
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

  Future<List<Map<String, dynamic>>> _buildOfflineRendererZones() async {
    await _rendererAudioInitialization;
    final existingByOutput = <String, Map<String, dynamic>>{
      for (final value in _zones.whereType<Map>())
        (_asMap(value)['output_id']?.toString() ??
            _asMap(value)['id']?.toString() ??
            ''): _asMap(
          value,
        ),
    };
    final alias = _clientAlias();
    return Future.wait(
      _rendererAudioDevicesByOutput.entries.map((entry) async {
        final outputId = entry.key;
        final existing = existingByOutput[outputId];
        final systemVolume = await _readSystemVolumeForOutput(
          outputId,
        ).catchError((_) => const _SystemVolumeState.unsupported());
        final rendererPlayback = _rendererPlaybackByOutput[outputId];
        final currentPlaybackOutput = _clientOutputForZone(
          _playback?['zone_id']?.toString() ?? '',
        );
        final playback =
            rendererPlayback ??
            (currentPlaybackOutput == outputId ? _playback : null);
        final playerVolume =
            ((existing?['player_volume'] ?? existing?['volume']) as num?)
                ?.toDouble()
                .clamp(0.0, 1.0) ??
            1.0;
        final playerMuted =
            existing?['player_muted'] == true || existing?['muted'] == true;
        final volumeMode = existing?['volume_mode']?.toString() == 'system'
            ? 'system'
            : 'player';
        final effectiveVolume = volumeMode == 'system' && systemVolume.readable
            ? systemVolume.volume
            : playerVolume;
        final effectiveMuted = volumeMode == 'system' && systemVolume.readable
            ? systemVolume.muted
            : playerMuted;
        return <String, dynamic>{
          'id': outputId,
          'output_id': outputId,
          'name': _rendererAudioDeviceLabel(entry.value),
          'system_name': '$alias - ${_rendererAudioDeviceLabel(entry.value)}',
          'node_name': alias,
          'platform': Platform.operatingSystem,
          'backend': _usesDesktopRendererBackend
              ? 'media-kit-libmpv'
              : 'flutter-audioplayers',
          'is_local_client': true,
          'is_remote': false,
          'is_online': true,
          'is_default': outputId == _clientOutputId,
          'state': playback?['state']?.toString() ?? 'stopped',
          'track_id': playback?['track_id'],
          'track_title': playback?['track_title'],
          'position_ms': playback?['position_ms'] ?? 0,
          'volume': effectiveVolume,
          'muted': effectiveMuted,
          'volume_mode': volumeMode,
          'player_volume': playerVolume,
          'player_muted': playerMuted,
          ...systemVolume.toJson(),
        };
      }),
    );
  }

  Future<void> _refreshOfflineRendererZones() async {
    if (!_offlineMode || !mounted) return;
    final zones = await _buildOfflineRendererZones();
    if (!mounted || !_offlineMode) return;
    _mutatePlayback(() {
      _zones = zones;
      _outputs = zones;
      _keepSelectedZoneValid();
      _selectedZoneLabel = _zoneLabelById(_selectedZoneId);
    });
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
        if (!mounted) return;
        final localOutputs = _rendererAudioDevicesByOutput.keys.toSet();
        var offlineChanged = false;
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
            if (_offlineMode) {
              offlineChanged = true;
            } else {
              await _reportRendererSystemVolume(outputId, current);
            }
          }
        }
        if (offlineChanged) {
          await _refreshOfflineRendererZones();
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
