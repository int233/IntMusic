part of '../intmusic_client.dart';

extension _DashboardLibrary on _CoreDashboardState {
  Future<void> _startScan() async {
    await _run<void>(() async {
      await _api.postJson('/scan/start', <String, dynamic>{});
      await _refreshAll();
    });
  }

  Future<void> _addLibraryRoot() async {
    final path = _libraryRootController.text.trim();
    if (path.isEmpty) {
      _mutate(() => _error = 'Music folder path is empty');
      return;
    }
    final result = await _run<Map<String, dynamic>>(() async {
      await _api.postJson('/library/roots', <String, dynamic>{'path': path});
      return _refreshLibrarySettingsPayload();
    });
    if (!mounted || result == null) {
      return;
    }
    _mutate(() {
      _libraryRootController.clear();
      _applyLibrarySettingsPayload(result);
    });
  }

  Future<void> _removeLibraryRoot(int id) async {
    final result = await _run<Map<String, dynamic>>(() async {
      await _api.deleteJson('/library/roots/$id');
      return _refreshLibrarySettingsPayload();
    });
    if (!mounted || result == null) {
      return;
    }
    _mutate(() => _applyLibrarySettingsPayload(result));
  }

  Future<void> _addClientLibraryRoot() async {
    try {
      final addFolderLabel = _tr(context, 'Add folder');
      final androidSelection = Platform.isAndroid
          ? await _IntMusicPlatform.instance.selectClientLibraryFolder()
          : null;
      final path = Platform.isAndroid
          ? androidSelection?.path
          : await getDirectoryPath(confirmButtonText: addFolderLabel);
      if (!mounted || path == null || path.trim().isEmpty) {
        return;
      }
      final access = Platform.isAndroid
          ? (path: path, token: androidSelection!.token as String?)
          : await _IntMusicPlatform.instance.persistFolderAccess(path);
      final normalizedPath = _normalizeLocalRootPath(access.path);
      final existing = _clientLibraryRoots
          .where((root) => root.path == normalizedPath)
          .firstOrNull;
      if (existing != null) {
        await _syncClientLibraryRoot(existing.externalId);
        return;
      }
      final root = _ClientLibraryRoot(
        externalId: _stableClientLibraryRootId(normalizedPath),
        path: normalizedPath,
        displayName:
            androidSelection?.displayName ??
            _localRootDisplayName(normalizedPath),
        accessToken: access.token,
      );
      _mutate(() => _clientLibraryRoots = [..._clientLibraryRoots, root]);
      await _persistClientLibraryRoots();
      await _syncClientLibraryRoot(root.externalId);
    } catch (error) {
      if (mounted) {
        _mutate(() => _error = 'Unable to add this device folder: $error');
      }
    }
  }

  Future<void> _syncAllClientLibraryRoots({bool refreshAfter = true}) async {
    for (final root in List<_ClientLibraryRoot>.of(_clientLibraryRoots)) {
      await _syncClientLibraryRoot(root.externalId, refreshAfter: false);
    }
    if (refreshAfter && mounted && _clientLibraryRoots.isNotEmpty) {
      await _refreshAll();
    }
  }

  Future<void> _syncClientLibraryRoot(
    String externalId, {
    bool refreshAfter = true,
  }) async {
    if (!_clientLibraryQueuedRootIds.add(externalId)) return;
    final operation = _clientLibrarySyncQueue.then(
      (_) => _syncClientLibraryRootNow(externalId, refreshAfter: refreshAfter),
    );
    _clientLibrarySyncQueue = operation;
    try {
      await operation;
    } finally {
      _clientLibraryQueuedRootIds.remove(externalId);
    }
  }

