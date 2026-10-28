part of '../intmusic_client.dart';

extension _DashboardCoreRefresh on _CoreDashboardState {
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
    await api.probeLibraryService(timeout: const Duration(seconds: 3));
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
    final wasOffline = _localPlaybackFallbackActive;
    final continuingOutputId = wasOffline
        ? _offlineOutputForZone(_playback?['zone_id']?.toString())
        : null;
    final continuingLocally =
        continuingOutputId != null &&
        _rendererLocalFileByOutput[continuingOutputId] == true &&
        _rendererLoadedTrackByOutput[continuingOutputId] != null;
    _startRendererHeartbeat();
    _startRendererPositionReporter();
    _startZoneRefresh();
    _startDistributionWorker();
    _startLibrarySync();
    unawaited(_refreshDistributionJobs());
    await _connectEventStream();
    if (!isCurrent()) return;
    // A reachable renderer/database is a connection, not a completed download.
    // Publish its identity now and release the Connect button before cache work.
    _mutate(() {
      _status = status;
      _coreLibraryOnline = true;
    });
    _coreLibraryRefreshPending = true;
    final connectionGeneration = _eventConnectionGeneration;
    unawaited(
      _catalogSyncQueue.run(() async {
        try {
          if (!isCurrent() || !_coreLibraryOnline) return;
          ClientLog.event('library.connection.sync_started');
          await _refreshConnectedLibrary(
            api,
            status,
            catalogReset: catalogReset,
            wasOffline: wasOffline,
            continuingOutputId: continuingOutputId,
            continuingLocally: continuingLocally,
            connectionGeneration: connectionGeneration,
          );
        } catch (error, stack) {
          ClientLog.error(
            'library.connection.sync_failed',
            error,
            stackTrace: stack,
          );
          await _clientLibrary.recordError(coreUrl, error);
          if (isCurrent() && _coreLibraryOnline) {
            _mutate(() => _error = 'Library synchronization failed: $error');
          }
        } finally {
          _coreLibraryRefreshPending = false;
        }
      }),
    );
  }

  Future<void> _refreshConnectedLibrary(
    CoreApiClient api,
    Map<String, dynamic> status, {
    required bool catalogReset,
    required bool wasOffline,
    required String? continuingOutputId,
    required bool continuingLocally,
    required int connectionGeneration,
  }) async {
    final coreUrl = api.baseUrl;
    bool isCurrent() =>
        mounted &&
        _coreLibraryOnline &&
        connectionGeneration == _eventConnectionGeneration &&
        coreUrl == CoreApiClient.normalizeBaseUrl(_coreUrlController.text);
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
    _outputs = results[0] as List<dynamic>;
    _zones = results[1] as List<dynamic>;
    _diagnostics = _asMap(results[2]);
    final settings = _asMap(results[3]);
    _transcodingStatus = _asMap(results[6]);
    if (syncSnapshot != null) {
      await _clientLibrary.replaceSnapshot(coreUrl, {
        ...syncSnapshot,
        'status': status,
        'diagnostics': _diagnostics,
      });
      if (!isCurrent()) return;
      await _publishCommittedLibrary(coreUrl, status);
      await _markPendingDetailRefresh();
    } else {
      await _persistOverviewValues(<String, dynamic>{
        'status': status,
        'diagnostics': _diagnostics,
        'playback_stats': results[4],
        'playback_history': results[5],
        'settings': settings,
      });
      await _publishCommittedLibrary(coreUrl, status);
    }
    if (!isCurrent()) return;
    _serverAliasController.text =
        _serverSettings?['alias']?.toString() ??
        status['display_name']?.toString() ??
        'Core local';
    _status = status;
    _offlineLibrary.serverId = status['server_id']?.toString();
    _offlineLibrary.catalogEpoch = status['catalog_epoch']?.toString();
    var flushedOfflineMutations = false;
    try {
      flushedOfflineMutations = await _flushOfflineMutations();
    } catch (error) {
      await _clientLibrary.recordError(coreUrl, error);
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
    if (!isCurrent()) return;
    _collections.configure(api, status);
    _collections.updateCatalog(_tracks);
    await _collections.ready;
    _collections.setNetworkAvailable(true);
    await _collections.refresh();
    if (!isCurrent()) return;
    ClientLog.event(
      'library.local.sync_committed',
      data: {
        'tracks': _tracks.length,
        'albums': _albums.length,
        'artists': _artists.length,
        'collections_complete': _collections.complete,
        'local_files': _offlineLibrary.copies.length,
      },
    );
    if (wasOffline && !continuingLocally) {
      await _finishOfflinePlayback('reconnected');
      artworkCacheCoordinator.retryFailedImages();
    }
    _coreLibraryOnline = true;
    // A restored connection updates library data; it does not replace the
    // decoder or the queue that continued playing during the interruption.
    _localPlaybackFallbackActive = continuingLocally;
    _refreshTrackAvailabilityProjection();
    _offlineReconnectTimer?.cancel();
    _offlineReconnectFailures = 0;
    _keepSelectedZoneValid();
    if (continuingLocally) await _adoptRunningLocalPlayback();
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
    } else {
      unawaited(_ensureLocalLibraryDeviceBinding());
    }
  }
}
