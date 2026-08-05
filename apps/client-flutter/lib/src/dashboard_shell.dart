part of '../intmusic_client.dart';

extension _DashboardShell on _CoreDashboardState {
  Future<void> _handleBackNavigation() async {
    if (_canNavigateBack) {
      _navigateBack();
      return;
    }
    await _moveAppToBackground();
  }

  Future<void> _moveAppToBackground() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _IntMusicPlatform.instance.moveToBackground();
  }

  void _startPlaybackReveal() {
    if (!Platform.isAndroid || _currentRoute.kind == _AppRouteKind.playback) {
      return;
    }
    _playbackRevealController.stop();
  }

  void _updatePlaybackReveal(double delta) {
    if (!Platform.isAndroid || _currentRoute.kind == _AppRouteKind.playback) {
      return;
    }
    _playbackRevealController.value = (_playbackRevealController.value + delta)
        .clamp(0.0, 1.0);
  }

  void _endPlaybackReveal(double upwardVelocity) {
    if (!Platform.isAndroid || _currentRoute.kind == _AppRouteKind.playback) {
      return;
    }
    final shouldOpen =
        _playbackRevealController.value >= 0.36 || upwardVelocity >= 680;
    if (shouldOpen) {
      unawaited(
        _playbackRevealController.animateTo(1).then((_) {
          if (!mounted) {
            return;
          }
          _mutate(() => _navigateToInState(_AppRoute.destination(5)));
          _playbackRevealController.value = 0;
        }),
      );
      return;
    }
    unawaited(_playbackRevealController.animateBack(0));
  }

  Widget _buildShell(BoxConstraints constraints) {
    final viewport = _effectiveViewportSize(constraints);
    final effectiveWidth = viewport.width;
    final desktop = effectiveWidth >= _desktopShellWidth;
    final showPlaybackBar = _currentRoute.kind != _AppRouteKind.playback;
    final pageTitle = _currentRoute.title;
    final pageContent = _currentRoute.kind == _AppRouteKind.playback
        ? ValueListenableBuilder<int>(
            valueListenable: _playbackRevision,
            builder: (_, _, _) => _buildPlaybackPage(),
          )
        : _page();
    final page = _AnimatedPageHost(
      pageKey: _currentRoute.animationKey,
      direction: _pageTransitionDirection,
      child: pageContent,
    );
    final playbackBar = ValueListenableBuilder<int>(
      valueListenable: _playbackRevision,
      builder: (_, _, _) => _PlaybackBar(
        coreBaseUrl: _coreUrlController.text,
        state: _playback,
        trackDetail: _activeTrackDetail,
        targetLabel: _selectedZoneLabel,
        playbackMode: _playbackMode,
        volumeState: _activeZoneDualVolumeState(),
        onResume: _resumePlayback,
        onPause: _pausePlayback,
        onPrevious: _playPreviousTrack,
        onNext: _playNextTrack,
        onSeek: _seekPlayback,
        onVolumeChanged: (mode, value) =>
            unawaited(_setActiveZoneVolume(value, mode: mode)),
        onToggleMute: (mode) => unawaited(
          _setActiveZoneVolume(
            _activeZoneVolumeForMode(mode),
            muted: !_activeZoneMutedForMode(mode),
            mode: mode,
          ),
        ),
        onCycleMode: _cyclePlaybackMode,
        onShowModeMenu: _showPlaybackModeMenu,
        onShowQueue: _showQueueSheet,
        onShowDevices: _showDeviceSheet,
        onOpenPlayback: () => _navigateTo(_AppRoute.destination(5)),
        enableRevealGesture: Platform.isAndroid,
        onRevealStart: _startPlaybackReveal,
        onRevealUpdate: _updatePlaybackReveal,
        onRevealEnd: _endPlaybackReveal,
      ),
    );
    final body = Expanded(
      child: LayoutBuilder(
        builder: (context, bodyConstraints) {
          return Stack(
            children: [
              Column(
                children: [
                  Expanded(child: page),
                  if (showPlaybackBar) playbackBar,
                ],
              ),
              if (showPlaybackBar)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _playbackRevealController,
                    builder: (context, _) {
                      final progress = _playbackRevealController.value;
                      if (progress <= 0.001) {
                        return const SizedBox.shrink();
                      }
                      final curved = Curves.easeOutCubic.transform(progress);
                      final radius = 24.0 * (1 - curved);
                      return IgnorePointer(
                        ignoring: progress < 0.98,
                        child: Transform.translate(
                          offset: Offset(
                            0,
                            bodyConstraints.maxHeight * (1 - curved),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(radius),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: IntMusicTheme.of(context).canvas,
                              ),
                              child: _buildPlaybackPage(),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
    final content = Column(
      children: [
        _AppTopBar(
          title: pageTitle,
          desktop: desktop,
          canGoBack: _canNavigateBack,
          canGoForward: _canNavigateForward,
          onBack: _navigateBack,
          onForward: _navigateForward,
          searchController: _searchController,
          searchSuggestions: _searchSuggestions,
          onOpenMenu: _showNavigationSheet,
          onSearchChanged: _onSearchChanged,
          onSubmitSearch: (query) => unawaited(_submitSearch(query)),
          onSelectSuggestion: _selectSearchSuggestion,
          recentSearches: _recentSearches,
          onSelectRecentSearch: _selectRecentSearch,
          onClearSearch: _clearSearch,
        ),
        if (_error != null) _ErrorBanner(message: _error!),
        body,
      ],
    );
    final contentSurface = KeyedSubtree(
      key: const Key('app-content-surface'),
      child: Platform.isMacOS
          ? ColoredBox(
              color: IntMusicTheme.of(context).canvas.withValues(alpha: 0.96),
              child: content,
            )
          : content,
    );

    if (_enforceViewportLimits) {
      final sidebar = ValueListenableBuilder<int>(
        valueListenable: _playbackRevision,
        builder: (_, _, _) => ValueListenableBuilder<double>(
          valueListenable: _IntMusicPlatform.instance.titlebarSafeInset,
          builder: (context, titlebarSafeInset, child) => _AppSidebar(
            selectedIndex: _selectedDestinationIndex,
            status: _status,
            zones: _zones,
            loading: _loading,
            error: _error,
            playback: _playback,
            titlebarSafeInset: Platform.isMacOS ? titlebarSafeInset : 0,
            onSelected: _setSelectedIndex,
          ),
        ),
      );
      return _withMinimumViewport(
        constraints,
        _AnimatedSidebarShell(
          expanded: desktop,
          sidebar: sidebar,
          content: contentSurface,
        ),
      );
    }

    return _withMinimumViewport(constraints, contentSurface);
  }

  bool get _enforceViewportLimits =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Size _effectiveViewportSize(BoxConstraints constraints) {
    if (!_enforceViewportLimits) {
      return Size(constraints.maxWidth, constraints.maxHeight);
    }
    var width = max(constraints.maxWidth, _appMinWidth);
    var height = max(constraints.maxHeight, _appMinHeight);
    final ratio = width / height;
    if (ratio < _appMinAspectRatio) {
      width = height * _appMinAspectRatio;
    } else if (ratio > _appMaxAspectRatio) {
      height = width / _appMaxAspectRatio;
    }
    return Size(width, height);
  }

  Widget _withMinimumViewport(BoxConstraints constraints, Widget child) {
    if (!_enforceViewportLimits) {
      return child;
    }
    final viewport = _effectiveViewportSize(constraints);
    final width = viewport.width;
    final height = viewport.height;
    final constrained = SizedBox(width: width, height: height, child: child);
    final fitsWidth = constraints.maxWidth >= width;
    final fitsHeight = constraints.maxHeight >= height;
    if (fitsWidth && fitsHeight) {
      return child;
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(child: constrained),
    );
  }

  Widget _buildPlaybackPage() {
    return _PlaybackPage(
      coreBaseUrl: _coreUrlController.text,
      playback: _playback,
      trackDetail: _activeTrackDetail,
      activeZoneId: _activeZoneId(),
      playbackMode: _playbackMode,
      volumeState: _activeZoneDualVolumeState(),
      onResume: (_) => _resumePlayback(),
      onPause: (_) => _pausePlayback(),
      onPrevious: _playPreviousTrack,
      onNext: _playNextTrack,
      onSeek: _seekPlayback,
      onCycleMode: _cyclePlaybackMode,
      onShowModeMenu: _showPlaybackModeMenu,
      onShowQueue: _showQueueSheet,
      onShowDevices: _showDeviceSheet,
      onVolumeChanged: (mode, value) =>
          unawaited(_setActiveZoneVolume(value, mode: mode)),
      onToggleMute: (mode) => unawaited(
        _setActiveZoneVolume(
          _activeZoneVolumeForMode(mode),
          muted: !_activeZoneMutedForMode(mode),
          mode: mode,
        ),
      ),
      onToggleFavorite: _toggleFavorite,
      onOpenTrack: _openTrackDetail,
    );
  }

  Widget _page() {
    switch (_currentRoute.kind) {
      case _AppRouteKind.home:
        return _HomePage(
          coreBaseUrl: _coreUrlController.text,
          status: _status,
          playback: _playback,
          trackDetail: _activeTrackDetail,
          zones: _zones,
          stats: _playbackStats,
          history: _playbackHistory,
          onNavigate: _setSelectedIndex,
          onOpenTrack: _openTrackDetail,
          onPlayTrack: _playTrack,
        );
      case _AppRouteKind.albums:
        return _AlbumsPage(
          coreBaseUrl: _coreUrlController.text,
          albums: _albums,
          onOpenAlbum: _openAlbumDetail,
          viewMode: _albumViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsAlbumViewModeKey,
            mode,
            (mode) => _albumViewMode = mode,
          ),
        );
      case _AppRouteKind.artists:
        return _ArtistsPage(
          coreBaseUrl: _coreUrlController.text,
          artists: _artists,
          onOpenArtist: _openArtistDetail,
          viewMode: _artistViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsArtistViewModeKey,
            mode,
            (mode) => _artistViewMode = mode,
          ),
        );
      case _AppRouteKind.tracks:
        return _TracksPage(
          coreBaseUrl: _coreUrlController.text,
          tracks: _tracks,
          onOpenTrack: _openTrackDetail,
          onPlayTrack: _playTrack,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
          onDistributeTracks: _distributeTracks,
          viewMode: _trackViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsTrackViewModeKey,
            mode,
            (mode) => _trackViewMode = mode,
          ),
        );
      case _AppRouteKind.playlists:
        return _PlaylistsPage(
          playlists: _playlists,
          onOpenPlaylist: _openPlaylistDetail,
          onCreateManual: _createManualPlaylist,
          onCreateSmart: _createSmartPlaylist,
          onDeletePlaylist: _deletePlaylist,
          viewMode: _playlistViewMode,
          onViewModeChanged: (mode) => _setLibraryViewMode(
            _prefsPlaylistViewModeKey,
            mode,
            (mode) => _playlistViewMode = mode,
          ),
        );
      case _AppRouteKind.playback:
        return _buildPlaybackPage();
      case _AppRouteKind.history:
        return _HistoryPage(
          coreBaseUrl: _coreUrlController.text,
          stats: _playbackStats,
          events: _playbackHistory,
          onOpenTrack: _openTrackDetail,
          onPlayTrack: _playTrack,
        );
      case _AppRouteKind.libraryManagement:
        return _LibraryManagementPage(
          coreBaseUrl: _coreUrlController.text,
          tracks: _tracks,
          onOpenTrack: _openTrackDetail,
          onLibraryChanged: _refreshAfterLibraryManagementChange,
        );
      case _AppRouteKind.settings:
        return _SettingsPage(
          coreUrlController: _coreUrlController,
          serverAliasController: _serverAliasController,
          clientAliasController: _clientAliasController,
          loading: _loading,
          status: _status,
          rendererStatus: _rendererStatus,
          settings: _favoriteSettings,
          metadataSettings: _metadataSettings,
          libraryRoots: _libraryRoots,
          clientLibraryRoots: _clientLibraryRoots,
          clientLibraryStatuses: _clientLibraryStatuses,
          clientLibrarySyncingRootIds: _clientLibrarySyncingRootIds,
          distributionJobs: _distributionJobs,
          transcodingStatus: _transcodingStatus,
          clientId: _clientId,
          diagnostics: _diagnostics,
          diagnosticLoggingEnabled: _diagnosticLoggingEnabled,
          diagnosticLogPath: _diagnosticLogPath,
          language: _language,
          pinCurrentClientRegion: _pinCurrentClientRegion,
          zoneRegionSort: _zoneRegionSort,
          libraryRootController: _libraryRootController,
          onConnect: _refreshAll,
          onDiscover: _discoverAndRefresh,
          onScan: _startScan,
          onAddLibraryRoot: () => unawaited(_addLibraryRoot()),
          onRemoveLibraryRoot: (id) => unawaited(_removeLibraryRoot(id)),
          onAddClientLibraryRoot: () => unawaited(_addClientLibraryRoot()),
          onSyncClientLibraryRoot: (id) =>
              unawaited(_syncClientLibraryRoot(id)),
          onSyncAllClientLibraryRoots: () =>
              unawaited(_syncAllClientLibraryRoots()),
          onRemoveClientLibraryRoot: (id) =>
              unawaited(_removeClientLibraryRoot(id)),
          onRefreshDistributions: () => unawaited(_refreshDistributionJobs()),
          onCancelDistribution: (id) => unawaited(_cancelDistributionJob(id)),
          onSaveServerAlias: () => unawaited(_saveServerAlias()),
          onSaveClientAlias: () => unawaited(_saveClientAlias()),
          onLanguageChanged: (language) => unawaited(_setLanguage(language)),
          onPinCurrentClientRegionChanged: (value) =>
              unawaited(_setPinCurrentClientRegion(value)),
          onZoneRegionSortChanged: (value) =>
              unawaited(_setZoneRegionSort(value)),
          onDiagnosticLoggingChanged: (value) =>
              unawaited(_setDiagnosticLogging(value)),
          onExportDiagnosticLog: () => unawaited(_exportDiagnosticLog()),
          onUpdateFavoriteSettings: _updateFavoriteSettings,
          onUpdateMetadataSettings: _updateMetadataSettings,
        );
      case _AppRouteKind.search:
        final query = _currentRoute.query ?? _searchQuery;
        return _SearchPage(
          coreBaseUrl: _coreUrlController.text,
          query: query,
          search: _searchResultCache[query],
          scope: _searchScopeByQuery[query] ?? _SearchScope.all,
          sort: _searchSortByQuery[query] ?? _SearchSort.relevance,
          onScopeChanged: (scope) =>
              _mutate(() => _searchScopeByQuery[query] = scope),
          onSortChanged: (sort) =>
              _mutate(() => _searchSortByQuery[query] = sort),
          onOpenAlbum: _openAlbumDetail,
          onOpenArtist: _openArtistDetail,
          onOpenTrack: _openTrackDetail,
          onOpenPlaylist: _openPlaylistDetail,
          onPlayTrack: _playTrack,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.track:
        final trackId = _currentRoute.entityId;
        return _TrackInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: _trackDetailCache[trackId],
          onClose: _closeTrackDetail,
          onPlayTrack: _playTrack,
          onOpenAlbum: _openAlbumDetail,
          onOpenArtist: _openArtistByName,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
          onEdit: trackId == null ? () async {} : () => _editTrack(trackId),
          onManageVersions: trackId == null
              ? () async {}
              : () => _manageTrackVersions(trackId),
        );
      case _AppRouteKind.album:
        final detail =
            _albumDetailCache[_currentRoute.entityId] ??
            const <String, dynamic>{};
        return _AlbumInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: detail,
          onClose: _closeAlbumDetail,
          onPlayTrack: (trackId) => _playTrackFromCollection(
            trackId,
            (detail['tracks'] as List?) ?? const [],
          ),
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.artist:
        final artistId = _currentRoute.entityId;
        final detail =
            _artistDetailCache[artistId] ?? const <String, dynamic>{};
        return _ArtistInfoPage(
          coreBaseUrl: _coreUrlController.text,
          detail: detail,
          onClose: _closeArtistDetail,
          onEdit: artistId == null
              ? () async {}
              : () => _editArtist(artistId, detail),
          onOpenAlbum: _openAlbumDetail,
          onPlayTrack: _playTrack,
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onAddToPlaylist: _addTrackToPlaylist,
        );
      case _AppRouteKind.playlist:
        final playlistId = _currentRoute.entityId;
        final detail =
            _playlistDetailCache[playlistId] ?? const <String, dynamic>{};
        return _PlaylistDetailPage(
          key: ValueKey('playlist-detail-$playlistId'),
          coreBaseUrl: _coreUrlController.text,
          detail: detail,
          initialScrollOffset: playlistId == null
              ? 0
              : _playlistScrollOffsets[playlistId] ?? 0,
          onScrollOffsetChanged: (offset) {
            if (playlistId != null) _playlistScrollOffsets[playlistId] = offset;
          },
          onPlayTrack: (trackId) => _playTrackFromCollection(
            trackId,
            (detail['tracks'] as List?) ?? const [],
          ),
          onOpenTrack: _openTrackDetail,
          onToggleFavorite: _toggleFavorite,
          onEditSmart: playlistId == null
              ? () async {}
              : () => _editSmartPlaylist(playlistId, detail),
          onRemoveTrack: playlistId == null
              ? (_) async {}
              : (trackId) => _removeTrackFromPlaylist(
                  playlistId: playlistId,
                  trackId: trackId,
                ),
        );
    }
  }
}