  Future<void> _syncClientLibraryRootNow(
    String externalId, {
    required bool refreshAfter,
  }) async {
    final root = _clientLibraryRoots
        .where((item) => item.externalId == externalId)
        .firstOrNull;
    if (root == null) return;
    _mutate(() {
      _clientLibrarySyncingRootIds.add(externalId);
      _replaceClientLibraryRoot(root.copyWith(clearError: true));
    });
    try {
      final directory = Directory(root.path);
      if (!await directory.exists()) {
        throw FileSystemException(
          'The folder is unavailable. Re-add it to restore access.',
          root.path,
        );
      }
      final scanId =
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
      var accepted = 0;
      var batch = <Map<String, dynamic>>[];
      var inspectionPaths = <String>[];
      var manifestBatchTarget = 20;
      var manifestBatchSequence = 0;
      final seenExternalIds = <String>{};
      Future<void> sendBatch({required bool complete}) async {
        final sentBatch = List<Map<String, dynamic>>.of(batch);
        final sequence = manifestBatchSequence++;
        final stopwatch = Stopwatch()..start();
        ClientLog.event(
          'client_library.manifest.start',
          data: <String, Object?>{
            'root_external_id': root.externalId,
            'scan_id': scanId,
            'batch_sequence': sequence,
            'file_count': sentBatch.length,
            'complete': complete,
          },
        );
        final result = _asMap(
          await _api.postLibrarySyncJson(
            '/client-library/manifests',
            <String, dynamic>{
              'device_id': _clientId,
              'device_name': _clientAlias(),
              'platform': Platform.operatingSystem,
              'root': <String, dynamic>{
                'external_id': root.externalId,
                'display_name': root.displayName,
                'path_hint': root.path,
              },
              'scan_id': scanId,
              'batch_id': '$scanId:$sequence',
              'complete': complete,
              'files': sentBatch,
            },
          ),
        );
        final elapsed = stopwatch.elapsed;
        manifestBatchTarget = switch (elapsed.inSeconds) {
          >= 8 => 10,
          >= 3 => 20,
          _ => 50,
        };
        ClientLog.event(
          'client_library.manifest.end',
          data: <String, Object?>{
            'root_external_id': root.externalId,
            'scan_id': scanId,
            'batch_sequence': sequence,
            'file_count': sentBatch.length,
            'elapsed_ms': elapsed.inMilliseconds,
            'next_batch_target': manifestBatchTarget,
            'complete': complete,
          },
        );
        accepted += _intValue(result['accepted_files']) ?? sentBatch.length;
        final bindings = <String, Map<String, dynamic>>{
          for (final value in ((result['bindings'] as List?) ?? const []))
            if (value is Map && value['external_id'] != null)
              value['external_id'].toString(): value.cast<String, dynamic>(),
        };
        for (final file in sentBatch) {
          final externalId = file['external_id']?.toString();
          final binding = externalId == null ? null : bindings[externalId];
          final trackId = _intValue(binding?['track_id']);
          final variantId = _intValue(binding?['media_variant_id']);
          if (externalId == null || trackId == null || variantId == null) {
            continue;
          }
          seenExternalIds.add(externalId);
          _offlineLibrary.upsert(
            _OfflineTrackCopy(
              trackId: trackId,
              mediaVariantId: variantId,
              rootExternalId: root.externalId,
              fileExternalId: externalId,
              relativePath: file['relative_path']?.toString() ?? externalId,
              extension: file['extension']?.toString() ?? '',
              sizeBytes: _intValue(file['size_bytes']) ?? 0,
              modifiedAt:
                  DateTime.tryParse(file['modified_at']?.toString() ?? '') ??
                  DateTime.now().toUtc(),
              metadata:
                  (file['metadata'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{},
              isFavorite: _offlineLibrary.track(trackId)?.isFavorite ?? false,
              playCount: _offlineLibrary.track(trackId)?.playCount ?? 0,
            ),
          );
        }
        batch = <Map<String, dynamic>>[];
      }

      Future<void> inspectPendingPaths() async {
        if (inspectionPaths.isEmpty) return;
        final paths = List<String>.of(inspectionPaths);
        inspectionPaths = <String>[];
        final inspected = await inspectClientFilesInBackground(
          rootPath: root.path,
          filePaths: paths,
        );
        batch.addAll(inspected);
        if (batch.length >= manifestBatchTarget) {
          await sendBatch(complete: false);
        }
      }

      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !_isSupportedClientAudioPath(entity.path)) {
          continue;
        }
        inspectionPaths.add(entity.path);
        if (inspectionPaths.length >= 20) {
          await inspectPendingPaths();
        }
      }
      await inspectPendingPaths();
      await sendBatch(complete: true);
      _offlineLibrary.retainRootFiles(root.externalId, seenExternalIds);
      await _OfflineLibraryStore.save(_offlineLibrary);
      final updated = root.copyWith(
        lastSyncedAt: DateTime.now().toUtc(),
        fileCount: accepted,
        clearError: true,
      );
      if (mounted) {
        _mutate(() => _replaceClientLibraryRoot(updated));
      } else {
        _replaceClientLibraryRoot(updated);
      }
      await _persistClientLibraryRoots();
      if (refreshAfter && mounted) {
        await _refreshAll();
      }
    } catch (error) {
      final updated = root.copyWith(lastError: error.toString());
      if (mounted) {
        _mutate(() {
          _replaceClientLibraryRoot(updated);
          _error = 'Local library sync failed: $error';
        });
      } else {
        _replaceClientLibraryRoot(updated);
      }
      await _persistClientLibraryRoots();
    } finally {
      if (mounted) {
        _mutate(() => _clientLibrarySyncingRootIds.remove(externalId));
      } else {
        _clientLibrarySyncingRootIds.remove(externalId);
      }
    }
  }

