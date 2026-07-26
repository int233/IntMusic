part of '../intmusic_client.dart';

extension _DashboardBootstrap on _CoreDashboardState {
  Future<void> _refreshAll() async {
    bool connected;
    if (_tracks.isNotEmpty || _albums.isNotEmpty || _artists.isNotEmpty) {
      try {
        await _refreshAllInner(allowDiscovery: true);
        connected = true;
        if (mounted) _mutate(() => _error = null);
      } catch (error) {
        connected = false;
        await _ClientCacheStore.recordError(_coreUrlController.text, error);
        if (mounted) {
          _mutate(() {
            _rendererStatus = 'Using cached library';
            _error = null;
          });
        }
      }
    } else {
      connected =
          await _run<bool>(() async {
            await _refreshAllInner(allowDiscovery: true);
            return true;
          }) ??
          false;
    }
    if (connected != true && _offlineLibrary.copies.isNotEmpty) {
      await _activateOfflineMode();
    }
  }

  Future<void> _initializeAndRefresh() async {
    await _IntMusicPlatform.instance.initialize(
      onCommand: _handlePlatformCommand,
      onSeek: _seekPlayback,
    );
    await _loadSavedCoreUrl();
    await _loadClientCache();
    await _rendererAudioInitialization;
    await _refreshAll();
  }

  Future<void> _loadClientCache() async {
    final cached = await _ClientCacheStore.load(_coreUrlController.text);
    if (cached.isEmpty || !mounted) return;
    _mutate(() {
      _cacheServerId = cached.serverId;
      _cacheCursor = cached.cursor;
      _applyCachedValues(cached.values);
      _trackDetailCache.addAll(cached.trackDetails);
      _albumDetailCache.addAll(cached.albumDetails);
      _artistDetailCache.addAll(cached.artistDetails);
      _playlistDetailCache.addAll(cached.playlistDetails);
      _detailWarmAfterIds.addAll(cached.pendingDetailRefresh);
      _detailWarmTargetCursors.addAll(cached.pendingDetailTargetCursors);
      _detailRefreshScopes.addAll(cached.pendingDetailRefresh.keys);
      _reconcileTrackSummariesInDetails();
      _rendererStatus = 'Cached library ready';
    });
  }

  void _applyCachedValues(Map<String, dynamic> values) {
    _albums = (values['albums'] as List?) ?? _albums;
    _artists = (values['artists'] as List?) ?? _artists;
    _tracks = (values['tracks'] as List?) ?? _tracks;
    _playlists = (values['playlists'] as List?) ?? _playlists;
    _outputs = (values['outputs'] as List?) ?? _outputs;
    _zones = (values['zones'] as List?) ?? _zones;
    if (values['playback'] is Map) {
      _playback = _withPlaybackTimestamp(_asMap(values['playback']));
    }
    if (values['playback_queue'] is Map) {
      _playbackQueue = _asMap(values['playback_queue']);
    }
    _playbackHistory =
        (values['playback_history'] as List?) ?? _playbackHistory;
    if (values['playback_stats'] is Map) {
      _playbackStats = _asMap(values['playback_stats']);
    }
    _libraryRoots = (values['library_roots'] as List?) ?? _libraryRoots;
    _clientLibraryStatuses =
        (values['client_library_roots'] as List?) ?? _clientLibraryStatuses;
    final settings = _asMap(values['settings']);
    if (settings.isNotEmpty) {
      _serverSettings = _asMap(settings['server']);
      _favoriteSettings = _asMap(settings['favorites']);
      _metadataSettings = _asMap(settings['metadata']);
    }
    if (values['status'] is Map) {
      _status = _asMap(values['status']);
    }
    if (values['diagnostics'] is Map) {
      _diagnostics = _asMap(values['diagnostics']);
    }
  }

