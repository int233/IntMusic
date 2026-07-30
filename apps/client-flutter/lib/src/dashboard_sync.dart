part of '../intmusic_client.dart';

extension _DashboardSync on _CoreDashboardState {
  Future<void> _discoverAndRefresh() async {
    await _run<void>(
      () => _refreshAllInner(forceDiscovery: true, includeLanScan: true),
    );
  }

  Future<void> _refreshAllInner({
    bool allowDiscovery = false,
    bool forceDiscovery = false,
    bool includeLanScan = false,
  }) async {
    if (forceDiscovery) {
      final discovered = await _applyDiscoveredCoreUrl(
        includeLanScan: includeLanScan,
      );
      if (!discovered) {
        throw StateError('No IntMusic core found on the local network');
      }
    }

    try {
      await _refreshFromCurrentCore();
    } catch (error) {
      if (!allowDiscovery || forceDiscovery) {
        rethrow;
      }
      final discovered = await _applyDiscoveredCoreUrl();
      if (!discovered) {
        rethrow;
      }
      await _refreshFromCurrentCore();
    }
  }

  Future<void> _activateOfflineMode() async {
    if (_offlineMode) return;
    await _rendererAudioInitialization;
    final cachedSnapshot = await _ClientCacheStore.load(
      _coreUrlController.text,
    );
    final cacheMatchesLibrary =
        cachedSnapshot.serverId == null ||
        _offlineLibrary.serverId == null ||
        cachedSnapshot.serverId == _offlineLibrary.serverId;
    final cachedValues = cacheMatchesLibrary
        ? cachedSnapshot.values
        : const <String, dynamic>{};
    final previousActiveOutput = _clientOutputForZone(_activeZoneId());
    for (final task in const <String>[
      'renderer-heartbeat',
      'system-volume',
      'renderer-position',
      'zone-refresh',
      'distribution',
      'library-sync',
    ]) {
      _taskScheduler.cancel(task);
    }
    _eventReconnectTimer?.cancel();
    await _eventSocket?.close();
    _eventSocket = null;
    await _failoverActiveCoreStreams('offline_transition');
    final offlineZones = await _buildOfflineRendererZones();
    final offlineSelectedOutput =
        previousActiveOutput != null &&
            offlineZones.any(
              (zone) => zone['id']?.toString() == previousActiveOutput,
            )
        ? previousActiveOutput
        : _clientOutputId;
    final selectedOfflineZone = offlineZones.firstWhere(
      (zone) => zone['id']?.toString() == offlineSelectedOutput,
      orElse: () => <String, dynamic>{
        'id': offlineSelectedOutput,
        'state': 'stopped',
        'position_ms': 0,
      },
    );
    final localTracks = <int, Map<String, dynamic>>{
      for (final value in _offlineTrackSummaries(
        _offlineLibrary,
      ).whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    final canonicalTracks = _tracks.isNotEmpty
        ? _tracks
        : (cachedValues['tracks'] as List?) ?? const <dynamic>[];
    final tracks = canonicalTracks
        .map((value) {
          final cached = _asMap(value);
          final local = localTracks[_intValue(cached['id'])];
          if (local == null) {
            return <String, dynamic>{...cached, '_local_available': false};
          }
          return <String, dynamic>{
            ...cached,
            'is_favorite': local['is_favorite'] ?? cached['is_favorite'],
            'play_count': local['play_count'] ?? cached['play_count'],
            '_offline': true,
            '_local_available': true,
          };
        })
        .toList(growable: true);
    final canonicalTrackIds = <int>{
      for (final value in tracks)
        if (_intValue(_asMap(value)['id']) != null)
          _intValue(_asMap(value)['id'])!,
    };
    tracks.addAll(
      localTracks.entries
          .where((entry) => !canonicalTrackIds.contains(entry.key))
          .map(
            (entry) => <String, dynamic>{
              ...entry.value,
              '_local_available': true,
              '_metadata_pending': true,
            },
          ),
    );
    final albums = _albums.isEmpty
        ? ((cachedValues['albums'] as List?) ??
              _offlineAlbumSummaries(_offlineLibrary))
        : _albums;
    final artists = _artists.isEmpty
        ? ((cachedValues['artists'] as List?) ??
              _offlineArtistSummaries(_offlineLibrary))
        : _artists;
    final playlists = _playlists.isEmpty
        ? (cachedValues['playlists'] as List?) ?? const <dynamic>[]
        : _playlists;
    final playbackHistory = _playbackHistory.isEmpty
        ? (cachedValues['playback_history'] as List?) ?? const <dynamic>[]
        : _playbackHistory;
    final offlinePlayback = <String, dynamic>{
      'zone_id': offlineSelectedOutput,
      'state': selectedOfflineZone['state'] ?? 'stopped',
      'track_id': selectedOfflineZone['track_id'],
      'track_title': selectedOfflineZone['track_title'],
      'position_ms': selectedOfflineZone['position_ms'] ?? 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
    };
    if (!mounted) return;
    _mutate(() {
      _offlineMode = true;
      _rendererStatus = 'Offline local playback';
      _error = null;
      _tracks = tracks;
      _albums = albums;
      _artists = artists;
      _playlists = playlists;
      _playbackHistory = playbackHistory;
      _outputs = offlineZones;
      _zones = offlineZones;
      _selectedZoneId = offlineSelectedOutput;
      _selectedZoneLabel = _tr(context, 'Offline · This device');
      _playback = _withPlaybackTimestamp(offlinePlayback);
      _playbackQueue = <String, dynamic>{
        ...?_playbackQueue,
        'zone_id': offlineSelectedOutput,
        'revision': _intValue(_playbackQueue?['revision']) ?? 0,
        'mode': _playbackQueue?['mode'] ?? _playbackMode.nameForApi,
        'current_index': _playbackQueue?['current_index'],
        'items': _playbackQueue?['items'] ?? const <dynamic>[],
      };
      _status = <String, dynamic>{
        ...?_status,
        'name': 'IntMusic Offline',
        'display_name': _tr(context, 'Offline library'),
        'version': _status?['version']?.toString() ?? 'local',
        'api_version': 'offline',
        'server_id': _offlineLibrary.serverId ?? 'offline',
        'database_path': '-',
        'counts': <String, dynamic>{
          'library_roots': _clientLibraryRoots.length,
          'files': tracks.length,
          'tracks': tracks.length,
          'albums': albums.length,
          'artists': artists.length,
          'scan_problems': 0,
        },
      };
      _favoriteSettings ??= <String, dynamic>{
        'treat_max_rating_as_favorite': true,
        'write_rating_on_favorite': false,
      };
    });
    final activeOutput = _offlineOutputForZone(offlineSelectedOutput);
    if (_rendererLocalFileByOutput[activeOutput] == true &&
        selectedOfflineZone['state']?.toString() == 'playing' &&
        _offlinePlaybackStartedAt == null) {
      final positionMs = _intValue(selectedOfflineZone['position_ms']) ?? 0;
      _offlinePlaybackStartedAt = DateTime.now().toUtc().subtract(
        Duration(milliseconds: positionMs),
      );
      _offlinePlaybackStartPositionMs = positionMs;
    }
    ClientLog.event(
      'client.offline.activated',
      data: <String, Object?>{
        'cached_tracks': tracks.length,
        'local_tracks': localTracks.length,
        'cached_albums': albums.length,
        'cached_artists': artists.length,
        'cached_playlists': _playlists.length,
      },
    );
    _startSystemVolumeMonitor();
    _scheduleOfflineReconnect(resetBackoff: true);
  }

  Future<bool> _applyDiscoveredCoreUrl({bool includeLanScan = false}) async {
    _rendererStatus = 'Discovering core';
    final cores = await _discoverIntMusicCores(
      hintBaseUrl: _coreUrlController.text,
      includeLanScan: includeLanScan,
    );
    if (cores.isEmpty) {
      return false;
    }
    final selected = cores.first;
    _coreUrlController.text = selected.baseUrl;
    _rendererStatus = 'Discovered ${selected.source}';
    return true;
  }

  void _scheduleOfflineReconnect({bool resetBackoff = false}) {
    _offlineReconnectTimer?.cancel();
    if (resetBackoff) {
      _offlineReconnectFailures = 0;
    }
    if (!_offlineMode || !mounted) {
      return;
    }
    const delays = <Duration>[
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ];
    final delay = delays[min(_offlineReconnectFailures, delays.length - 1)];
    _offlineReconnectTimer = Timer(delay, () async {
      if (!mounted || !_offlineMode || _offlineReconnectBusy) {
        _scheduleOfflineReconnect();
        return;
      }
      _offlineReconnectBusy = true;
      try {
        final discovered = await _applyDiscoveredCoreUrl();
        if (discovered) {
          await _refreshFromCurrentCore();
        }
      } catch (error) {
        ClientLog.event(
          'client.offline.reconnect_failed',
          level: 'warning',
          message: error.toString(),
          data: <String, Object?>{
            'attempt': _offlineReconnectFailures + 1,
            'next_delay_seconds':
                delays[min(_offlineReconnectFailures + 1, delays.length - 1)]
                    .inSeconds,
          },
        );
      } finally {
        _offlineReconnectBusy = false;
        if (_offlineMode && mounted) {
          _offlineReconnectFailures += 1;
          _scheduleOfflineReconnect();
        }
      }
    });
  }

  Future<void> _refreshFromCurrentCore() async {
    final status = _asMap(await _api.getCriticalJson('/status'));
    if (!_isIntMusicCoreStatus(status)) {
      throw StateError('Not an IntMusic core: ${_coreUrlController.text}');
    }
    await _saveCoreUrlPreference();
    final coreUrl = _coreUrlController.text.trim();
    await _sendRendererRegistration(
      resetPlayback: _rendererRegisteredCoreUrl != coreUrl,
    );
    _rendererRegisteredCoreUrl = coreUrl;
    await _connectEventStream();
    // Once the Core has accepted registration, keep liveness independent from
    // the larger metadata/cache refresh that follows.
    _startRendererHeartbeat();
    final serverId = status['server_id']?.toString() ?? '';
    final syncSnapshot = await _fetchSyncSnapshot(
      status,
      force: _cacheServerId != serverId || _tracks.isEmpty,
    );
    final results = await Future.wait<dynamic>([
      _api.getJson('/outputs'),
      _api.getCriticalJson('/zones'),
      _api.getJson('/diagnostics'),
      _api.getJson('/settings/server'),
      _api.getJson('/playback/stats?top_limit=20'),
      _api.getJson('/playback/history?limit=250'),
      _api.getJson('/settings/favorites'),
      _api.getJson('/settings/metadata'),
      _api
          .getJson('/transcoding/status')
          .catchError((_) => const <String, dynamic>{}),
    ]);
    _status = status;
    _outputs = results[0] as List<dynamic>;
    _zones = results[1] as List<dynamic>;
    _diagnostics = _asMap(results[2]);
    _serverSettings = _asMap(results[3]);
    _serverAliasController.text =
        _serverSettings?['alias']?.toString() ??
        status['display_name']?.toString() ??
        'Core local';
    _playbackStats = _asMap(results[4]);
    _playbackHistory = results[5] as List<dynamic>;
    _favoriteSettings = _asMap(results[6]);
    _metadataSettings = _asMap(results[7]);
    _transcodingStatus = _asMap(results[8]);
    if (syncSnapshot != null) {
      final settings = <String, dynamic>{
        ..._asMap(syncSnapshot['settings']),
        'server': _serverSettings,
        'favorites': _favoriteSettings,
        'metadata': _metadataSettings,
      };
      final storageSnapshot = <String, dynamic>{
        ...syncSnapshot,
        'settings': settings,
        'playback_stats': _playbackStats,
        'playback_history': _playbackHistory,
      };
      _applySyncSnapshot(
        storageSnapshot,
        status: status,
        diagnostics: _diagnostics,
      );
      await _ClientCacheStore.replaceSnapshot(
        coreUrl,
        _snapshotForStorage(
          storageSnapshot,
          status: status,
          diagnostics: _diagnostics,
        ),
      );
      await _markPendingDetailRefresh();
    } else {
      await _persistOverviewValues(<String, dynamic>{
        'status': status,
        'diagnostics': _diagnostics,
        'playback_stats': _playbackStats,
        'playback_history': _playbackHistory,
        'settings': <String, dynamic>{
          'server': _serverSettings,
          'favorites': _favoriteSettings,
          'metadata': _metadataSettings,
        },
      });
    }
    final wasOffline = _offlineMode;
    final continuingOutputId = wasOffline
        ? _offlineOutputForZone(_playback?['zone_id']?.toString())
        : null;
    final continuingLocally =
        continuingOutputId != null &&
        _rendererLocalFileByOutput[continuingOutputId] == true &&
        _rendererLoadedTrackByOutput[continuingOutputId] != null;
    if (wasOffline) {
      await _finishOfflinePlayback('reconnected');
    }
    _offlineMode = false;
    _offlineReconnectTimer?.cancel();
    _offlineReconnectFailures = 0;
    _startRendererHeartbeat();
    _startRendererPositionReporter();
    _startZoneRefresh();
    _startDistributionWorker();
    _startLibrarySync();
    unawaited(_refreshDistributionJobs());
    _offlineLibrary.serverId = status['server_id']?.toString();
    final flushedOfflineMutations = await _flushOfflineMutations();
    if (flushedOfflineMutations) {
      await _backgroundLibrarySync();
      unawaited(_refreshHistoryCache());
    }
    final onlineTracks = <int, Map<String, dynamic>>{
      for (final value in _tracks.whereType<Map>())
        if (_intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    for (final entry in _offlineLibrary.copies.entries.toList(
      growable: false,
    )) {
      final online = onlineTracks[entry.value.trackId];
      if (online == null) continue;
      final artistDisplay = online['artist_display']?.toString().trim();
      _offlineLibrary.copies[entry.key] = entry.value.copyWith(
        metadata: <String, dynamic>{
          ...entry.value.metadata,
          if ((online['title']?.toString().trim() ?? '').isNotEmpty)
            'title': online['title'].toString(),
          if ((online['album_title']?.toString().trim() ?? '').isNotEmpty)
            'album': online['album_title'].toString(),
          if (artistDisplay?.isNotEmpty == true)
            'track_artists': <String>[artistDisplay!],
          if (_intValue(online['duration_ms']) != null)
            'duration_ms': _intValue(online['duration_ms']),
          if (_intValue(online['disc_number']) != null)
            'disc_number': _intValue(online['disc_number']),
          if (_intValue(online['track_number']) != null)
            'track_number': _intValue(online['track_number']),
          if (_intValue(online['year']) != null)
            'year': _intValue(online['year']),
        },
        isFavorite: online['is_favorite'] == true,
        playCount: _intValue(online['play_count']) ?? entry.value.playCount,
      );
    }
    await _OfflineLibraryStore.save(_offlineLibrary);
    _keepSelectedZoneValid();
    _syncPlaybackFromSelectedZone();
    await _refreshPlaybackQueue();
    _scheduleActiveTrackDetailLoad(_playback);
    if (continuingLocally) {
      await _reportRendererStateSafely('playing', outputId: continuingOutputId);
      if (mounted) {
        _rendererStatus = _tr(
          context,
          'Reconnected · local playback continues',
        );
      }
    }
    await _persistOverviewValues(<String, dynamic>{
      'outputs': _outputs,
      'zones': _zones,
      if (_playback != null) 'playback': _playback,
      if (_playbackQueue != null) 'playback_queue': _playbackQueue,
    });
    unawaited(_warmDetailCache());
  }

  Future<Map<String, dynamic>?> _fetchSyncSnapshot(
    Map<String, dynamic> status, {
    bool force = false,
  }) async {
    final serverId = status['server_id']?.toString() ?? '';
    try {
      if (force) {
        _detailRefreshScopes.addAll(const <String>{
          'track',
          'album',
          'artist',
          'playlist',
        });
      }
      if (!force && _cacheServerId == serverId) {
        final changes = _asMap(
          await _api.getJson(
            '/client-sync/changes?after=$_cacheCursor&limit=500',
          ),
        );
        if (changes['server_id']?.toString() == serverId &&
            changes['requires_snapshot'] != true) {
          _cacheCursor = _intValue(changes['cursor']) ?? _cacheCursor;
          return null;
        }
        for (final value
            in ((changes['changes'] as List?) ?? const <dynamic>[])) {
          if (value is! Map) continue;
          final reason = value['reason']?.toString().toLowerCase() ?? '';
          switch (value['scope']?.toString()) {
            case 'tracks':
              if (!reason.contains('favorite') &&
                  !reason.contains('mutation')) {
                _detailRefreshScopes.addAll(const <String>{
                  'track',
                  'album',
                  'artist',
                  'playlist',
                });
              }
            case 'albums':
              _detailRefreshScopes.add('album');
            case 'artists':
              _detailRefreshScopes.add('artist');
            case 'playlists':
              _detailRefreshScopes.add('playlist');
            default:
              _detailRefreshScopes.addAll(const <String>{
                'track',
                'album',
                'artist',
                'playlist',
              });
          }
        }
      }
      return _asMap(
        await _api.getJson(
          '/client-sync/snapshot',
          requestTimeout: const Duration(seconds: 60),
        ),
      );
    } on HttpException {
      return _loadLegacySyncSnapshot(status);
    }
  }

  Future<Map<String, dynamic>> _loadLegacySyncSnapshot(
    Map<String, dynamic> status,
  ) async {
    final values = await Future.wait<dynamic>([
      _loadPagedList('/albums'),
      _loadPagedList('/artists'),
      _loadPagedList('/tracks'),
      _api.getJson('/playlists'),
      _api.getJson('/playback/history?limit=250'),
      _api.getJson('/playback/stats?top_limit=50'),
      _api.getJson('/library/roots'),
      _api.getJson('/client-library/manifests'),
      _api.getJson('/settings'),
    ]);
    return <String, dynamic>{
      'server_id': status['server_id']?.toString() ?? '',
      'cursor': _intValue(status['library_revision']) ?? 0,
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'albums': values[0],
      'artists': values[1],
      'tracks': values[2],
      'playlists': values[3],
      'playback_history': values[4],
      'playback_stats': values[5],
      'library_roots': values[6],
      'client_library_roots': values[7],
      'settings': values[8],
    };
  }

  void _startLibrarySync() {
    _taskScheduler.schedule(
      'library-sync',
      interval: const Duration(seconds: 8),
      callback: () async {
        await _backgroundLibrarySync();
        _backgroundSyncTicks += 1;
        if (_backgroundSyncTicks % 4 == 0) {
          await _refreshHistoryCache();
        }
      },
    );
  }

  Future<void> _refreshHistoryCache() async {
    if (_offlineMode || _cacheServerId == null) return;
    try {
      final values = await Future.wait<dynamic>([
        _api.getJson('/playback/history?limit=250'),
        _api.getJson('/playback/stats?top_limit=50'),
        _api.getJson('/settings'),
      ]);
      final settings = _asMap(values[2]);
      if (mounted) {
        _mutate(() {
          _playbackHistory = values[0] as List<dynamic>;
          _playbackStats = _asMap(values[1]);
          _serverSettings = _asMap(settings['server']);
          _favoriteSettings = _asMap(settings['favorites']);
          _metadataSettings = _asMap(settings['metadata']);
        });
      }
      await _persistOverviewValues(<String, dynamic>{
        'playback_history': values[0],
        'playback_stats': values[1],
        'settings': settings,
      });
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Future<void> _backgroundLibrarySync({bool force = false}) async {
    if (_backgroundSyncBusy ||
        _offlineMode ||
        _rendererRegisteredCoreUrl == null) {
      return;
    }
    _backgroundSyncBusy = true;
    try {
      final status = _asMap(await _api.getJson('/status'));
      if (!_isIntMusicCoreStatus(status)) return;
      final snapshot = await _fetchSyncSnapshot(status, force: force);
      if (snapshot == null) return;
      final storageSnapshot = <String, dynamic>{
        ...snapshot,
        'settings': <String, dynamic>{
          ..._asMap(snapshot['settings']),
          if (_serverSettings != null) 'server': _serverSettings,
          if (_favoriteSettings != null) 'favorites': _favoriteSettings,
          if (_metadataSettings != null) 'metadata': _metadataSettings,
        },
      };
      if (mounted) {
        _mutate(() {
          _applySyncSnapshot(
            storageSnapshot,
            status: status,
            diagnostics: _diagnostics,
          );
          _error = null;
        });
      } else {
        _applySyncSnapshot(
          storageSnapshot,
          status: status,
          diagnostics: _diagnostics,
        );
      }
      await _ClientCacheStore.replaceSnapshot(
        _coreUrlController.text,
        _snapshotForStorage(
          storageSnapshot,
          status: status,
          diagnostics: _diagnostics,
        ),
      );
      await _markPendingDetailRefresh();
      unawaited(_warmDetailCache());
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    } finally {
      _backgroundSyncBusy = false;
    }
  }

  Future<void> _warmDetailCache() async {
    if (_detailWarmupBusy || _offlineMode || _cacheServerId == null) return;
    _detailWarmupBusy = true;
    final serverId = _cacheServerId!;
    var retryPending = false;
    try {
      for (final kind in const <String>[
        'artist',
        'album',
        'playlist',
        'track',
      ]) {
        if (!_detailRefreshScopes.contains(kind)) continue;
        final target = switch (kind) {
          'artist' => _artistDetailCache,
          'album' => _albumDetailCache,
          'playlist' => _playlistDetailCache,
          _ => _trackDetailCache,
        };
        var afterId = _detailWarmAfterIds[kind] ?? 0;
        final targetCursor = _detailWarmTargetCursors[kind] ?? _cacheCursor;
        var superseded = false;
        while (!_offlineMode && _cacheServerId == serverId) {
          final response = _asMap(
            await _api.getJson(
              '/client-sync/details?kind=$kind&after_id=$afterId&limit=100',
              requestTimeout: const Duration(seconds: 60),
            ),
          );
          if (response['server_id']?.toString() != serverId) return;
          if ((_detailWarmTargetCursors[kind] ?? targetCursor) !=
              targetCursor) {
            superseded = true;
            break;
          }
          final batch = <int, Map<String, dynamic>>{};
          for (final value
              in ((response['items'] as List?) ?? const <dynamic>[])) {
            if (value is! Map) continue;
            final id = _intValue(value['id']);
            final detail = _asMap(value['detail']);
            if (id == null || detail.isEmpty) continue;
            target[id] = detail;
            batch[id] = detail;
          }
          await _ClientCacheStore.putDetails(
            _coreUrlController.text,
            serverId,
            kind,
            batch,
          );
          final next = _intValue(response['next_after_id']) ?? afterId;
          final complete = response['has_more'] != true || next <= afterId;
          _detailWarmAfterIds[kind] = next;
          await _ClientCacheStore.updateDetailWarmProgress(
            _coreUrlController.text,
            kind,
            next,
            targetCursor: targetCursor,
            complete: complete,
          );
          if ((_detailWarmTargetCursors[kind] ?? targetCursor) !=
              targetCursor) {
            superseded = true;
            break;
          }
          if (complete) break;
          afterId = next;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (superseded ||
            (_detailWarmTargetCursors[kind] ?? targetCursor) != targetCursor) {
          retryPending = true;
          continue;
        }
        _detailWarmAfterIds.remove(kind);
        _detailWarmTargetCursors.remove(kind);
        _detailRefreshScopes.remove(kind);
      }
      if (mounted) _mutate(() {});
    } on HttpException catch (error) {
      // A 404 means an older Core: details are then cached on first visit.
      // Transient HTTP failures keep their durable cursor and retry later.
      retryPending = !error.message.startsWith('HTTP 404');
      if (retryPending) {
        await _ClientCacheStore.recordError(_coreUrlController.text, error);
      }
    } catch (error) {
      retryPending = true;
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    } finally {
      _detailWarmupBusy = false;
      if (retryPending && _detailRefreshScopes.isNotEmpty && !_offlineMode) {
        unawaited(
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (mounted && !_offlineMode) unawaited(_warmDetailCache());
          }),
        );
      }
    }
  }

  Future<void> _markPendingDetailRefresh() async {
    final serverId = _cacheServerId;
    if (serverId == null || _detailRefreshScopes.isEmpty) return;
    for (final kind in _detailRefreshScopes) {
      _detailWarmAfterIds[kind] = 0;
      _detailWarmTargetCursors[kind] = _cacheCursor;
    }
    await _ClientCacheStore.markDetailsForRefresh(
      _coreUrlController.text,
      serverId,
      _cacheCursor,
      _detailRefreshScopes,
    );
  }

  Future<bool> _flushOfflineMutations() async {
    if (_offlineLibrary.outbox.isEmpty) return false;
    var flushedAny = false;
    while (_offlineLibrary.outbox.isNotEmpty) {
      final batch = _offlineLibrary.outbox.take(100).toList(growable: false);
      final result = _asMap(
        await _api.postJson('/client-sync/mutations', <String, dynamic>{
          'device_id': _clientId,
          'device_name': _clientAlias(),
          'platform': Platform.operatingSystem,
          'mutations': batch
              .map((mutation) => mutation.toJson())
              .toList(growable: false),
        }),
      );
      final acknowledged = <String>{
        for (final value
            in ((result['applied_ids'] as List?) ?? const <dynamic>[]))
          value.toString(),
        for (final value
            in ((result['duplicate_ids'] as List?) ?? const <dynamic>[]))
          value.toString(),
      };
      if (acknowledged.isEmpty) {
        break;
      }
      _offlineLibrary.outbox.removeWhere(
        (mutation) => acknowledged.contains(mutation.id),
      );
      flushedAny = true;
      await _OfflineLibraryStore.save(_offlineLibrary);
      if (acknowledged.length < batch.length) {
        break;
      }
    }
    return flushedAny;
  }

  Future<List<dynamic>> _loadPagedList(
    String path, {
    int pageSize = 500,
  }) async {
    final items = <dynamic>[];
    for (var offset = 0; ; offset += pageSize) {
      final separator = path.contains('?') ? '&' : '?';
      final page =
          await _api.getJson('$path${separator}limit=$pageSize&offset=$offset')
              as List<dynamic>;
      items.addAll(page);
      if (page.length < pageSize) {
        break;
      }
    }
    return items;
  }
}
