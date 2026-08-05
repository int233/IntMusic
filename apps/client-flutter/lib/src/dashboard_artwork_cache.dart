part of '../intmusic_client.dart';

extension _DashboardArtworkCache on _CoreDashboardState {
  Future<void> _warmOfflineArtworkCache() async {
    if (_offlineMode || _cacheServerId == null) return;
    if (_artworkWarmupBusy) {
      _artworkWarmupRequested = true;
      return;
    }
    _artworkWarmupBusy = true;
    try {
      do {
        _artworkWarmupRequested = false;
        final serverId = _cacheServerId;
        if (serverId == null || _offlineMode) return;
        final localTrackIds = _offlineLibrary.distinctTracks
            .map((copy) => copy.trackId)
            .where((id) => id > 0)
            .toSet();
        if (localTrackIds.isEmpty) return;
        final requests = <String, String>{};
        void add(String? url) {
          if (url == null) return;
          requests[artworkCacheCoordinator.cacheKey(url)] = url;
        }

        final localAlbumIds = <int>{};
        for (final value in _tracks.whereType<Map>()) {
          final track = value.cast<String, dynamic>();
          final trackId = _intValue(track['id']);
          if (trackId == null || !localTrackIds.contains(trackId)) continue;
          add(_trackArtworkUrl(_coreUrlController.text, trackId));
          final albumId = _intValue(track['album_id']);
          if (albumId != null) localAlbumIds.add(albumId);
        }
        for (final albumId in localAlbumIds) {
          add(_albumArtworkUrl(_coreUrlController.text, albumId));
        }
        for (final entry in _artistDetailCache.entries) {
          final containsLocalTrack =
              (entry.value['tracks'] as List? ?? const <dynamic>[]).any(
                (value) =>
                    value is Map &&
                    localTrackIds.contains(_intValue(value['id'])),
              );
          if (!containsLocalTrack) continue;
          final artist = _asMap(entry.value['artist']);
          add(
            _artistArtworkUrl(
              _coreUrlController.text,
              entry.key,
              'avatar',
              revision: artist['artwork_revision'],
              width: 512,
              height: 512,
            ),
          );
        }

        final entries = requests.entries.toList(growable: false);
        var nextIndex = 0;
        Future<void> worker() async {
          while (nextIndex < entries.length &&
              !_offlineMode &&
              _cacheServerId == serverId) {
            final entry = entries[nextIndex++];
            try {
              final cached = await _artworkCacheManager.getFileFromCache(
                entry.key,
              );
              if (cached != null && cached.validTill.isAfter(DateTime.now())) {
                continue;
              }
              await _artworkCacheManager.getSingleFile(
                entry.value,
                key: entry.key,
              );
            } catch (_) {
              // Artwork is opportunistic. A later reconnect retries failures.
            }
          }
        }

        await Future.wait(List<Future<void>>.generate(4, (_) => worker()));
      } while (_artworkWarmupRequested && !_offlineMode);
    } finally {
      _artworkWarmupBusy = false;
    }
  }
}