  Future<void> _removeClientLibraryRoot(String externalId) async {
    final root = _clientLibraryRoots
        .where((item) => item.externalId == externalId)
        .firstOrNull;
    if (root == null) {
      return;
    }
    try {
      await _api.deleteJson(
        '/client-library/devices/${Uri.encodeComponent(_clientId)}'
        '/roots/${Uri.encodeComponent(externalId)}',
      );
      if (!mounted) {
        return;
      }
      _mutate(() {
        _clientLibraryRoots = _clientLibraryRoots
            .where((item) => item.externalId != externalId)
            .toList(growable: false);
        _offlineLibrary.retainRootFiles(externalId, const <String>{});
      });
      await _persistClientLibraryRoots();
      await _OfflineLibraryStore.save(_offlineLibrary);
      await _refreshAll();
    } catch (error) {
      if (mounted) {
        _mutate(() => _error = 'Unable to remove local folder: $error');
      }
    }
  }

  void _replaceClientLibraryRoot(_ClientLibraryRoot replacement) {
    _clientLibraryRoots = _clientLibraryRoots
        .map(
          (root) =>
              root.externalId == replacement.externalId ? replacement : root,
        )
        .toList(growable: false);
  }

  Future<void> _persistClientLibraryRoots() async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setString(
      _prefsClientLibraryRootsKey,
      jsonEncode(
        _clientLibraryRoots
            .map((root) => root.toJson())
            .toList(growable: false),
      ),
    );
  }

  Future<Map<String, dynamic>> _refreshLibrarySettingsPayload() async {
    final results = await Future.wait([
      _api.getJson('/library/roots'),
      _api.getJson('/status'),
      _api.getJson('/diagnostics'),
    ]);
    return <String, dynamic>{
      'roots': results[0],
      'status': results[1],
      'diagnostics': results[2],
    };
  }

  void _applyLibrarySettingsPayload(Map<String, dynamic> result) {
    _libraryRoots = (result['roots'] as List?) ?? const [];
    _status = _asMap(result['status']);
    _diagnostics = _asMap(result['diagnostics']);
  }

  Future<Map<String, dynamic>> _loadSearch(String query, {int limit = 25}) {
    final normalizedTerms = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    bool matches(Map<String, dynamic> value, Iterable<String> keys) {
      final searchable = keys
          .map((key) => value[key]?.toString().toLowerCase() ?? '')
          .join(' ');
      return normalizedTerms.every(searchable.contains);
    }

    List<dynamic> filter(List<dynamic> values, Iterable<String> keys) => values
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .where((value) => matches(value, keys))
        .take(limit)
        .toList(growable: false);

    final memoryResult = <String, dynamic>{
      'query': query,
      'tracks': filter(_tracks, const [
        'title',
        'artist_display',
        'album_title',
      ]),
      'albums': filter(_albums, const [
        'title',
        'album_artist_display',
        'year',
      ]),
      'artists': filter(_artists, const ['name', 'sort_name']),
      'playlists': filter(_playlists, const ['name', 'description']),
    };
    return _ClientCacheStore.search(
      _coreUrlController.text,
      query,
      limit: limit,
    ).then((cached) {
      final cachedCount =
          const <String>['tracks', 'albums', 'artists', 'playlists'].fold<int>(
            0,
            (count, key) => count + ((cached[key] as List?)?.length ?? 0),
          );
      return cachedCount == 0 ? memoryResult : cached;
    });
  }

  void _onSearchChanged(String value) {
    final query = value.trim();
    _searchDebounce?.cancel();
    if (query.isEmpty) {
      _mutate(() => _searchSuggestions = const []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      unawaited(_loadSearchSuggestions(query));
    });
  }

  Future<void> _loadSearchSuggestions(String query) async {
    try {
      final result = await _loadSearch(query, limit: 6);
      if (!mounted || _searchController.text.trim() != query) {
        return;
      }
      _mutate(() => _searchSuggestions = _suggestionsFromSearch(result));
    } catch (_) {
      if (mounted) {
        _mutate(() => _searchSuggestions = const []);
      }
    }
  }

  List<_SearchSuggestion> _suggestionsFromSearch(Map<String, dynamic> result) {
    final suggestions = <_SearchSuggestion>[];
    void addItems(List<dynamic> items, _ResultKind kind) {
      for (final item in items) {
        final map = (item as Map).cast<String, dynamic>();
        final id = _intValue(map['id']);
        if (id == null) {
          continue;
        }
        final title = (map['title'] ?? map['name'] ?? 'Untitled').toString();
        suggestions.add(
          _SearchSuggestion(
            kind: kind,
            id: id,
            title: title,
            subtitle: _searchSubtitle(map, kind),
            icon: switch (kind) {
              _ResultKind.track => Icons.music_note_outlined,
              _ResultKind.album => Icons.album_outlined,
              _ResultKind.artist => Icons.person_outline,
              _ResultKind.playlist => Icons.queue_music_outlined,
            },
          ),
        );
      }
    }

    addItems((result['tracks'] as List?) ?? const [], _ResultKind.track);
    addItems((result['albums'] as List?) ?? const [], _ResultKind.album);
    addItems((result['artists'] as List?) ?? const [], _ResultKind.artist);
    addItems((result['playlists'] as List?) ?? const [], _ResultKind.playlist);
    return suggestions.take(10).toList(growable: false);
  }

  Future<void> _submitSearch(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      return;
    }
    _rememberSearch(query);
    final result = await _loadSearch(query, limit: 120);
    if (!mounted) return;
    _mutate(() {
      _searchResultCache[query] = result;
      _searchQuery = query;
      _searchScopeByQuery.putIfAbsent(query, () => _SearchScope.all);
      _searchSortByQuery.putIfAbsent(query, () => _SearchSort.relevance);
      _navigateToInState(_AppRoute.search(query));
      _searchSuggestions = const [];
      _decorateSearchTrackAvailability(query);
    });
  }

  void _rememberSearch(String query) {
    final updated = <String>[
      query,
      ..._recentSearches.where(
        (item) => item.toLowerCase() != query.toLowerCase(),
      ),
    ].take(10).toList(growable: false);
    _mutate(() => _recentSearches = updated);
    unawaited(_persistRecentSearches(updated));
  }

  Future<void> _persistRecentSearches(List<String> searches) async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setStringList(_prefsRecentSearchesKey, searches);
    } catch (_) {
      // Search history remains available for the current session.
    }
  }

  void _selectRecentSearch(String query) {
    _searchController.text = query;
    _searchController.selection = TextSelection.collapsed(offset: query.length);
    unawaited(_submitSearch(query));
  }

  void _selectSearchSuggestion(_SearchSuggestion suggestion) {
    _searchController.text = suggestion.title;
    _searchController.selection = TextSelection.collapsed(
      offset: suggestion.title.length,
    );
    switch (suggestion.kind) {
      case _ResultKind.track:
        unawaited(_openTrackDetail(suggestion.id));
      case _ResultKind.album:
        unawaited(_openAlbumDetail(suggestion.id));
      case _ResultKind.artist:
        unawaited(_openArtistDetail(suggestion.id));
      case _ResultKind.playlist:
        unawaited(_openPlaylistDetail(suggestion.id));
    }
  }

  void _clearSearch() {
    _searchController.clear();
    _mutate(() {
      _searchQuery = '';
      _searchSuggestions = const [];
      if (_currentRoute.kind == _AppRouteKind.search) {
        _navigateToInState(const _AppRoute.home());
      }
    });
  }
}
