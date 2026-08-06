part of '../intmusic_client.dart';

extension _DashboardDetails on _CoreDashboardState {
  Future<T?> _showPanelDialog<T>({
    required Widget child,
    required double maxWidth,
  }) {
    final language = _language;
    return showDialog<T>(
      context: context,
      builder: (context) => _LocaleScope(
        language: language,
        child: Dialog(
          insetPadding: const EdgeInsets.all(22),
          backgroundColor: IntMusicTheme.of(context).surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: IntMusicTheme.of(context).stroke),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: MediaQuery.sizeOf(context).height - 44,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> _openAlbumDetail(int albumId) async {
    if (_offlineMode) {
      final detail =
          _albumDetailCache[albumId] ??
          _albumDetailFromOverview(albumId) ??
          _offlineAlbumDetail(_offlineLibrary, albumId);
      if (detail != null && mounted) {
        _mutate(() {
          _albumDetailCache[albumId] = detail;
          _navigateToInState(_AppRoute.album(albumId));
        });
      }
      return;
    }
    final detail =
        _albumDetailCache[albumId] ?? _albumDetailFromOverview(albumId);
    if (detail == null || !mounted) return;
    _mutate(() {
      _albumDetailCache[albumId] = detail;
      _navigateToInState(_AppRoute.album(albumId));
    });
    unawaited(_refreshAlbumDetail(albumId));
  }

  Map<String, dynamic>? _albumDetailFromOverview(int albumId) {
    final album = _findEntity(_albums, albumId);
    if (album == null) return null;
    return <String, dynamic>{
      'album': album,
      'tracks': _tracks
          .whereType<Map>()
          .map((value) => value.cast<String, dynamic>())
          .where((track) => _intValue(track['album_id']) == albumId)
          .toList(growable: false),
    };
  }

  Future<void> _refreshAlbumDetail(int albumId) async {
    try {
      final detail = _asMap(await _api.getJson('/albums/$albumId'));
      _albumDetailCache[albumId] = detail;
      await _persistDetail('album', albumId, detail);
      if (mounted) {
        _mutate(
          () => _decorateDetailTrackAvailability(_albumDetailCache, albumId),
        );
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  void _closeAlbumDetail() => _closeDetailPage();

  Future<void> _editAlbum(int albumId) async {
    if (_offlineMode) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr(context, 'Album editing requires Core'))),
      );
      return;
    }
    final snapshot = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/albums/$albumId/edit')),
    );
    if (!mounted || snapshot == null) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _AlbumEditorDialog(
          api: _api,
          albumId: albumId,
          snapshot: snapshot,
        ),
      ),
    );
    if (!mounted || result == null) return;
    final targetAlbumId = _intValue(result['target_album_id']);
    final updatedSnapshot = result['snapshot'] is Map
        ? _asMap(result['snapshot'])
        : null;
    if (updatedSnapshot != null) {
      final detail = _asMap(updatedSnapshot['detail']);
      final canonicalId = _intValue(_asMap(detail['album'])['id']) ?? albumId;
      _mutate(() => _albumDetailCache[canonicalId] = detail);
      unawaited(_persistDetail('album', canonicalId, detail));
    }
    await _backgroundLibrarySync(force: true);
    if (!mounted) return;
    if (targetAlbumId != null) {
      await _openAlbumDetail(targetAlbumId);
    } else {
      await _refreshAlbumDetail(albumId);
    }
  }

  Future<void> _openArtistDetail(int artistId) async {
    if (_offlineMode) {
      final detail =
          _artistDetailCache[artistId] ??
          _artistDetailFromOverview(artistId) ??
          _offlineArtistDetail(_offlineLibrary, artistId);
      if (detail != null && mounted) {
        _mutate(() {
          _artistDetailCache[artistId] = detail;
          _navigateToInState(_AppRoute.artist(artistId));
        });
      }
      return;
    }
    final detail =
        _artistDetailCache[artistId] ?? _artistDetailFromOverview(artistId);
    if (detail == null || !mounted) return;
    _mutate(() {
      _artistDetailCache[artistId] = detail;
      _navigateToInState(_AppRoute.artist(artistId));
    });
    unawaited(_refreshArtistDetail(artistId));
  }

  Future<void> _openArtistByName(String displayName) async {
    final query = displayName.trim().toLowerCase();
    if (query.isEmpty) return;
    Map<String, dynamic>? match;
    for (final value in _artists.whereType<Map>()) {
      final artist = value.cast<String, dynamic>();
      final name = artist['name']?.toString().trim().toLowerCase() ?? '';
      if (name == query) {
        match = artist;
        break;
      }
    }
    if (match == null) {
      for (final value in _artists.whereType<Map>()) {
        final artist = value.cast<String, dynamic>();
        final name = artist['name']?.toString().trim().toLowerCase() ?? '';
        if (name.length >= 2 &&
            RegExp(
              '(^|[,;/&、，]\\s*)${RegExp.escape(name)}(\\s*[,;/&、，]|\$)',
            ).hasMatch(query)) {
          match = artist;
          break;
        }
      }
    }
    final artistId = _intValue(match?['id']);
    if (artistId != null) {
      await _openArtistDetail(artistId);
    }
  }

  Map<String, dynamic>? _artistDetailFromOverview(int artistId) {
    final artist = _findEntity(_artists, artistId);
    if (artist == null) return null;
    return <String, dynamic>{
      'artist': artist,
      'profile': <String, dynamic>{
        'display_name': artist['name'],
        'sort_name': artist['sort_name'],
        'aliases': const <String>[],
        'genres': const <String>[],
        'links': const <dynamic>[],
      },
      'assets': const <dynamic>[],
      'visuals': const <dynamic>[],
      'albums': const <dynamic>[],
      'tracks': const <dynamic>[],
    };
  }

  Future<void> _refreshArtistDetail(int artistId) async {
    try {
      final detail = _asMap(await _api.getJson('/artists/$artistId'));
      _artistDetailCache[artistId] = detail;
      await _persistDetail('artist', artistId, detail);
      if (mounted) {
        _mutate(
          () => _decorateDetailTrackAvailability(_artistDetailCache, artistId),
        );
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  void _closeArtistDetail() => _closeDetailPage();

  Future<void> _editArtist(int artistId, Map<String, dynamic> detail) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _ArtistEditorDialog(
          api: _api,
          artistId: artistId,
          detail: detail,
        ),
      ),
    );
    if (changed != true || !mounted) {
      return;
    }
    final refreshed = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/artists/$artistId')),
    );
    if (!mounted || refreshed == null) {
      return;
    }
    _mutate(() {
      _artistDetailCache[artistId] = refreshed;
      final artist = _asMap(refreshed['artist']);
      _artists = _artists
          .map(
            (value) => value is Map && _intValue(value['id']) == artistId
                ? artist
                : value,
          )
          .toList(growable: false);
    });
    unawaited(_persistDetail('artist', artistId, refreshed));
    unawaited(_persistOverviewValues(<String, dynamic>{'artists': _artists}));
    unawaited(_backgroundLibrarySync());
  }

  Future<void> _openTrackDetail(int trackId) async {
    if (_offlineMode) {
      final copy = await _availableOfflineCopy(trackId);
      final path = copy == null
          ? null
          : _offlineCopyPath(copy, _clientLibraryRoots);
      final cached =
          _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
      if (cached != null && mounted) {
        final detail = copy == null || path == null
            ? cached
            : _detailWithLocalCopy(cached, copy, path);
        _mutate(() {
          _trackDetailCache[trackId] = detail;
          _navigateToInState(_AppRoute.track(trackId));
        });
      }
      return;
    }
    final detail =
        _trackDetailCache[trackId] ?? _trackDetailFromOverview(trackId);
    if (detail == null || !mounted) return;
    _mutate(() {
      _trackDetailCache[trackId] = detail;
      _navigateToInState(_AppRoute.track(trackId));
    });
    unawaited(_refreshTrackDetail(trackId));
  }

  Map<String, dynamic> _detailWithLocalCopy(
    Map<String, dynamic> detail,
    _OfflineTrackCopy copy,
    String path,
  ) {
    return <String, dynamic>{
      ...detail,
      'track': <String, dynamic>{
        ..._asMap(detail['track']),
        '_local_available': true,
      },
      '_client_local_copy': <String, dynamic>{
        'media_variant_id': copy.mediaVariantId,
        'device_id': _clientId,
        'device_name': _clientAlias(),
        'source_kind': 'client',
        'availability_state': 'ready',
        'is_primary': false,
        'relative_path': copy.relativePath,
        'root_external_id': copy.rootExternalId,
        'client_file_id': copy.fileExternalId,
        'file_path': path,
        'extension': copy.extension,
        'size_bytes': copy.sizeBytes,
        'modified_at': copy.modifiedAt.toUtc().toIso8601String(),
        'codec': copy.metadata['codec'],
        'bitrate': copy.metadata['bitrate'],
        'sample_rate': copy.metadata['sample_rate'],
        'bit_depth': copy.metadata['bit_depth'],
        'channels': copy.metadata['channels'],
        'duration_ms': copy.metadata['duration_ms'],
      },
    };
  }

  Map<String, dynamic>? _trackDetailFromOverview(int trackId) {
    final track = _findEntity(_tracks, trackId);
    if (track == null) return null;
    return <String, dynamic>{
      'track': track,
      'file_path': '',
      'relative_path': '',
      'extension': '',
      'size_bytes': _intValue(track['size_bytes']) ?? 0,
      'modified_at': track['added_at'],
      'scan_status': 'cached_summary',
      'genres': const <String>[],
      'composers': const <String>[],
      'lyricists': const <String>[],
      'lyrics': null,
      'media': null,
    };
  }

  Future<void> _refreshTrackDetail(int trackId) async {
    try {
      final detail = _asMap(await _api.getJson('/tracks/$trackId'));
      _trackDetailCache[trackId] = detail;
      await _persistDetail('track', trackId, detail);
      if (_activeTrackDetailId == trackId) _activeTrackDetail = detail;
      if (mounted) {
        _mutate(() => _refreshTrackAvailabilityForTrack(trackId));
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Future<void> _refreshAfterLibraryManagementChange() async {
    _trackDetailCache.clear();
    _activeTrackDetail = null;
    await _ClientCacheStore.invalidateDetails(_coreUrlController.text, 'track');
    await _refreshAll();
  }

  Future<void> _editTrack(int trackId) async {
    final snapshot = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/tracks/$trackId/edit')),
    );
    if (!mounted || snapshot == null) {
      return;
    }
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _TrackEditorDialog(
          api: _api,
          trackId: trackId,
          snapshot: snapshot,
        ),
      ),
    );
    if (!mounted || updated == null) {
      return;
    }
    final detail = _asMap(updated['detail']);
    _mutate(() {
      _trackDetailCache[trackId] = detail;
      _searchResultCache.clear();
      final updatedTrack = _asMap(detail['track']);
      _replaceTrackInCollections(updatedTrack);
      if (_activeTrackDetailId == trackId) {
        _activeTrackDetail = detail;
      }
      _refreshTrackAvailabilityForTrack(trackId);
    });
    unawaited(_persistDetail('track', trackId, detail));
    unawaited(_persistOverviewValues(<String, dynamic>{'tracks': _tracks}));
    unawaited(_backgroundLibrarySync());
  }

  Future<void> _manageTrackVersions(int trackId) async {
    final detail = _trackDetailCache[trackId];
    if (detail == null) {
      return;
    }
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _LocaleScope(
        language: _language,
        child: _TrackVersionManagerDialog(
          api: _api,
          trackId: trackId,
          detail: detail,
        ),
      ),
    );
    if (changed != true || !mounted) {
      return;
    }
    final refreshed = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/tracks/$trackId')),
    );
    if (!mounted || refreshed == null) {
      return;
    }
    _mutate(() {
      _trackDetailCache[trackId] = refreshed;
      if (_activeTrackDetailId == trackId) {
        _activeTrackDetail = refreshed;
      }
      _refreshTrackAvailabilityForTrack(trackId);
    });
    unawaited(_persistDetail('track', trackId, refreshed));
    unawaited(_backgroundLibrarySync());
  }

  void _closeTrackDetail() => _closeDetailPage();

  Future<void> _openPlaylistDetail(int playlistId) async {
    final detail =
        _playlistDetailCache[playlistId] ??
        _playlistDetailFromOverview(playlistId);
    if (detail == null || !mounted) return;
    _mutate(() {
      _playlistDetailCache[playlistId] = detail;
      _navigateToInState(_AppRoute.playlist(playlistId));
    });
    if (!_offlineMode) {
      unawaited(_refreshPlaylistDetail(playlistId));
    }
  }

  Map<String, dynamic>? _playlistDetailFromOverview(int playlistId) {
    final playlist = _findEntity(_playlists, playlistId);
    if (playlist == null) return null;
    return <String, dynamic>{
      'playlist': playlist,
      'rules': null,
      'tracks': const <dynamic>[],
    };
  }

  Future<void> _refreshPlaylistDetail(int playlistId) async {
    try {
      final detail = _asMap(await _api.getJson('/playlists/$playlistId'));
      _playlistDetailCache[playlistId] = detail;
      await _persistDetail('playlist', playlistId, detail);
      if (mounted) {
        _mutate(
          () => _decorateDetailTrackAvailability(
            _playlistDetailCache,
            playlistId,
          ),
        );
      }
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
    }
  }

  Map<String, dynamic>? _findEntity(List<dynamic> values, int id) {
    for (final value in values) {
      if (value is Map && _intValue(value['id']) == id) {
        return value.cast<String, dynamic>();
      }
    }
    return null;
  }

  Future<void> _persistDetail(
    String kind,
    int id,
    Map<String, dynamic> detail,
  ) {
    final serverId = _cacheServerId ?? _status?['server_id']?.toString();
    if (serverId == null || serverId.isEmpty) return Future<void>.value();
    return _ClientCacheStore.putDetail(
      _coreUrlController.text,
      serverId,
      kind,
      id,
      detail,
    );
  }

  Future<void> _createManualPlaylist() async {
    final payload = await _showPanelDialog<Map<String, dynamic>>(
      maxWidth: 640,
      child: const _ManualPlaylistSheet(),
    );
    if (payload == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/playlists', payload)),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _createSmartPlaylist() async {
    final sourceOptions = await _smartPlaylistSourceOptions();
    if (!mounted) return;
    final payload = await _showPanelDialog<Map<String, dynamic>>(
      maxWidth: 760,
      child: _SmartPlaylistSheet(sourceOptions: sourceOptions),
    );
    if (payload == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/playlists', payload)),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _editSmartPlaylist(
    int playlistId,
    Map<String, dynamic> detail,
  ) async {
    final sourceOptions = await _smartPlaylistSourceOptions();
    if (!mounted) return;
    final payload = await _showPanelDialog<Map<String, dynamic>>(
      maxWidth: 760,
      child: _SmartPlaylistSheet(detail: detail, sourceOptions: sourceOptions),
    );
    if (payload == null) {
      return;
    }
    final updated = await _run<Map<String, dynamic>>(
      () async =>
          _asMap(await _api.postJson('/playlists/$playlistId', payload)),
    );
    if (!mounted || updated == null) {
      return;
    }
    await _reloadPlaylists();
    if (mounted) {
      _mutate(() => _playlistDetailCache[playlistId] = updated);
      unawaited(_persistDetail('playlist', playlistId, updated));
    }
  }

  Future<List<Map<String, dynamic>>> _smartPlaylistSourceOptions() async {
    if (_offlineMode) return const <Map<String, dynamic>>[];
    final unknownDeviceLabel = _tr(context, 'Unknown device');
    final musicSourceLabel = _tr(context, 'Music source');
    try {
      final devices =
          await _api.getBulkJson('/library-management/devices')
              as List<dynamic>;
      return <Map<String, dynamic>>[
        for (final value in devices)
          if (value is Map)
            for (final source
                in ((_asMap(value)['sources'] as List?) ?? const <dynamic>[]))
              if (source is Map &&
                  _asMap(source)['state']?.toString() != 'retired' &&
                  _intValue(_asMap(source)['root_id']) != null)
                <String, dynamic>{
                  'id': _intValue(_asMap(source)['root_id']).toString(),
                  'device_id': _asMap(value)['device_id']?.toString(),
                  'device_name':
                      _asMap(value)['display_name']?.toString() ??
                      unknownDeviceLabel,
                  'source_name':
                      _asMap(source)['display_name']?.toString() ??
                      musicSourceLabel,
                  'state': _asMap(source)['state']?.toString() ?? 'offline',
                  'file_count': _intValue(_asMap(source)['file_count']) ?? 0,
                },
      ];
    } catch (error) {
      await _ClientCacheStore.recordError(_coreUrlController.text, error);
      return const <Map<String, dynamic>>[];
    }
  }

  Future<void> _deletePlaylist(int playlistId) async {
    final result = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.deleteJson('/playlists/$playlistId')),
    );
    if (mounted && result != null) {
      await _reloadPlaylists();
    }
  }

  Future<void> _reloadPlaylists() async {
    final playlists = await _api.getJson('/playlists') as List<dynamic>;
    if (mounted) {
      _mutate(() => _playlists = playlists);
    }
    await _persistOverviewValues(<String, dynamic>{'playlists': playlists});
  }

  Future<void> _addTrackToPlaylist(int trackId) async {
    final manualPlaylists = _playlists
        .where((item) => _asMap(item)['kind']?.toString() == 'manual')
        .toList(growable: false);
    if (manualPlaylists.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Create a manual playlist first')),
        );
      }
      return;
    }
    final playlistId = await _showPanelDialog<int>(
      maxWidth: 560,
      child: _AddToPlaylistSheet(playlists: manualPlaylists),
    );
    if (playlistId == null) {
      return;
    }
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson('/playlists/$playlistId/tracks', <String, dynamic>{
          'track_id': trackId,
        }),
      ),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
      final playlistId = _intValue(_asMap(detail['playlist'])['id']);
      if (playlistId != null) {
        _playlistDetailCache[playlistId] = detail;
        _decorateDetailTrackAvailability(_playlistDetailCache, playlistId);
        unawaited(_persistDetail('playlist', playlistId, detail));
      }
    }
  }

  Future<void> _removeTrackFromPlaylist({
    required int playlistId,
    required int trackId,
  }) async {
    final detail = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.deleteJson('/playlists/$playlistId/tracks/$trackId'),
      ),
    );
    if (mounted && detail != null) {
      await _reloadPlaylists();
      if (!mounted) {
        return;
      }
      _mutate(() {
        _playlistDetailCache[playlistId] = detail;
        _decorateDetailTrackAvailability(_playlistDetailCache, playlistId);
      });
      unawaited(_persistDetail('playlist', playlistId, detail));
    }
  }

  Future<void> _toggleFavorite(Map<String, dynamic> track) async {
    final trackId = _intValue(track['id']);
    if (trackId == null) {
      return;
    }
    final favorite = track['is_favorite'] != true;
    final mutation = _OfflineMutation(
      id: _newClientMutationId(),
      kind: 'favorite',
      trackId: trackId,
      occurredAt: DateTime.now().toUtc(),
      payload: <String, dynamic>{'is_favorite': favorite},
    );
    _offlineLibrary.setFavorite(trackId, favorite);
    _offlineLibrary.outbox.add(mutation);
    final optimisticTrack = <String, dynamic>{
      ...track,
      'is_favorite': favorite,
      if (favorite && track['user_rating'] == null) 'user_rating': 100,
    };
    if (mounted) {
      _mutate(() {
        _replaceTrackInCollections(optimisticTrack);
        _replaceTrackInDetailCache(_albumDetailCache, optimisticTrack);
        _replaceTrackInDetailCache(_artistDetailCache, optimisticTrack);
        _replaceTrackInDetailCache(_playlistDetailCache, optimisticTrack);
        final detail = _trackDetailCache[trackId];
        if (detail != null) {
          _trackDetailCache[trackId] = <String, dynamic>{
            ...detail,
            'track': optimisticTrack,
          };
        }
        if (_activeTrackDetailId == trackId && _activeTrackDetail != null) {
          _activeTrackDetail = <String, dynamic>{
            ...?_activeTrackDetail,
            'track': optimisticTrack,
          };
        }
      });
    }
    await _OfflineLibraryStore.save(_offlineLibrary);
    await _persistOverviewValues(<String, dynamic>{'tracks': _tracks});
    if (_offlineMode) return;
    Map<String, dynamic> detail;
    try {
      detail = _asMap(
        await _api.postJson('/tracks/$trackId/favorite', <String, dynamic>{
          'is_favorite': favorite,
        }),
      );
      _offlineLibrary.outbox.removeWhere((value) => value.id == mutation.id);
      unawaited(_OfflineLibraryStore.save(_offlineLibrary));
    } catch (_) {
      if (mounted) {
        _mutate(() => _rendererStatus = 'Change queued for synchronization');
      }
      return;
    }
    if (!mounted) {
      return;
    }
    final updatedTrack = _asMap(detail['track']);
    _offlineLibrary.setFavorite(trackId, updatedTrack['is_favorite'] == true);
    unawaited(_OfflineLibraryStore.save(_offlineLibrary));
    _mutate(() {
      _replaceTrackInCollections(updatedTrack);
      if (_activeTrackDetailId == trackId) {
        _activeTrackDetail = detail;
      }
      _trackDetailCache[trackId] = detail;
      _replaceTrackInDetailCache(_albumDetailCache, updatedTrack);
      _replaceTrackInDetailCache(_artistDetailCache, updatedTrack);
      _replaceTrackInDetailCache(_playlistDetailCache, updatedTrack);
    });
    unawaited(_persistDetail('track', trackId, detail));
    unawaited(_persistOverviewValues(<String, dynamic>{'tracks': _tracks}));
  }

  Future<void> _persistOverviewValues(Map<String, dynamic> values) {
    final serverId = _cacheServerId ?? _status?['server_id']?.toString();
    if (serverId == null || serverId.isEmpty) return Future<void>.value();
    return _ClientCacheStore.putOverviewValues(
      _coreUrlController.text,
      serverId,
      values,
    );
  }

  void _replaceTrackInDetailCache(
    Map<int, Map<String, dynamic>> cache,
    Map<String, dynamic> updatedTrack,
  ) {
    final trackId = _intValue(updatedTrack['id']);
    if (trackId == null) {
      return;
    }
    for (final entry in cache.entries.toList(growable: false)) {
      final tracks = (entry.value['tracks'] as List?) ?? const [];
      cache[entry.key] = <String, dynamic>{
        ...entry.value,
        'tracks': tracks
            .map((item) {
              final track = (item as Map).cast<String, dynamic>();
              return _intValue(track['id']) == trackId ? updatedTrack : track;
            })
            .toList(growable: false),
      };
    }
  }

  Future<void> _updateFavoriteSettings(Map<String, dynamic> payload) async {
    final settings = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/settings/favorites', payload)),
    );
    if (mounted && settings != null) {
      _mutate(() => _favoriteSettings = settings);
      await _refreshAll();
    }
  }

  Future<void> _updateMetadataSettings(Map<String, dynamic> payload) async {
    final settings = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.postJson('/settings/metadata', payload)),
    );
    if (mounted && settings != null) {
      _mutate(() => _metadataSettings = settings);
    }
  }

  void _replaceTrackInCollections(Map<String, dynamic> updatedTrack) {
    final trackId = _intValue(updatedTrack['id']);
    if (trackId == null) {
      return;
    }
    List<dynamic> replaceInList(List<dynamic> items) => items
        .map((item) {
          final map = (item as Map).cast<String, dynamic>();
          return _intValue(map['id']) == trackId ? updatedTrack : map;
        })
        .toList(growable: false);

    _tracks = replaceInList(_tracks);
    for (final entry in _searchResultCache.entries.toList(growable: false)) {
      final tracks = (entry.value['tracks'] as List?) ?? const [];
      _searchResultCache[entry.key] = <String, dynamic>{
        ...entry.value,
        'tracks': replaceInList(tracks),
      };
    }
  }
}
