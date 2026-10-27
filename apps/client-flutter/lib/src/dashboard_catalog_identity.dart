part of '../intmusic_client.dart';

extension _DashboardCatalogIdentity on _CoreDashboardState {
  void _reconcileOfflineCopyBindings(List<dynamic> bindings) {
    if (_offlineLibrary.copies.isEmpty) return;
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
      _remapLocalTrackId(copy.trackId, trackId);
      _offlineLibrary.copies[key] = copy.copyWith(
        trackId: trackId,
        mediaVariantId: mediaVariantId,
      );
      changed = true;
    }
    // Absence from a remote snapshot is not evidence that a local file vanished.
    // Only a completed local scan can remove local file records.
    if (changed) unawaited(_OfflineLibraryStore.save(_offlineLibrary));
  }

  void _remapLocalTrackId(int previous, int current) {
    if (previous == current) return;
    if (_verifiedLocalTrackIds.remove(previous)) {
      _verifiedLocalTrackIds.add(current);
    }
    if (_knownLocalTrackIds.remove(previous)) _knownLocalTrackIds.add(current);
    for (var i = 0; i < _offlineLibrary.outbox.length; i++) {
      final mutation = _offlineLibrary.outbox[i];
      if (mutation.trackId == previous) {
        _offlineLibrary.outbox[i] = _OfflineMutation(
          id: mutation.id,
          kind: mutation.kind,
          trackId: current,
          occurredAt: mutation.occurredAt,
          payload: mutation.payload,
        );
      }
    }
    if (_playback?['track_id'] == previous) {
      _playback = {..._playback!, 'track_id': current};
    }
    if (_activeTrackDetailId == previous) _activeTrackDetailId = current;
    for (final output in _rendererLoadedTrackByOutput.keys.toList()) {
      if (_rendererLoadedTrackByOutput[output] == previous) {
        _rendererLoadedTrackByOutput[output] = current;
      }
    }
    for (final output in _rendererPlaybackByOutput.keys.toList()) {
      final playback = _rendererPlaybackByOutput[output]!;
      if (playback['track_id'] == previous) {
        _rendererPlaybackByOutput[output] = {...playback, 'track_id': current};
      }
    }
    final detail = _trackDetailCache.remove(previous);
    if (detail != null) {
      _trackDetailCache[current] = {
        ...detail,
        'track': {..._asMap(detail['track']), 'id': current},
      };
    }
    if (_currentRoute.kind == _AppRouteKind.track &&
        _currentRoute.entityId == previous) {
      _navigateToInState(_AppRoute.track(current), addToHistory: false);
    }
    if (_playbackQueue != null) {
      _playbackQueue = {
        ..._playbackQueue!,
        'items': _queueItems().map((item) {
          final track = _asMap(item['track']);
          return track['id'] == previous
              ? {
                  ...item,
                  'track': {...track, 'id': current},
                }
              : item;
        }).toList(),
      };
    }
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
    final changed = serverChanged || epochChanged || offlineIdentityChanged;
    if (!changed &&
        knownServerId == serverId &&
        knownCatalogEpoch == catalogEpoch) {
      await ClientLibraryDatabase.shared.bindCatalog(
        coreUrl,
        serverId,
        catalogEpoch,
      );
    }
    if (changed) {
      ClientLog.event(
        'catalog.replacement_pending',
        message:
            'Keeping the last committed library until its replacement is saved.',
        data: {'server_id': serverId, 'catalog_epoch': catalogEpoch},
      );
    }
    return changed;
  }

  Future<void> _rebindLocalLibraryAfterCatalogReset() async {
    ClientLog.event(
      'catalog.local_rebind_started',
      data: <String, Object?>{'root_count': _clientLibraryRoots.length},
    );
    await _syncAllClientLibraryRoots(refreshAfter: false);
    if (!_coreLibraryOnline || !mounted) return;
    await _backgroundLibrarySync(force: true);
    ClientLog.event(
      'catalog.local_rebind_finished',
      data: <String, Object?>{'copy_count': _offlineLibrary.copies.length},
    );
  }
}
