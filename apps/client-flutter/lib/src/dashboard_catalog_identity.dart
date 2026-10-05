part of '../intmusic_client.dart';

extension _DashboardCatalogIdentity on _CoreDashboardState {
  void _reconcileOfflineCopyBindings(List<dynamic> bindings) {
    if (_offlineLibrary.copies.isEmpty) return;
    final boundKeys = <String>{};
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
      boundKeys.add(key);
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
    _offlineLibrary.copies.removeWhere((key, copy) {
      // A live scan may have uploaded new bindings after this snapshot began.
      final removed =
          !_clientLibrarySyncingRootIds.contains(copy.rootExternalId) &&
          !boundKeys.contains(key);
      changed |= removed;
      return removed;
    });
    if (changed) unawaited(_OfflineLibraryStore.save(_offlineLibrary));
  }

  Future<bool> _adoptCatalogIdentity(
    Map<String, dynamic> status,
    String coreUrl,
  ) async {
    final serverId = status['server_id']?.toString().trim() ?? '';
    final catalogEpoch = status['catalog_epoch']?.toString().trim() ?? '';
    if (serverId.isEmpty || catalogEpoch.isEmpty) {
      throw StateError('Core must provide server_id and catalog_epoch');
    }

    final knownServerId = _cacheServerId ?? _offlineLibrary.serverId;
    final knownCatalogEpoch =
        _cacheCatalogEpoch ?? _offlineLibrary.catalogEpoch;
    final hasLogicalState =
        _tracks.isNotEmpty ||
        _albums.isNotEmpty ||
        _artists.isNotEmpty ||
        _collections.items.isNotEmpty ||
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
    final offlineIdentityChanged =
        (_offlineLibrary.copies.isNotEmpty ||
            _offlineLibrary.outbox.isNotEmpty) &&
        (_offlineLibrary.serverId != serverId ||
            _offlineLibrary.catalogEpoch != catalogEpoch);
    if (!serverChanged && !epochChanged && !offlineIdentityChanged) {
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
    if (!mounted ||
        CoreApiClient.normalizeBaseUrl(coreUrl) !=
            CoreApiClient.normalizeBaseUrl(_coreUrlController.text)) {
      throw StateError('Core connection changed during catalog reset');
    }
    _cacheServerId = serverId;
    _cacheCatalogEpoch = catalogEpoch;
    _cacheCursor = 0;
    _eventCursor = 0;
    _albums = const <dynamic>[];
    _artists = const <dynamic>[];
    _tracks = const <dynamic>[];
    _songDisplayState.reset();
    _collections.reset();
    _playbackHistory = const <dynamic>[];
    _playbackStats = null;
    _playbackQueue = null;
    _playbackAgentsByOutput.clear();
    _pendingPlaybackCommandsV3.clear();
    for (final output in _audioPlayers.keys.toList()) {
      await _disposeRendererPlayer(output);
    }
    _playback = null;
    _activeTrackDetail = null;
    _activeTrackDetailId = null;
    _trackDetailCache.clear();
    _albumDetailCache.clear();
    _artistDetailCache.clear();
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
    if (_localPlaybackFallbackActive || !mounted) return;
    await _backgroundLibrarySync(force: true);
    ClientLog.event(
      'catalog.local_rebind_finished',
      data: <String, Object?>{'copy_count': _offlineLibrary.copies.length},
    );
  }
}