  void _applySyncSnapshot(
    Map<String, dynamic> snapshot, {
    Map<String, dynamic>? status,
    Map<String, dynamic>? diagnostics,
  }) {
    final nextServerId = snapshot['server_id']?.toString();
    final serverChanged =
        _cacheServerId != null &&
        nextServerId != null &&
        _cacheServerId != nextServerId;
    if (serverChanged) {
      _trackDetailCache.clear();
      _albumDetailCache.clear();
      _artistDetailCache.clear();
      _playlistDetailCache.clear();
      _searchResultCache.clear();
      _detailWarmAfterIds.clear();
      _detailWarmTargetCursors.clear();
      _activeTrackDetail = null;
      _activeTrackDetailId = null;
    }
    _cacheServerId = nextServerId;
    _cacheCursor = _intValue(snapshot['cursor']) ?? _cacheCursor;
    _albums = (snapshot['albums'] as List?) ?? const <dynamic>[];
    _artists = (snapshot['artists'] as List?) ?? const <dynamic>[];
    _tracks = (snapshot['tracks'] as List?) ?? const <dynamic>[];
    _playlists = (snapshot['playlists'] as List?) ?? const <dynamic>[];
    _playbackHistory =
        (snapshot['playback_history'] as List?) ?? const <dynamic>[];
    _playbackStats = _asMap(snapshot['playback_stats']);
    _libraryRoots = (snapshot['library_roots'] as List?) ?? const <dynamic>[];
    _clientLibraryStatuses =
        (snapshot['client_library_roots'] as List?) ?? const <dynamic>[];
    final settings = _asMap(snapshot['settings']);
    _serverSettings = _asMap(settings['server']);
    _favoriteSettings = _asMap(settings['favorites']);
    _metadataSettings = _asMap(settings['metadata']);
    final trackIds = _entityIds(_tracks);
    final albumIds = _entityIds(_albums);
    final artistIds = _entityIds(_artists);
    final playlistIds = _entityIds(_playlists);
    _trackDetailCache.removeWhere((id, _) => !trackIds.contains(id));
    _albumDetailCache.removeWhere((id, _) => !albumIds.contains(id));
    _artistDetailCache.removeWhere((id, _) => !artistIds.contains(id));
    _playlistDetailCache.removeWhere((id, _) => !playlistIds.contains(id));
    _reconcileTrackSummariesInDetails();
    if (status != null) _status = status;
    if (diagnostics != null) _diagnostics = diagnostics;
  }

  Set<int> _entityIds(List<dynamic> values) => <int>{
    for (final value in values)
      if (value is Map && _intValue(value['id']) != null)
        _intValue(value['id'])!,
  };

  void _reconcileTrackSummariesInDetails() {
    final tracksById = <int, Map<String, dynamic>>{
      for (final value in _tracks)
        if (value is Map && _intValue(value['id']) != null)
          _intValue(value['id'])!: value.cast<String, dynamic>(),
    };
    for (final entry in _trackDetailCache.entries.toList(growable: false)) {
      final summary = tracksById[entry.key];
      if (summary != null) {
        _trackDetailCache[entry.key] = <String, dynamic>{
          ...entry.value,
          'track': summary,
        };
      }
    }
    for (final cache in <Map<int, Map<String, dynamic>>>[
      _albumDetailCache,
      _artistDetailCache,
      _playlistDetailCache,
    ]) {
      for (final entry in cache.entries.toList(growable: false)) {
        final detailTracks = (entry.value['tracks'] as List?) ?? const [];
        cache[entry.key] = <String, dynamic>{
          ...entry.value,
          'tracks': detailTracks
              .map((value) {
                if (value is! Map) return value;
                final id = _intValue(value['id']);
                return id == null ? value : tracksById[id] ?? value;
              })
              .toList(growable: false),
        };
      }
    }
  }

  Map<String, dynamic> _snapshotForStorage(
    Map<String, dynamic> snapshot, {
    Map<String, dynamic>? status,
    Map<String, dynamic>? diagnostics,
  }) {
    final stored = <String, dynamic>{...snapshot};
    if (status != null) stored['status'] = status;
    if (diagnostics != null) stored['diagnostics'] = diagnostics;
    return stored;
  }

  Future<void> _handlePlatformCommand(_PlatformCommand command) async {
    switch (command) {
      case _PlatformCommand.play:
        await _resumePlayback();
      case _PlatformCommand.pause:
        await _pausePlayback();
      case _PlatformCommand.togglePlayPause:
        if (_playback?['state']?.toString() == 'playing') {
          await _pausePlayback();
        } else {
          await _resumePlayback();
        }
      case _PlatformCommand.previous:
        await _playPreviousTrack();
      case _PlatformCommand.next:
        await _playNextTrack();
      case _PlatformCommand.stop:
        await _stopZone(_activeZoneId());
      case _PlatformCommand.showWindow:
        await _IntMusicPlatform.instance.showWindow();
      case _PlatformCommand.quit:
        await SystemNavigator.pop();
    }
  }

