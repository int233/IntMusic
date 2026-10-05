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
        allowServerChange: true,
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

  Future<void> _activateLocalPlaybackFallback() async {
    if (_localPlaybackFallbackActive) return;
    await _rendererAudioInitialization;
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
    final offlineSelectedZoneId = _zones
        .whereType<Map>()
        .map(_asMap)
        .where(
          (zone) =>
              (zone['output_id']?.toString() ?? zone['id']?.toString()) ==
              offlineSelectedOutput,
        )
        .map((zone) => zone['id']?.toString())
        .whereType<String>()
        .firstOrNull;
    final availableLocalTrackIds = <int>{};
    final localCopies = _offlineLibrary.distinctTracks.toList(growable: false);
    for (var start = 0; start < localCopies.length; start += 32) {
      final end = min(start + 32, localCopies.length);
      final availability = await Future.wait(
        localCopies.sublist(start, end).map((copy) async {
          final path = _offlineCopyPath(copy, _clientLibraryRoots);
          return path != null && await File(path).exists();
        }),
      );
      for (var index = 0; index < availability.length; index += 1) {
        if (availability[index]) {
          availableLocalTrackIds.add(localCopies[start + index].trackId);
        }
      }
    }
    final offlinePlayback = <String, dynamic>{
      'zone_id': offlineSelectedZoneId ?? offlineSelectedOutput,
      'state': selectedOfflineZone['state'] ?? 'stopped',
      'track_id': selectedOfflineZone['track_id'],
      'track_title': selectedOfflineZone['track_title'],
      'position_ms': selectedOfflineZone['position_ms'] ?? 0,
      'queue_revision': _intValue(_playbackQueue?['revision']) ?? 0,
    };
    if (!mounted) return;
    _mutate(() {
      // Offline playback keeps the same catalog and queue occurrence IDs.
      _localPlaybackFallbackActive = true;
      _verifiedLocalTrackIds
        ..clear()
        ..addAll(availableLocalTrackIds);
      _rendererStatus = 'Core unreachable · local playback available';
      _error = null;
      // Keep the last authoritative device projection visible. Transport
      // failure only marks remote outputs unreachable; it must not replace the
      // device model with a second, local-only list.
      _outputs = _mergeOfflineRendererProjection(_outputs, offlineZones);
      _zones = _mergeOfflineRendererProjection(_zones, offlineZones);
      _selectedZoneId = offlineSelectedZoneId ?? offlineSelectedOutput;
      _selectedZoneLabel = _tr(context, 'This device');
      _playback = _withPlaybackTimestamp(offlinePlayback);
      _playbackQueue = <String, dynamic>{
        ...?_playbackQueue,
        'zone_id': offlineSelectedOutput,
        'revision': _intValue(_playbackQueue?['revision']) ?? 0,
        'mode': _playbackQueue?['mode'] ?? _playbackMode.nameForApi,
        'current_index': _playbackQueue?['current_index'],
        'items': _playbackQueue?['items'] ?? const <dynamic>[],
      };
      _favoriteSettings ??= <String, dynamic>{
        'treat_max_rating_as_favorite': true,
        'write_rating_on_favorite': false,
      };
      _refreshTrackAvailabilityProjection();
    });
    _schedulePlaybackCheckpoint(immediate: true);
    final activeOutput = _offlineOutputForZone(
      offlineSelectedZoneId ?? offlineSelectedOutput,
    );
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
        'projected_tracks': _tracks.length,
        'verified_local_tracks': availableLocalTrackIds.length,
        'projected_albums': _albums.length,
        'projected_artists': _artists.length,
        'cached_collections': _collections.items.length,
      },
    );
    _startSystemVolumeMonitor();
    _scheduleCoreReconnect(resetBackoff: true);
  }

  Future<bool> _applyDiscoveredCoreUrl({
    bool includeLanScan = false,
    bool allowServerChange = false,
  }) async {
    _rendererStatus = 'Discovering core';
    final cores = await _discoverIntMusicCores(
      hintBaseUrl: _coreUrlController.text,
      requiredServerId: allowServerChange
          ? null
          : _cacheServerId ?? _offlineLibrary.serverId,
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

  void _scheduleCoreReconnect({bool resetBackoff = false}) {
    _offlineReconnectTimer?.cancel();
    if (resetBackoff) {
      _offlineReconnectFailures = 0;
    }
    if (!_localPlaybackFallbackActive || !mounted) {
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
      if (!mounted || !_localPlaybackFallbackActive || _offlineReconnectBusy) {
        _scheduleCoreReconnect();
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
        if (_localPlaybackFallbackActive && mounted) {
          _offlineReconnectFailures += 1;
          _scheduleCoreReconnect();
        }
      }
    });
  }

  Future<void> _refreshFromCurrentCore() =>
      _catalogSyncQueue.run(_refreshFromCurrentCoreNow);

  Future<void> _refreshFromCurrentCoreNow() async {
    final api = _api;
    bool isCurrent() =>
        mounted &&
        api.baseUrl == CoreApiClient.normalizeBaseUrl(_coreUrlController.text);
    final status = _asMap(await api.getCriticalJson('/status'));
    if (!_isIntMusicCoreStatus(status)) {
      throw StateError('Not an IntMusic core: ${_coreUrlController.text}');
    }
    if (!isCurrent()) return;
    await _saveCoreUrlPreference();
    if (!isCurrent()) return;
    final coreUrl = api.baseUrl;
    final catalogReset = await _adoptCatalogIdentity(status, coreUrl);
    if (!isCurrent()) return;
    await _sendRendererRegistration(
      resetPlayback: _rendererRegisteredCoreUrl != coreUrl,
    );
    if (!isCurrent()) return;
    _rendererRegisteredCoreUrl = coreUrl;
    _status = status;
    final wasOffline = _localPlaybackFallbackActive;
    final continuingOutputId = wasOffline
        ? _offlineOutputForZone(_playback?['zone_id']?.toString())
        : null;
    final continuingLocally =
        continuingOutputId != null &&
        _rendererLocalFileByOutput[continuingOutputId] == true &&
        _rendererLoadedTrackByOutput[continuingOutputId] != null;
    if (wasOffline) {
      await _finishOfflinePlayback('reconnected');
      artworkCacheCoordinator.retryFailedImages();
    }
    _localPlaybackFallbackActive = false;
    _refreshTrackAvailabilityProjection();
    _offlineReconnectTimer?.cancel();
    _offlineReconnectFailures = 0;
    _startRendererHeartbeat();
    _startRendererPositionReporter();
    _startZoneRefresh();
    _startDistributionWorker();
    _startLibrarySync();
    unawaited(_refreshDistributionJobs());
    await _connectEventStream();
    if (!isCurrent()) return;
    // Playback and its liveness tasks are active before metadata synchronization.
    final serverId = status['server_id']?.toString() ?? '';
    artworkCacheCoordinator.registerServer(
      serverId,
      catalogEpoch: status['catalog_epoch']?.toString() ?? '',
    );
    final syncSnapshot = await _fetchSyncSnapshot(
      status,
      api: api,
      force: catalogReset || _cacheServerId != serverId || _tracks.isEmpty,
    );
    Future<dynamic> overview(String key, String path) => syncSnapshot != null
        ? Future<dynamic>.value(syncSnapshot[key])
        : api.getJson(path);
    final results = await Future.wait<dynamic>([
      api.getJson('/outputs').catchError((_) => _outputs),
      api.getCriticalJson('/zones').catchError((_) => _zones),
      api
          .getJson('/diagnostics')
          .catchError((_) => _diagnostics ?? <String, dynamic>{}),
      overview('settings', '/settings'),
      overview('playback_stats', '/playback/stats?top_limit=50'),
      overview('playback_history', '/playback/history?limit=250'),
      api
          .getJson('/transcoding/status')
          .catchError((_) => const <String, dynamic>{}),
    ]);
    if (!isCurrent()) return;
    _status = status;
    _outputs = results[0] as List<dynamic>;
    _zones = results[1] as List<dynamic>;
    _diagnostics = _asMap(results[2]);
    final settings = _asMap(results[3]);
    _serverSettings = _asMap(settings['server']);
    _serverAliasController.text =
        _serverSettings?['alias']?.toString() ??
        status['display_name']?.toString() ??
        'Core local';
    _playbackStats = _asMap(results[4]);
    _playbackHistory = results[5] as List<dynamic>;
    _favoriteSettings = _asMap(settings['favorites']);
    _metadataSettings = _asMap(settings['metadata']);
    _songDisplaySettings = _asMap(settings['song_display']);
    _transcodingStatus = _asMap(results[6]);
    if (syncSnapshot != null) {
      await _ClientCacheStore.replaceSnapshot(coreUrl, {
        ...syncSnapshot,
        'status': status,
        'diagnostics': _diagnostics,
      });
      if (!isCurrent()) return;
      _applySyncSnapshot(
        syncSnapshot,
        status: status,
        diagnostics: _diagnostics,
      );
      await _markPendingDetailRefresh();
    } else {
      await _persistOverviewValues(<String, dynamic>{
        'status': status,
        'diagnostics': _diagnostics,
        'playback_stats': _playbackStats,
        'playback_history': _playbackHistory,
        'settings': settings,
      });
    }
    _offlineLibrary.serverId = status['server_id']?.toString();
    _offlineLibrary.catalogEpoch = status['catalog_epoch']?.toString();
    var flushedOfflineMutations = false;
    try {
      flushedOfflineMutations = await _flushOfflineMutations();
    } catch (error) {
      await _ClientCacheStore.recordError(coreUrl, error);
    }
    if (flushedOfflineMutations) {
      unawaited(_backgroundLibrarySync());
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
    unawaited(_warmOfflineArtworkCache());
    if (catalogReset && _clientLibraryRoots.isNotEmpty) {
      unawaited(_rebindLocalLibraryAfterCatalogReset());
    }
  }

  Future<Map<String, dynamic>?> _fetchSyncSnapshot(
    Map<String, dynamic> status, {
    required CoreApiClient api,
    bool force = false,
  }) async {
    final result = await fetchLibrarySnapshot(
      identity: CatalogIdentity(
        status['server_id']?.toString() ?? '',
        status['catalog_epoch']?.toString() ?? '',
      ),
      cursor: _cacheCursor,
      deviceId: _clientId,
      force: force || _cacheServerId != status['server_id'],
      get: (path) async => _asMap(
        await api.getBulkJson(
          path,
          requestTimeout: const Duration(seconds: 60),
        ),
      ),
    );
    if (!mounted ||
        api.baseUrl !=
            CoreApiClient.normalizeBaseUrl(_coreUrlController.text)) {
      throw StateError('Core connection changed during synchronization');
    }
    _detailRefreshScopes.addAll(result.detailKinds);
    return result.snapshot;
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
    if (_localPlaybackFallbackActive ||
        _cacheServerId == null ||
        _clientLibrarySyncingRootIds.isNotEmpty) {
      return;
    }
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
          _songDisplaySettings = _asMap(settings['song_display']);
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
        _localPlaybackFallbackActive ||
        _clientLibrarySyncingRootIds.isNotEmpty ||
        _rendererRegisteredCoreUrl == null) {
      return;
    }
    _backgroundSyncBusy = true;
    try {
      await _catalogSyncQueue.run(
        () => _backgroundLibrarySyncNow(force: force),
      );
    } finally {
      _backgroundSyncBusy = false;
    }
  }

  Future<void> _backgroundLibrarySyncNow({required bool force}) async {
    if (!mounted ||
        _localPlaybackFallbackActive ||
        _clientLibrarySyncingRootIds.isNotEmpty) {
      return;
    }
    final api = _api;
    final coreUrl = api.baseUrl;
    var catalogReset = false;
    try {
      final status = _asMap(await api.getJson('/status'));
      if (!_isIntMusicCoreStatus(status)) return;
      if (!mounted ||
          coreUrl != CoreApiClient.normalizeBaseUrl(_coreUrlController.text)) {
        return;
      }
      catalogReset = await _adoptCatalogIdentity(
        status,
        _coreUrlController.text.trim(),
      );
      try {
        await _flushOfflineMutations();
      } catch (error) {
        // A rejected/offline mutation must not prevent downloading the catalog.
        await _ClientCacheStore.recordError(coreUrl, error);
      }
      final snapshot = await _fetchSyncSnapshot(
        status,
        api: api,
        force: force || catalogReset,
      );
      if (snapshot == null) return;
      await _ClientCacheStore.replaceSnapshot(coreUrl, {
        ...snapshot,
        'status': status,
        'diagnostics': _diagnostics,
      });
      if (!mounted ||
          coreUrl != CoreApiClient.normalizeBaseUrl(_coreUrlController.text)) {
        return;
      }
      _mutate(() {
        _applySyncSnapshot(snapshot, status: status, diagnostics: _diagnostics);
        _error = null;
      });
      await _markPendingDetailRefresh();
      unawaited(_warmDetailCache());
    } catch (error) {
      await _ClientCacheStore.recordError(coreUrl, error);
    } finally {
      if (catalogReset && _clientLibraryRoots.isNotEmpty && mounted) {
        unawaited(_rebindLocalLibraryAfterCatalogReset());
      }
    }
  }

  Future<void> _warmDetailCache() async {
    if (_detailWarmupBusy ||
        _localPlaybackFallbackActive ||
        _cacheServerId == null ||
        _clientLibrarySyncingRootIds.isNotEmpty) {
      return;
    }
    _detailWarmupBusy = true;
    final serverId = _cacheServerId!;
    final epoch = _cacheCatalogEpoch;
    final api = _api;
    final identity = CatalogIdentity(serverId, epoch ?? '');
    var retryPending = false;
    try {
      for (final kind in const <String>['track', 'artist', 'album']) {
        if (!_detailRefreshScopes.contains(kind)) continue;
        final target = switch (kind) {
          'artist' => _artistDetailCache,
          'album' => _albumDetailCache,
          _ => _trackDetailCache,
        };
        final targetCursor = _detailWarmTargetCursors[kind] ?? _cacheCursor;
        _detailWarmTargetCursors[kind] = targetCursor;
        bool canContinue() =>
            mounted &&
            !_localPlaybackFallbackActive &&
            _cacheServerId == serverId &&
            _cacheCatalogEpoch == epoch &&
            api.baseUrl ==
                CoreApiClient.normalizeBaseUrl(_coreUrlController.text) &&
            _detailWarmTargetCursors[kind] == targetCursor &&
            _clientLibrarySyncingRootIds.isEmpty;
        final completed = await syncLibraryDetailPages(
          afterId: _detailWarmAfterIds[kind] ?? 0,
          canContinue: canContinue,
          load: (afterId) async {
            final response = _asMap(
              await api.getBulkJson(
                '/client-sync/details?kind=$kind&after_id=$afterId&limit=100',
                requestTimeout: const Duration(seconds: 60),
              ),
            );
            if (!identity.matches(response)) {
              throw StateError(
                'Core catalog changed during detail synchronization',
              );
            }
            return response;
          },
          save: (response, next, complete) async {
            final batch = <int, Map<String, dynamic>>{};
            for (final value in ((response['items'] as List?) ?? const [])) {
              if (value is! Map) continue;
              final id = _intValue(value['id']);
              final detail = _asMap(value['detail']);
              if (id == null || detail.isEmpty) continue;
              target[id] = detail;
              batch[id] = detail;
            }
            await _ClientCacheStore.putDetails(
              api.baseUrl,
              serverId,
              kind,
              batch,
            );
            if (!canContinue()) return;
            _detailWarmAfterIds[kind] = next;
            await _ClientCacheStore.updateDetailWarmProgress(
              api.baseUrl,
              kind,
              next,
              targetCursor: targetCursor,
              complete: complete,
            );
          },
        );
        if (!completed) {
          retryPending = true;
          return;
        }
        _detailWarmAfterIds.remove(kind);
        _detailWarmTargetCursors.remove(kind);
        _detailRefreshScopes.remove(kind);
        if (kind == 'track' && mounted) {
          _mutate(() => _refreshTrackAvailabilityProjection());
        }
      }
      if (mounted) {
        _mutate(() => _refreshTrackAvailabilityProjection());
      }
      unawaited(_warmOfflineArtworkCache());
    } catch (error) {
      retryPending = true;
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    } finally {
      _detailWarmupBusy = false;
      if (retryPending &&
          _detailRefreshScopes.isNotEmpty &&
          !_localPlaybackFallbackActive) {
        unawaited(
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (mounted &&
                !_localPlaybackFallbackActive &&
                _clientLibrarySyncingRootIds.isEmpty) {
              unawaited(_warmDetailCache());
            }
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

  Future<bool> _flushOfflineMutations() =>
      _offlineMutationSyncQueue.run(_flushOfflineMutationsNow);

  Future<bool> _flushOfflineMutationsNow() async {
    final library = _offlineLibrary;
    final api = _api;
    bool isCurrent() =>
        mounted &&
        identical(library, _offlineLibrary) &&
        library.serverId == _cacheServerId &&
        library.catalogEpoch == _cacheCatalogEpoch &&
        _rendererRegisteredCoreUrl != null &&
        CoreApiClient.normalizeBaseUrl(_rendererRegisteredCoreUrl!) ==
            api.baseUrl &&
        api.baseUrl == CoreApiClient.normalizeBaseUrl(_coreUrlController.text);
    if (!isCurrent() || library.outbox.isEmpty) return false;
    var flushedAny = false;
    while (isCurrent() && library.outbox.isNotEmpty) {
      final batch = library.outbox.take(100).toList(growable: false);
      final result = _asMap(
        await api.postJson('/client-sync/mutations', <String, dynamic>{
          'device_id': _clientId,
          'device_name': _clientAlias(),
          'platform': Platform.operatingSystem,
          'mutations': batch
              .map((mutation) => mutation.toJson())
              .toList(growable: false),
        }),
      );
      if (!isCurrent()) break;
      final sentIds = batch.map((mutation) => mutation.id).toSet();
      final acknowledged = <String>{
        for (final value
            in ((result['applied_ids'] as List?) ?? const <dynamic>[]))
          value.toString(),
        for (final value
            in ((result['duplicate_ids'] as List?) ?? const <dynamic>[]))
          value.toString(),
      }.intersection(sentIds);
      if (acknowledged.isEmpty) {
        break;
      }
      library.outbox.removeWhere(
        (mutation) => acknowledged.contains(mutation.id),
      );
      flushedAny = true;
      await _OfflineLibraryStore.save(library);
      if (acknowledged.length < batch.length) {
        break;
      }
    }
    return flushedAny;
  }
}
