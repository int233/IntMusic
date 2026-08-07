part of '../intmusic_client.dart';

extension _DashboardCatalogIdentity on _CoreDashboardState {
  void _reconcileOfflineCopyBindings(List<dynamic> bindings) {
    if (bindings.isEmpty || _offlineLibrary.copies.isEmpty) return;
    var changed = false;
    for (final value in bindings) {
      if (value is! Map) continue;
      final binding = value.cast<String, dynamic>();
      final rootExternalId = binding['root_external_id']?.toString() ?? '';
      final externalId = binding['external_id']?.toString() ?? '';
      final trackId = _intValue(binding['track_id']);
      final mediaVariantId = _intValue(binding['media_variant_id']);
      if (rootExternalId.isEmpty ||
          externalId.isEmpty ||
          trackId == null ||
          mediaVariantId == null) {
        continue;
      }
      final key = '$rootExternalId\u0000$externalId';
      final copy = _offlineLibrary.copies[key];
      if (copy == null ||
          (copy.trackId == trackId && copy.mediaVariantId == mediaVariantId)) {
        continue;
      }
      _offlineLibrary.copies[key] = copy.copyWith(
        trackId: trackId,
        mediaVariantId: mediaVariantId,
      );
      changed = true;
    }
    if (changed) unawaited(_OfflineLibraryStore.save(_offlineLibrary));
  }

  Future<bool> _adoptCatalogIdentity(
    Map<String, dynamic> status,
    String coreUrl,
  ) async {
    final serverId = status['server_id']?.toString().trim() ?? '';
    final catalogEpoch = status['catalog_epoch']?.toString().trim() ?? '';
    if (serverId.isEmpty || catalogEpoch.isEmpty) return false;

    final knownServerId = _cacheServerId ?? _offlineLibrary.serverId;
    final knownCatalogEpoch =
        _cacheCatalogEpoch ?? _offlineLibrary.catalogEpoch;
    final hasLogicalState =
        _tracks.isNotEmpty ||
        _albums.isNotEmpty ||
        _artists.isNotEmpty ||
        _playlists.isNotEmpty ||
        _offlineLibrary.copies.isNotEmpty ||
        _offlineLibrary.outbox.isNotEmpty;
    final serverChanged =
        knownServerId != null &&
        knownServerId.isNotEmpty &&
        knownServerId != serverId;
    final epochChanged =
        (knownCatalogEpoch != null &&
            knownCatalogEpoch.isNotEmpty &&
            knownCatalogEpoch != catalogEpoch) ||
        (knownCatalogEpoch == null &&
            (hasLogicalState || _clientLibraryRoots.isNotEmpty));
    if (!serverChanged && !epochChanged) {
      _cacheServerId = serverId;
      _cacheCatalogEpoch = catalogEpoch;
      _offlineLibrary.serverId = serverId;
      _offlineLibrary.catalogEpoch = catalogEpoch;
      return false;
    }

    ClientLog.event(
      'catalog.epoch_reset',
      message: 'Discarding cached logical IDs and rebuilding local bindings.',
      data: <String, Object?>{
        'previous_server_id': knownServerId,
        'server_id': serverId,
        'previous_catalog_epoch': knownCatalogEpoch,
        'catalog_epoch': catalogEpoch,
      },
    );
    await _ClientCacheStore.clear(coreUrl);
    try {
      await _artworkCacheManager.emptyCache();
    } catch (error, stackTrace) {
      ClientLog.error(
        'catalog.artwork_cache_clear_failed',
        error,
        stackTrace: stackTrace,
      );
    }
    _cacheServerId = serverId;
    _cacheCatalogEpoch = catalogEpoch;
    _cacheCursor = 0;
    _albums = const <dynamic>[];
    _artists = const <dynamic>[];
    _tracks = const <dynamic>[];
    _playlists = const <dynamic>[];
    _playbackHistory = const <dynamic>[];
    _playbackStats = null;
    _activeTrackDetail = null;
    _activeTrackDetailId = null;
    _trackDetailCache.clear();
    _albumDetailCache.clear();
    _artistDetailCache.clear();
    _playlistDetailCache.clear();
    _trackAvailabilityById.clear();
    _searchResultCache.clear();
    _detailRefreshScopes.clear();
    _detailWarmAfterIds.clear();
    _detailWarmTargetCursors.clear();
    _offlineLibrary = _OfflineLibrarySnapshot(
      serverId: serverId,
      catalogEpoch: catalogEpoch,
    );
    await _OfflineLibraryStore.save(_offlineLibrary);
    return true;
  }

  Future<void> _rebindLocalLibraryAfterCatalogReset() async {
    ClientLog.event(
      'catalog.local_rebind_started',
      data: <String, Object?>{'root_count': _clientLibraryRoots.length},
    );
    await _syncAllClientLibraryRoots(refreshAfter: false);
    if (_offlineMode || !mounted) return;
    await _backgroundLibrarySync(force: true);
    ClientLog.event(
      'catalog.local_rebind_finished',
      data: <String, Object?>{'copy_count': _offlineLibrary.copies.length},
    );
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
      'catalog_epoch': status['catalog_epoch']?.toString() ?? '',
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
      'client_file_bindings': const <dynamic>[],
      'settings': values[8],
    };
  }
}