  Future<void> _loadSavedCoreUrl() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      final savedUrl = preferences.getString(_prefsCoreUrlKey)?.trim();
      final savedLanguage = preferences.getString(_prefsLanguageKey)?.trim();
      final savedClientAlias = preferences
          .getString(_prefsClientAliasKey)
          ?.trim();
      final language = _languageFromPreference(savedLanguage);
      final albumViewMode = _viewModeFromPreference(
        preferences.getString(_prefsAlbumViewModeKey),
      );
      final artistViewMode = _viewModeFromPreference(
        preferences.getString(_prefsArtistViewModeKey),
      );
      final trackViewMode = _viewModeFromPreference(
        preferences.getString(_prefsTrackViewModeKey),
        fallback: _LibraryViewMode.list,
      );
      final playlistViewMode = _viewModeFromPreference(
        preferences.getString(_prefsPlaylistViewModeKey),
      );
      final recentSearches =
          preferences.getStringList(_prefsRecentSearchesKey) ?? const [];
      final pinCurrentClientRegion =
          preferences.getBool(_prefsPinCurrentClientRegionKey) ?? true;
      final zoneRegionSort = _zoneRegionSortFromPreference(
        preferences.getString(_prefsRegionSortKey),
      );
      final diagnosticLoggingEnabled =
          preferences.getBool(_prefsDiagnosticLoggingKey) ?? true;
      await ClientLog.initialize(enabled: diagnosticLoggingEnabled);
      var clientLibraryRoots = _decodeClientLibraryRoots(
        preferences.getString(_prefsClientLibraryRootsKey),
      );
      clientLibraryRoots = await Future.wait(
        clientLibraryRoots.map((root) async {
          final access = await _IntMusicPlatform.instance.restoreFolderAccess(
            root.path,
            root.accessToken,
          );
          return root.copyWith(path: access.path, accessToken: access.token);
        }),
      );
      await preferences.setString(
        _prefsClientLibraryRootsKey,
        jsonEncode(
          clientLibraryRoots
              .map((root) => root.toJson())
              .toList(growable: false),
        ),
      );
      final offlineLibrary = await _OfflineLibraryStore.load();
      if (!mounted) {
        return;
      }
      _mutate(() {
        if (savedUrl != null && savedUrl.isNotEmpty) {
          _coreUrlController.text = savedUrl;
        }
        if (language != null) {
          _language = language;
        }
        _albumViewMode = albumViewMode;
        _artistViewMode = artistViewMode;
        _trackViewMode = trackViewMode;
        _playlistViewMode = playlistViewMode;
        _pinCurrentClientRegion = pinCurrentClientRegion;
        _zoneRegionSort = zoneRegionSort;
        _diagnosticLoggingEnabled = diagnosticLoggingEnabled;
        _diagnosticLogPath = ClientLog.path;
        _clientLibraryRoots = clientLibraryRoots;
        _offlineLibrary = offlineLibrary;
        _recentSearches = recentSearches.take(10).toList(growable: false);
        _clientAliasController.text = savedClientAlias?.isNotEmpty == true
            ? savedClientAlias!
            : _defaultClientAlias();
      });
    } catch (error, stackTrace) {
      ClientLog.error(
        'client.preferences.load_failed',
        error,
        stackTrace: stackTrace,
      );
      // Preferences are optional; discovery can still find the core.
    }
  }

  Future<void> _setDiagnosticLogging(bool enabled) async {
    final preferences = _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setBool(_prefsDiagnosticLoggingKey, enabled);
    if (ClientLog.path.isEmpty) {
      await ClientLog.initialize(enabled: enabled);
    } else {
      ClientLog.setEnabled(enabled);
    }
    if (!mounted) return;
    _mutate(() {
      _diagnosticLoggingEnabled = enabled;
      _diagnosticLogPath = ClientLog.path;
    });
  }

  Future<void> _exportDiagnosticLog() async {
    try {
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final location = await getSaveLocation(
        suggestedName: 'intmusic-client-$timestamp.jsonl',
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(label: 'JSON Lines log', extensions: <String>['jsonl']),
        ],
      );
      if (location == null) return;
      await ClientLog.exportTo(location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_tr(context, 'Diagnostic log exported'))),
      );
    } catch (error, stackTrace) {
      ClientLog.error(
        'client.log.export_failed',
        error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_tr(context, 'Export failed')}: $error')),
      );
    }
  }

  Future<void> _saveCoreUrlPreference() async {
    try {
      CoreApiClient.retainOnly(_coreUrlController.text);
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(
        _prefsCoreUrlKey,
        _coreUrlController.text.trim(),
      );
    } catch (_) {
      // A failed preference write should not break playback control.
    }
  }

  _AppLanguage? _languageFromPreference(String? value) {
    return switch (value) {
      'zh' => _AppLanguage.zh,
      'en' => _AppLanguage.en,
      _ => null,
    };
  }

  _LibraryViewMode _viewModeFromPreference(
    String? value, {
    _LibraryViewMode fallback = _LibraryViewMode.grid,
  }) {
    return switch (value) {
      'list' => _LibraryViewMode.list,
      'grid' => _LibraryViewMode.grid,
      _ => fallback,
    };
  }

  void _setLibraryViewMode(
    String preferenceKey,
    _LibraryViewMode mode,
    void Function(_LibraryViewMode mode) apply,
  ) {
    _mutate(() => apply(mode));
    unawaited(_persistLibraryViewMode(preferenceKey, mode));
  }

  Future<void> _persistLibraryViewMode(
    String preferenceKey,
    _LibraryViewMode mode,
  ) async {
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(preferenceKey, mode.name);
    } catch (_) {
      // View preferences are non-critical and remain valid for this session.
    }
  }

  _ZoneRegionSort _zoneRegionSortFromPreference(String? value) {
    return switch (value) {
      'name' => _ZoneRegionSort.name,
      _ => _ZoneRegionSort.playingFirst,
    };
  }

  Future<void> _setPinCurrentClientRegion(bool value) async {
    _mutate(() => _pinCurrentClientRegion = value);
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setBool(_prefsPinCurrentClientRegionKey, value);
    } catch (_) {
      // Region ordering remains available for the current session.
    }
  }

  Future<void> _setZoneRegionSort(_ZoneRegionSort value) async {
    _mutate(() => _zoneRegionSort = value);
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_prefsRegionSortKey, value.name);
    } catch (_) {
      // Region ordering remains available for the current session.
    }
  }

  Future<void> _setLanguage(_AppLanguage language) async {
    _mutate(() => _language = language);
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_prefsLanguageKey, language.name);
    } catch (_) {
      // Language can still change for the current session.
    }
  }

  String _defaultClientAlias() => '${Platform.localHostname} Client';

  String _clientAlias() {
    final alias = _clientAliasController.text.trim();
    return alias.isEmpty ? _defaultClientAlias() : alias;
  }

  Future<void> _saveClientAlias() async {
    final alias = _clientAliasController.text.trim();
    _clientAliasController.text = alias.isEmpty ? _defaultClientAlias() : alias;
    try {
      final preferences = _preferences ?? await SharedPreferences.getInstance();
      _preferences = preferences;
      await preferences.setString(_prefsClientAliasKey, _clientAlias());
    } catch (_) {
      // The renderer can still advertise the alias for the current session.
    }
    await _sendRendererRegistration();
    await _refreshZonesSilently();
  }

  Future<void> _saveServerAlias() async {
    final alias = _serverAliasController.text.trim();
    final serverSettings = await _run<Map<String, dynamic>>(
      () async => _asMap(
        await _api.postJson('/settings/server', <String, dynamic>{
          'alias': alias,
        }),
      ),
    );
    if (!mounted || serverSettings == null) {
      return;
    }
    final status = await _run<Map<String, dynamic>>(
      () async => _asMap(await _api.getJson('/status')),
    );
    final zones = await _run<List<dynamic>>(
      () async => await _api.getJson('/zones') as List<dynamic>,
    );
    if (!mounted) {
      return;
    }
    _mutate(() {
      _serverSettings = serverSettings;
      _serverAliasController.text =
          serverSettings['alias']?.toString() ??
          status?['display_name']?.toString() ??
          'Core local';
      if (status != null) {
        _status = status;
      }
      if (zones != null) {
        _zones = zones;
        _keepSelectedZoneValid();
        _syncPlaybackFromSelectedZone();
      }
    });
  }
}
