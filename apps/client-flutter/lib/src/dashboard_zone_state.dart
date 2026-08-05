part of '../intmusic_client.dart';

extension _DashboardZoneState on _CoreDashboardState {
  double _activeZoneVolume() {
    final zone = _zoneById(_activeZoneId());
    return ((zone?['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
  }

  bool _activeZoneMuted() => _zoneById(_activeZoneId())?['muted'] == true;

  String _activeZoneVolumeMode() =>
      _zoneById(_activeZoneId())?['volume_mode']?.toString() == 'system'
      ? 'system'
      : 'player';

  bool _activeZoneSystemVolumeSupported() {
    final zone = _zoneById(_activeZoneId());
    return zone?['system_volume_supported'] == true &&
        zone?['system_volume_writable'] == true;
  }

  double _activeZoneVolumeForMode(String mode) {
    final zone = _zoneById(_activeZoneId());
    final key = mode == 'system' ? 'system_volume' : 'player_volume';
    return ((zone?[key] as num?)?.toDouble() ?? _activeZoneVolume()).clamp(
      0.0,
      1.0,
    );
  }

  bool _activeZoneMutedForMode(String mode) {
    final zone = _zoneById(_activeZoneId());
    final key = mode == 'system' ? 'system_muted' : 'player_muted';
    return zone?[key] == true;
  }

  Future<void> _setActiveZoneVolumeMode(String mode) async {
    final normalizedMode = mode == 'system' ? 'system' : 'player';
    if (normalizedMode == 'system' && !_activeZoneSystemVolumeSupported()) {
      return;
    }
    if (normalizedMode == 'system') {
      final localOutputId = _clientOutputForZone(_activeZoneId());
      if (localOutputId != null) {
        final current = await _readSystemVolumeForOutput(localOutputId);
        if (current.supported && current.writable) {
          await _setActiveZoneVolume(
            current.volume,
            muted: current.muted,
            mode: normalizedMode,
          );
          return;
        }
      }
    }
    await _setActiveZoneVolume(
      _activeZoneVolumeForMode(normalizedMode),
      muted: _activeZoneMutedForMode(normalizedMode),
      mode: normalizedMode,
    );
  }

  Future<void> _setActiveZoneVolume(
    double volume, {
    bool? muted,
    String? mode,
  }) async {
    final zoneId = _activeZoneId();
    final intentId = _beginPlaybackIntent(zoneId, 'volume');
    final volumeMode = mode ?? _activeZoneVolumeMode();
    final normalized = volume.clamp(0.0, 1.0);
    final effectiveMuted = muted ?? (normalized <= 0.001);
    if (_offlineMode) {
      final localOutputId = _clientOutputForZone(zoneId);
      if (localOutputId == null) {
        return;
      }
      _SystemVolumeState? appliedSystemVolume;
      if (volumeMode == 'system') {
        appliedSystemVolume = await _setSystemVolumeForOutput(
          localOutputId,
          normalized,
          effectiveMuted,
        );
        if (!appliedSystemVolume.supported || !appliedSystemVolume.writable) {
          if (mounted) {
            _mutate(
              () => _error = 'System volume is unavailable for this output',
            );
          }
          return;
        }
      } else {
        final player = await _playerForOutput(localOutputId);
        await player.setVolume(effectiveMuted ? 0 : normalized);
      }
      if (mounted) {
        _mutatePlayback(() {
          _zones = _zones
              .map((value) {
                final zone = _asMap(value);
                if (zone['id']?.toString() != zoneId) return zone;
                return <String, dynamic>{
                  ...zone,
                  'volume': appliedSystemVolume?.volume ?? normalized,
                  'muted': appliedSystemVolume?.muted ?? effectiveMuted,
                  'volume_mode': volumeMode,
                  if (volumeMode == 'system')
                    'system_volume': appliedSystemVolume?.volume ?? normalized
                  else
                    'player_volume': normalized,
                  if (volumeMode == 'system')
                    'system_muted': appliedSystemVolume?.muted ?? effectiveMuted
                  else
                    'player_muted': effectiveMuted,
                };
              })
              .toList(growable: false);
        });
      }
      return;
    }
    final localOutputId = _clientOutputForZone(zoneId);
    _SystemVolumeState? appliedSystemVolume;
    if (localOutputId != null &&
        (volumeMode == 'system' || _hasActiveRendererSource(zoneId))) {
      if (volumeMode == 'system') {
        appliedSystemVolume = await _setSystemVolumeForOutput(
          localOutputId,
          normalized,
          effectiveMuted,
        );
        if (!appliedSystemVolume.supported || !appliedSystemVolume.writable) {
          if (mounted) {
            _mutate(
              () => _error = 'System volume is unavailable for this output',
            );
          }
          return;
        }
      } else {
        final player = await _playerForOutput(localOutputId);
        await _runRendererAudioOperation(
          localOutputId,
          'local_volume',
          () => player.setVolume(effectiveMuted ? 0 : normalized),
        );
      }
      _markPlaybackIntentAppliedLocally(intentId);
      if (mounted) {
        _mutatePlayback(() {
          _zones = _zones
              .map((value) {
                final zone = _asMap(value);
                if (zone['id']?.toString() != zoneId) return zone;
                return <String, dynamic>{
                  ...zone,
                  'volume': appliedSystemVolume?.volume ?? normalized,
                  'muted': appliedSystemVolume?.muted ?? effectiveMuted,
                  'volume_mode': volumeMode,
                  if (volumeMode == 'system')
                    'system_volume': appliedSystemVolume?.volume ?? normalized
                  else
                    'player_volume': normalized,
                  if (volumeMode == 'system')
                    'system_muted': appliedSystemVolume?.muted ?? effectiveMuted
                  else
                    'player_muted': effectiveMuted,
                };
              })
              .toList(growable: false);
        });
      }
    }
    final result = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postControlJson(
          '/zones/${Uri.encodeComponent(zoneId)}/volume',
          _playbackCommandBody(<String, dynamic>{
            'volume': normalized,
            'muted': effectiveMuted,
            'mode': volumeMode,
          }, intentId: intentId),
        ),
      ),
    );
    if (!mounted || result == null) {
      if (localOutputId != null && appliedSystemVolume != null) {
        unawaited(
          _reportRendererSystemVolume(
            localOutputId,
            appliedSystemVolume,
          ).catchError((Object _) {}),
        );
      }
      return;
    }
    _mutatePlayback(() {
      _zones = _zones
          .map((item) {
            final zone = (item as Map).cast<String, dynamic>();
            if (zone['id']?.toString() != zoneId) {
              return zone;
            }
            return <String, dynamic>{
              ...zone,
              'volume': appliedSystemVolume?.volume ?? result['volume'],
              'muted': appliedSystemVolume?.muted ?? result['muted'],
              'volume_mode': result['mode'],
              'player_volume': result['player_volume'],
              'player_muted': result['player_muted'],
              'system_volume':
                  appliedSystemVolume?.volume ?? result['system_volume'],
              'system_muted':
                  appliedSystemVolume?.muted ?? result['system_muted'],
            };
          })
          .toList(growable: false);
    });
    if (localOutputId != null && appliedSystemVolume != null) {
      unawaited(
        _reportRendererSystemVolume(
          localOutputId,
          appliedSystemVolume,
        ).catchError((Object _) {}),
      );
    }
  }

  String _activeZoneId() =>
      _playback?['zone_id']?.toString() ?? _selectedZoneId;

  Future<void> _selectZone(Map<String, dynamic> zone) async {
    final zoneId = zone['id']?.toString() ?? 'local';
    _mutatePlayback(() {
      _selectedZoneId = zoneId;
      _selectedZoneLabel = _zoneDisplayName(zone);
      _syncPlaybackFromZone(zone);
    });
    await _refreshPlaybackQueue(zoneId: zoneId);
  }

  Future<void> _renameZone(String zoneId, String? alias) async {
    if (_offlineMode) {
      _mutatePlayback(() {
        _zones = _zones
            .map((value) {
              final zone = _asMap(value);
              if (zone['id']?.toString() != zoneId) return zone;
              return <String, dynamic>{...zone, 'alias': alias};
            })
            .toList(growable: false);
        if (_selectedZoneId == zoneId) {
          _selectedZoneLabel = _zoneLabelById(zoneId);
        }
      });
      return;
    }
    await _run<void>(() async {
      await _api.postJson(
        '/zones/${Uri.encodeComponent(zoneId)}/alias',
        <String, dynamic>{'alias': alias},
      );
      final zones = await _api.getCriticalJson('/zones') as List<dynamic>;
      if (!mounted) {
        return;
      }
      _mutatePlayback(() {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
      });
    });
  }

  Future<void> _stopEverywhere() async {
    if (_offlineMode) {
      await _finishOfflinePlayback('stopped');
      for (final outputId in _rendererLoadedTrackByOutput.keys.toList()) {
        await (await _playerForOutput(outputId)).stop();
        _rendererLoadedTrackByOutput.remove(outputId);
        _rendererLocalFileByOutput.remove(outputId);
        _rendererPlaybackByOutput.remove(outputId);
      }
      await _setOfflineStopped();
      await _refreshOfflineRendererZones();
      return;
    }
    final zoneIds = _onlineZoneIds();
    if (zoneIds.isEmpty) {
      return;
    }
    await _run<void>(() async {
      for (final zoneId in zoneIds) {
        await _api.postJson(
          '/zones/${Uri.encodeComponent(zoneId)}/stop',
          <String, dynamic>{},
        );
      }
      final zones = await _api.getCriticalJson('/zones') as List<dynamic>;
      if (!mounted) {
        return;
      }
      _mutatePlayback(() {
        _zones = zones;
        _syncPlaybackFromSelectedZone();
      });
    });
  }

  void _keepSelectedZoneValid() {
    final stillAvailable = _zones.isNotEmpty
        ? _zones.any((item) {
            final zone = (item as Map).cast<String, dynamic>();
            return zone['id']?.toString() == _selectedZoneId &&
                zone['is_online'] != false;
          })
        : _outputs.any((item) {
            final output = (item as Map).cast<String, dynamic>();
            return _zoneIdForOutput(output) == _selectedZoneId &&
                output['is_online'] == true;
          });
    if (!stillAvailable) {
      Map<String, dynamic>? clientZone;
      for (final item in _zones) {
        final zone = (item as Map).cast<String, dynamic>();
        if (zone['id']?.toString() == _clientOutputId) {
          clientZone = zone;
          break;
        }
      }
      if (clientZone != null) {
        _selectedZoneId = _clientOutputId;
        _selectedZoneLabel = _zoneDisplayName(clientZone);
      } else {
        _selectedZoneId = 'local';
        _selectedZoneLabel = 'Core local';
      }
    }
  }

  List<String> _onlineZoneIds() {
    final ids = <String>{};
    if (_zones.isNotEmpty) {
      for (final item in _zones) {
        final zone = (item as Map).cast<String, dynamic>();
        if (zone['is_online'] == false) {
          continue;
        }
        final zoneId = zone['id']?.toString();
        if (zoneId != null && zoneId.isNotEmpty) {
          ids.add(zoneId);
        }
      }
      return ids.toList(growable: false);
    }

    for (final item in _outputs) {
      final output = (item as Map).cast<String, dynamic>();
      if (output['is_online'] == false) {
        continue;
      }
      ids.add(_zoneIdForOutput(output));
    }
    return ids.toList(growable: false);
  }

  Map<String, dynamic>? _zoneById(String zoneId) {
    for (final item in _zones) {
      final zone = (item as Map).cast<String, dynamic>();
      if (zone['id']?.toString() == zoneId) {
        return zone;
      }
    }
    return null;
  }

  String _zoneLabelById(String zoneId) {
    final zone = _zoneById(zoneId);
    return zone == null ? zoneId : _zoneDisplayName(zone);
  }

  void _syncPlaybackFromSelectedZone() {
    final zone = _zoneById(_selectedZoneId);
    if (zone != null) {
      _selectedZoneLabel = _zoneDisplayName(zone);
      _syncPlaybackFromZone(zone);
    }
  }

  void _syncPlaybackFromZone(Map<String, dynamic> zone) {
    final playback = _playbackFromZone(zone);
    if (_acceptIncomingPlayback(playback)) {
      _applyPlayback(playback, syncZone: false);
    }
  }

  Map<String, dynamic> _playbackFromZone(Map<String, dynamic> zone) {
    final zoneId = zone['id'];
    final trackId = _intValue(zone['track_id']);
    final state = zone['state']?.toString();
    var positionMs = _intValue(zone['position_ms']) ?? 0;
    final currentZoneId = _playback?['zone_id']?.toString();
    final currentTrackId = _intValue(_playback?['track_id']);
    if (zoneId?.toString() == currentZoneId &&
        trackId != null &&
        trackId == currentTrackId &&
        (state == 'playing' || state == 'paused')) {
      final currentPosition = _estimatedPlaybackPositionMs(_playback);
      if (positionMs + 1500 < currentPosition) {
        positionMs = currentPosition;
      }
    }

    return <String, dynamic>{
      'zone_id': zoneId,
      'state': state,
      'track_id': trackId,
      'track_title': zone['track_title'],
      'position_ms': positionMs,
      'queue_revision': 0,
      'command_sequence': zone['command_sequence'],
      'origin_client_id': zone['origin_client_id'],
      'intent_id': zone['intent_id'],
    };
  }

  void _upsertZoneFromPlayback(Map<String, dynamic> playback) {
    final zoneId = playback['zone_id']?.toString();
    if (zoneId == null || zoneId.isEmpty) {
      return;
    }

    _zones = _zones
        .map((item) {
          final zone = (item as Map).cast<String, dynamic>();
          if (zone['id']?.toString() != zoneId) {
            return zone;
          }
          return <String, dynamic>{
            ...zone,
            'state': playback['state'],
            'track_id': playback['track_id'],
            'track_title': playback['track_title'],
            'position_ms': playback['position_ms'] ?? 0,
            'command_sequence': playback['command_sequence'],
            'origin_client_id': playback['origin_client_id'],
            'intent_id': playback['intent_id'],
          };
        })
        .toList(growable: false);
  }

  void _mergePlaybackEvent(Map<String, dynamic> playback) {
    final stablePlayback = _stabilizeIncomingPlayback(playback);
    final zoneId = playback['zone_id']?.toString();
    final activeZoneId = _activeZoneId();
    if (zoneId == _selectedZoneId || zoneId == activeZoneId) {
      _applyPlayback(stablePlayback);
    } else {
      _upsertZoneFromPlayback(stablePlayback);
    }
  }

  Map<String, dynamic> _stabilizeIncomingPlayback(
    Map<String, dynamic> playback,
  ) {
    final zoneId = playback['zone_id']?.toString();
    final trackId = _intValue(playback['track_id']);
    final state = playback['state']?.toString();
    final currentZoneId = _playback?['zone_id']?.toString();
    final currentTrackId = _intValue(_playback?['track_id']);
    if (zoneId == null ||
        zoneId != currentZoneId ||
        trackId == null ||
        trackId != currentTrackId ||
        (state != 'playing' && state != 'paused')) {
      return playback;
    }

    final incomingPosition = _intValue(playback['position_ms']) ?? 0;
    final currentPosition = _estimatedPlaybackPositionMs(_playback);
    if (incomingPosition + 1500 >= currentPosition) {
      return playback;
    }
    return <String, dynamic>{...playback, 'position_ms': currentPosition};
  }

  Map<String, dynamic> _withPlaybackTimestamp(Map<String, dynamic> playback) {
    return <String, dynamic>{
      ...playback,
      '_received_at_ms': DateTime.now().millisecondsSinceEpoch,
    };
  }

  void _applyPlayback(Map<String, dynamic> playback, {bool syncZone = true}) {
    if (syncZone) {
      _upsertZoneFromPlayback(playback);
    }
    _playback = _withPlaybackTimestamp(playback);
    _scheduleActiveTrackDetailLoad(playback);
    _syncSystemPlayback();
  }

  void _syncSystemPlayback() {
    _IntMusicPlatform.instance._activeCoreBaseUrlForPlatform =
        _coreUrlController.text;
    unawaited(
      _IntMusicPlatform.instance.updatePlayback(
        playback: _playback,
        detail: _activeTrackDetail,
      ),
    );
  }

  void _scheduleActiveTrackDetailLoad(Map<String, dynamic>? playback) {
    final trackId = _intValue(playback?['track_id']);
    if (trackId == null) {
      _activeTrackDetailId = null;
      _activeTrackDetail = null;
      return;
    }
    if (_activeTrackDetailId == trackId && _activeTrackDetail != null) {
      return;
    }
    if (_activeTrackDetailId != trackId) {
      _activeTrackDetail = null;
    }
    _activeTrackDetailId = trackId;
    unawaited(_loadActiveTrackDetail(trackId));
  }

  Future<void> _loadActiveTrackDetail(int trackId) async {
    if (_offlineMode) {
      final copy = await _availableOfflineCopy(trackId);
      final path = copy == null
          ? null
          : _offlineCopyPath(copy, _clientLibraryRoots);
      if (!mounted ||
          copy == null ||
          path == null ||
          _activeTrackDetailId != trackId) {
        return;
      }
      final detail = copy.toTrackDetail(path);
      _mutatePlayback(() {
        _activeTrackDetail = detail;
        _trackDetailCache[trackId] = detail;
      });
      _syncSystemPlayback();
      return;
    }
    final cached =
        _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
    if (cached != null && _activeTrackDetailId == trackId) {
      _activeTrackDetail = cached;
      if (mounted) _mutatePlayback(() {});
      _syncSystemPlayback();
    }
    try {
      final detail = _asMap(await _api.getJson('/tracks/$trackId'));
      if (!mounted || _activeTrackDetailId != trackId) {
        return;
      }
      _mutatePlayback(() {
        _activeTrackDetail = detail;
        _trackDetailCache[trackId] = detail;
      });
      unawaited(_persistDetail('track', trackId, detail));
      _syncSystemPlayback();
    } catch (_) {
      // Track detail loading is secondary to playback control.
    }
  }
}
