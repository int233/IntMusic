part of '../main.dart';

class _AlbumsPage extends StatefulWidget {
  const _AlbumsPage({
    required this.coreBaseUrl,
    required this.albums,
    required this.onOpenAlbum,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  final String coreBaseUrl;
  final List<dynamic> albums;
  final Future<void> Function(int) onOpenAlbum;
  final _LibraryViewMode viewMode;
  final ValueChanged<_LibraryViewMode> onViewModeChanged;

  @override
  State<_AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<_AlbumsPage> {
  String _query = '';
  String _sort = 'title';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final albums = widget.albums
        .where((item) {
          if (query.isEmpty) {
            return true;
          }
          final album = (item as Map).cast<String, dynamic>();
          return '${album['title'] ?? ''}\u0000'
                  '${album['album_artist_display'] ?? ''}'
              .toLowerCase()
              .contains(query);
        })
        .toList(growable: false);
    albums.sort((left, right) {
      final a = (left as Map).cast<String, dynamic>();
      final b = (right as Map).cast<String, dynamic>();
      return switch (_sort) {
        'artist' => _compareLibraryText(
          a['album_artist_display'],
          b['album_artist_display'],
          secondaryA: a['title'],
          secondaryB: b['title'],
        ),
        'year' => _compareLibraryNumber(
          b['year'],
          a['year'],
          secondaryA: a['title'],
          secondaryB: b['title'],
        ),
        'tracks' => _compareLibraryNumber(
          b['track_count'],
          a['track_count'],
          secondaryA: a['title'],
          secondaryB: b['title'],
        ),
        _ => _compareLibraryText(a['title'], b['title']),
      };
    });
    return _PageFrame(
      title: 'Albums',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
            child: _LibraryToolbar(
              countLabel: query.isEmpty
                  ? '${albums.length} albums'
                  : '${albums.length} of ${widget.albums.length} albums',
              searchHint: _tr(context, 'Filter albums'),
              onQueryChanged: (value) => setState(() => _query = value),
              sortValue: _sort,
              sortOptions: {
                'title': _tr(context, 'Title'),
                'artist': _tr(context, 'Artist'),
                'year': _tr(context, 'Newest year'),
                'tracks': _tr(context, 'Most tracks'),
              },
              onSortChanged: (value) => setState(() => _sort = value),
              viewMode: widget.viewMode,
              onViewModeChanged: widget.onViewModeChanged,
            ),
          ),
          Expanded(
            child: albums.isEmpty
                ? const Center(child: Text('No albums'))
                : widget.viewMode == _LibraryViewMode.grid
                ? GridView.builder(
                    key: const PageStorageKey('albums-grid'),
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 214,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.72,
                        ),
                    itemCount: albums.length,
                    itemBuilder: (context, index) {
                      final album = (albums[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(album['id']);
                      return _AlbumCard(
                        coreBaseUrl: widget.coreBaseUrl,
                        album: album,
                        onTap: id == null
                            ? null
                            : () => unawaited(widget.onOpenAlbum(id)),
                      );
                    },
                  )
                : ListView.separated(
                    key: const PageStorageKey('albums-list'),
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                    itemCount: albums.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final album = (albums[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(album['id']);
                      final title = album['title']?.toString() ?? 'Untitled';
                      final artist =
                          album['album_artist_display']?.toString() ??
                          'Unknown Artist';
                      return _SimpleListRow(
                        leading: _ArtworkTile(
                          title: title,
                          subtitle: artist,
                          size: 48,
                          icon: Icons.album_outlined,
                          imageUrl: _albumArtworkUrl(widget.coreBaseUrl, id),
                        ),
                        title: title,
                        subtitle: _joinParts([
                          artist,
                          album['year'],
                          '${album['track_count'] ?? 0} tracks',
                        ]),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: id == null
                            ? null
                            : () => unawaited(widget.onOpenAlbum(id)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.coreBaseUrl,
    required this.album,
    required this.onTap,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> album;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final title = album['title']?.toString() ?? 'Untitled';
    final artist =
        album['album_artist_display']?.toString() ?? 'Unknown Artist';
    final subtitle = _joinParts([
      artist,
      album['year'],
      '${album['track_count'] ?? 0} tracks',
    ]);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  return _ArtworkTile(
                    title: title,
                    subtitle: artist,
                    size: constraints.maxWidth,
                    icon: Icons.album_outlined,
                    imageUrl: _albumArtworkUrl(coreBaseUrl, album['id']),
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: IntMusicTheme.of(context).textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistsPage extends StatefulWidget {
  const _ArtistsPage({
    required this.coreBaseUrl,
    required this.artists,
    required this.onOpenArtist,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  final String coreBaseUrl;
  final List<dynamic> artists;
  final Future<void> Function(int) onOpenArtist;
  final _LibraryViewMode viewMode;
  final ValueChanged<_LibraryViewMode> onViewModeChanged;

  @override
  State<_ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<_ArtistsPage> {
  String _query = '';
  String _sort = 'name';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final artists = widget.artists
        .where((item) {
          if (query.isEmpty) {
            return true;
          }
          final artist = (item as Map).cast<String, dynamic>();
          return (artist['name']?.toString() ?? '').toLowerCase().contains(
            query,
          );
        })
        .toList(growable: false);
    artists.sort((left, right) {
      final a = (left as Map).cast<String, dynamic>();
      final b = (right as Map).cast<String, dynamic>();
      return switch (_sort) {
        'albums' => _compareLibraryNumber(
          b['album_count'],
          a['album_count'],
          secondaryA: a['name'],
          secondaryB: b['name'],
        ),
        'tracks' => _compareLibraryNumber(
          b['track_count'],
          a['track_count'],
          secondaryA: a['name'],
          secondaryB: b['name'],
        ),
        _ => _compareLibraryText(a['name'], b['name']),
      };
    });
    return _PageFrame(
      title: 'Artists',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
            child: _LibraryToolbar(
              countLabel: query.isEmpty
                  ? '${artists.length} artists'
                  : '${artists.length} of ${widget.artists.length} artists',
              searchHint: _tr(context, 'Filter artists'),
              onQueryChanged: (value) => setState(() => _query = value),
              sortValue: _sort,
              sortOptions: {
                'name': _tr(context, 'Name'),
                'albums': _tr(context, 'Most albums'),
                'tracks': _tr(context, 'Most tracks'),
              },
              onSortChanged: (value) => setState(() => _sort = value),
              viewMode: widget.viewMode,
              onViewModeChanged: widget.onViewModeChanged,
            ),
          ),
          Expanded(
            child: artists.isEmpty
                ? const Center(child: Text('No artists'))
                : widget.viewMode == _LibraryViewMode.grid
                ? GridView.builder(
                    key: const PageStorageKey('artists-grid'),
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.86,
                        ),
                    itemCount: artists.length,
                    itemBuilder: (context, index) {
                      final artist = (artists[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(artist['id']);
                      final name =
                          artist['name']?.toString() ?? 'Unknown Artist';
                      final subtitle =
                          '${artist['album_count'] ?? 0} albums · '
                          '${artist['track_count'] ?? 0} tracks';
                      return Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: id == null
                              ? null
                              : () => unawaited(widget.onOpenArtist(id)),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) =>
                                        _ArtworkTile(
                                          title: name,
                                          subtitle: subtitle,
                                          size: constraints.maxWidth,
                                          icon: Icons.person_outline,
                                          imageUrl: _artistArtworkUrl(
                                            widget.coreBaseUrl,
                                            id,
                                            'artist_card',
                                            revision:
                                                artist['artwork_revision'],
                                            width: 640,
                                            height: 640,
                                          ),
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: IntMusicTheme.of(
                                          context,
                                        ).textSecondary,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    key: const PageStorageKey('artists-list'),
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                    itemCount: artists.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final artist = (artists[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(artist['id']);
                      final name =
                          artist['name']?.toString() ?? 'Unknown Artist';
                      return _SimpleListRow(
                        leading: _ArtworkTile(
                          title: name,
                          subtitle: 'artist',
                          size: 48,
                          icon: Icons.person_outline,
                          imageUrl: _artistArtworkUrl(
                            widget.coreBaseUrl,
                            id,
                            'search_list',
                            revision: artist['artwork_revision'],
                            width: 128,
                            height: 128,
                          ),
                        ),
                        title: name,
                        subtitle:
                            '${artist['album_count'] ?? 0} albums · '
                            '${artist['track_count'] ?? 0} tracks',
                        trailing: const Icon(Icons.chevron_right),
                        onTap: id == null
                            ? null
                            : () => unawaited(widget.onOpenArtist(id)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _TracksPage extends StatefulWidget {
  const _TracksPage({
    required this.coreBaseUrl,
    required this.tracks,
    required this.onOpenTrack,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
    required this.onDistributeTracks,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  final String coreBaseUrl;
  final List<dynamic> tracks;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;
  final Future<void> Function(List<int>) onDistributeTracks;
  final _LibraryViewMode viewMode;
  final ValueChanged<_LibraryViewMode> onViewModeChanged;

  @override
  State<_TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<_TracksPage> {
  Timer? _scrollIdleTimer;
  bool _deferArtwork = false;
  bool _selecting = false;
  final Set<int> _selectedTrackIds = <int>{};
  String _query = '';
  String _sort = 'title';

  @override
  void dispose() {
    _scrollIdleTimer?.cancel();
    super.dispose();
  }

  void _setDeferArtwork(bool value) {
    if (_deferArtwork == value || !mounted) {
      return;
    }
    setState(() => _deferArtwork = value);
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _setDeferArtwork(true);
      _scrollIdleTimer?.cancel();
      _scrollIdleTimer = Timer(
        const Duration(milliseconds: 180),
        () => _setDeferArtwork(false),
      );
    } else if (notification is ScrollEndNotification) {
      _scrollIdleTimer?.cancel();
      _scrollIdleTimer = Timer(
        const Duration(milliseconds: 120),
        () => _setDeferArtwork(false),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final tracks = widget.tracks
        .where((item) {
          if (query.isEmpty) {
            return true;
          }
          final track = (item as Map).cast<String, dynamic>();
          return '${track['title'] ?? ''}\u0000'
                  '${track['artist_display'] ?? ''}\u0000'
                  '${track['album_title'] ?? ''}'
              .toLowerCase()
              .contains(query);
        })
        .toList(growable: false);
    tracks.sort((left, right) {
      final a = (left as Map).cast<String, dynamic>();
      final b = (right as Map).cast<String, dynamic>();
      return switch (_sort) {
        'artist' => _compareLibraryText(
          a['artist_display'],
          b['artist_display'],
          secondaryA: a['title'],
          secondaryB: b['title'],
        ),
        'album' => _compareLibraryText(
          a['album_title'],
          b['album_title'],
          secondaryA: a['disc_number'],
          secondaryB: b['disc_number'],
        ),
        'duration' => _compareLibraryNumber(
          b['duration_ms'],
          a['duration_ms'],
          secondaryA: a['title'],
          secondaryB: b['title'],
        ),
        _ => _compareLibraryText(a['title'], b['title']),
      };
    });
    final visibleTrackIds = tracks
        .map((item) => _intValue((item as Map)['id']))
        .whereType<int>()
        .toSet();
    final allVisibleSelected =
        visibleTrackIds.isNotEmpty &&
        visibleTrackIds.every(_selectedTrackIds.contains);
    return _PageFrame(
      title: 'Tracks',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 8),
            child: _LibraryToolbar(
              countLabel: query.isEmpty
                  ? '${tracks.length} tracks'
                  : '${tracks.length} of ${widget.tracks.length} tracks',
              searchHint: _tr(context, 'Filter tracks'),
              onQueryChanged: (value) => setState(() => _query = value),
              sortValue: _sort,
              sortOptions: {
                'title': _tr(context, 'Title'),
                'artist': _tr(context, 'Artist'),
                'album': _tr(context, 'Album'),
                'duration': _tr(context, 'Longest'),
              },
              onSortChanged: (value) => setState(() => _sort = value),
              viewMode: widget.viewMode,
              onViewModeChanged: widget.onViewModeChanged,
              action: OutlinedButton.icon(
                onPressed: () => setState(() {
                  _selecting = !_selecting;
                  if (!_selecting) {
                    _selectedTrackIds.clear();
                  }
                }),
                icon: Icon(
                  _selecting ? Icons.close : Icons.checklist_rounded,
                  size: 18,
                ),
                label: Text(_tr(context, _selecting ? 'Cancel' : 'Select')),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: !_selecting
                ? const SizedBox.shrink()
                : Padding(
                    key: const ValueKey('track-selection-bar'),
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                    child: _TrackSelectionBar(
                      selectedCount: _selectedTrackIds.length,
                      allVisibleSelected: allVisibleSelected,
                      onToggleAll: () => setState(() {
                        if (allVisibleSelected) {
                          _selectedTrackIds.removeAll(visibleTrackIds);
                        } else {
                          _selectedTrackIds.addAll(visibleTrackIds);
                        }
                      }),
                      onClear: _selectedTrackIds.isEmpty
                          ? null
                          : () => setState(_selectedTrackIds.clear),
                      onDistribute: _selectedTrackIds.isEmpty
                          ? null
                          : () async {
                              await widget.onDistributeTracks(
                                _selectedTrackIds.toList(growable: false)
                                  ..sort(),
                              );
                              if (mounted) {
                                setState(() {
                                  _selecting = false;
                                  _selectedTrackIds.clear();
                                });
                              }
                            },
                    ),
                  ),
          ),
          Expanded(
            child: tracks.isEmpty
                ? const Center(child: Text('No tracks'))
                : widget.viewMode == _LibraryViewMode.grid
                ? NotificationListener<ScrollNotification>(
                    onNotification: _handleScrollNotification,
                    child: GridView.builder(
                      key: const PageStorageKey('tracks-grid'),
                      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 230,
                            mainAxisSpacing: 18,
                            crossAxisSpacing: 18,
                            childAspectRatio: 0.72,
                          ),
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final track = (tracks[index] as Map)
                            .cast<String, dynamic>();
                        final id = _intValue(track['id']);
                        final selected =
                            id != null && _selectedTrackIds.contains(id);
                        return _TrackCard(
                          coreBaseUrl: widget.coreBaseUrl,
                          track: track,
                          deferArtwork: _deferArtwork,
                          selectionMode: _selecting,
                          selected: selected,
                          onSelectionChanged: id == null
                              ? null
                              : () => setState(() {
                                  if (selected) {
                                    _selectedTrackIds.remove(id);
                                  } else {
                                    _selectedTrackIds.add(id);
                                  }
                                }),
                          onOpen: id == null || _selecting
                              ? null
                              : () => unawaited(widget.onOpenTrack(id)),
                          onPlay: id == null || _selecting
                              ? null
                              : () => unawaited(widget.onPlayTrack(id)),
                          onAddToPlaylist: id == null || _selecting
                              ? null
                              : () => unawaited(widget.onAddToPlaylist(id)),
                          onToggleFavorite: widget.onToggleFavorite,
                        );
                      },
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final showAlbum = constraints.maxWidth >= 760;
                      return Column(
                        children: [
                          _TrackTableHeader(showAlbum: showAlbum),
                          Expanded(
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _handleScrollNotification,
                              child: ListView.builder(
                                key: const PageStorageKey('tracks-list'),
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  0,
                                  14,
                                  20,
                                ),
                                scrollCacheExtent:
                                    const ScrollCacheExtent.pixels(220),
                                itemExtent: 67,
                                itemCount: tracks.length,
                                itemBuilder: (context, index) {
                                  final track = (tracks[index] as Map)
                                      .cast<String, dynamic>();
                                  final id = _intValue(track['id']);
                                  final selected =
                                      id != null &&
                                      _selectedTrackIds.contains(id);
                                  return DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: IntMusicTheme.of(
                                            context,
                                          ).stroke,
                                        ),
                                      ),
                                    ),
                                    child: _TrackTableRow(
                                      coreBaseUrl: widget.coreBaseUrl,
                                      track: track,
                                      showAlbum: showAlbum,
                                      deferArtwork: _deferArtwork,
                                      selectionMode: _selecting,
                                      selected: selected,
                                      onSelectionChanged: id == null
                                          ? null
                                          : () => setState(() {
                                              if (selected) {
                                                _selectedTrackIds.remove(id);
                                              } else {
                                                _selectedTrackIds.add(id);
                                              }
                                            }),
                                      onTap: id == null || _selecting
                                          ? null
                                          : () => unawaited(
                                              widget.onOpenTrack(id),
                                            ),
                                      onPlay: id == null || _selecting
                                          ? null
                                          : () => unawaited(
                                              widget.onPlayTrack(id),
                                            ),
                                      onAddToPlaylist: id == null || _selecting
                                          ? null
                                          : () => unawaited(
                                              widget.onAddToPlaylist(id),
                                            ),
                                      onToggleFavorite: widget.onToggleFavorite,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _TrackSelectionBar extends StatelessWidget {
  const _TrackSelectionBar({
    required this.selectedCount,
    required this.allVisibleSelected,
    required this.onToggleAll,
    required this.onClear,
    required this.onDistribute,
  });

  final int selectedCount;
  final bool allVisibleSelected;
  final VoidCallback onToggleAll;
  final VoidCallback? onClear;
  final VoidCallback? onDistribute;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.accent.withValues(alpha: 0.08),
        border: Border.all(color: tokens.accent.withValues(alpha: 0.24)),
        borderRadius: BorderRadius.circular(tokens.radiusSmall),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: tokens.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$selectedCount ${_tr(context, 'selected')}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            TextButton(
              onPressed: onToggleAll,
              child: Text(
                _tr(
                  context,
                  allVisibleSelected ? 'Deselect visible' : 'Select visible',
                ),
              ),
            ),
            TextButton(onPressed: onClear, child: Text(_tr(context, 'Clear'))),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: onDistribute,
              icon: const Icon(Icons.send_to_mobile_outlined, size: 18),
              label: Text(_tr(context, 'Distribute to device')),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.coreBaseUrl,
    required this.track,
    required this.deferArtwork,
    required this.onToggleFavorite,
    required this.onOpen,
    required this.onPlay,
    required this.onAddToPlaylist,
    required this.selectionMode,
    required this.selected,
    required this.onSelectionChanged,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final bool deferArtwork;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final VoidCallback? onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onAddToPlaylist;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final title = track['title']?.toString() ?? 'Untitled';
    final artist = track['artist_display']?.toString() ?? 'Unknown Artist';
    return Material(
      color: selected
          ? IntMusicTheme.of(context).accent.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: selectionMode ? onSelectionChanged : onOpen,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = min(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Align(
                      alignment: Alignment.topCenter,
                      child: _ArtworkTile(
                        title: title,
                        subtitle: artist,
                        size: size,
                        icon: Icons.music_note_outlined,
                        imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
                        deferImage: deferArtwork,
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 9),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(
                _joinParts([artist, track['album_title']]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: IntMusicTheme.of(context).textSecondary,
                ),
              ),
              Row(
                children: [
                  Text(
                    _formatDuration(track['duration_ms']),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                  const Spacer(),
                  if (selectionMode)
                    Checkbox(
                      value: selected,
                      onChanged: onSelectionChanged == null
                          ? null
                          : (_) => onSelectionChanged!(),
                    )
                  else
                    _TrackActions(
                      track: track,
                      compact: true,
                      onToggleFavorite: onToggleFavorite,
                      onAddToPlaylist: onAddToPlaylist,
                      onPlay: onPlay,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTableHeader extends StatelessWidget {
  const _TrackTableHeader({required this.showAlbum});

  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: IntMusicTheme.of(context).textSecondary,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 6),
      child: Row(
        children: [
          SizedBox(width: 46, child: Text('#', style: style)),
          Expanded(flex: 5, child: Text('Title', style: style)),
          if (showAlbum) Expanded(flex: 3, child: Text('Album', style: style)),
          SizedBox(
            width: 72,
            child: Text('Time', textAlign: TextAlign.right, style: style),
          ),
          const SizedBox(width: 150),
        ],
      ),
    );
  }
}

class _TrackTableRow extends StatelessWidget {
  const _TrackTableRow({
    required this.coreBaseUrl,
    required this.track,
    required this.showAlbum,
    required this.deferArtwork,
    required this.onToggleFavorite,
    required this.onTap,
    required this.onPlay,
    required this.onAddToPlaylist,
    required this.selectionMode,
    required this.selected,
    required this.onSelectionChanged,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final bool showAlbum;
  final bool deferArtwork;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onAddToPlaylist;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final title = track['title']?.toString() ?? 'Untitled';
    final artist = track['artist_display']?.toString() ?? 'Unknown Artist';
    final favorite = track['is_favorite'] == true;

    return Material(
      color: selected
          ? IntMusicTheme.of(context).accent.withValues(alpha: 0.10)
          : favorite
          ? appPrimary.withValues(alpha: 0.06)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: selectionMode ? onSelectionChanged : onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 66,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _ArtworkTile(
                  title: title,
                  subtitle: artist,
                  size: 46,
                  icon: Icons.music_note_outlined,
                  imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
                  deferImage: deferArtwork,
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _joinParts([artist, _ratingLabel(track)]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: IntMusicTheme.of(context).textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showAlbum) ...[
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 3,
                    child: Text(
                      track['album_title']?.toString() ?? '-',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  ),
                ],
                SizedBox(
                  width: 72,
                  child: Text(
                    _formatDuration(track['duration_ms']),
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                ),
                if (selectionMode)
                  SizedBox(
                    width: 150,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Checkbox(
                        value: selected,
                        onChanged: onSelectionChanged == null
                            ? null
                            : (_) => onSelectionChanged!(),
                      ),
                    ),
                  )
                else
                  _TrackActions(
                    track: track,
                    compact: true,
                    onToggleFavorite: onToggleFavorite,
                    onAddToPlaylist: onAddToPlaylist,
                    onPlay: onPlay,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackActions extends StatefulWidget {
  const _TrackActions({
    required this.track,
    required this.onToggleFavorite,
    this.onAddToPlaylist,
    this.onPlay,
    this.compact = false,
  });

  final Map<String, dynamic> track;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onPlay;
  final bool compact;

  @override
  State<_TrackActions> createState() => _TrackActionsState();
}

class _TrackActionsState extends State<_TrackActions> {
  bool? _favoriteOverride;

  @override
  void didUpdateWidget(covariant _TrackActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_intValue(oldWidget.track['id']) != _intValue(widget.track['id']) ||
        oldWidget.track['is_favorite'] != widget.track['is_favorite']) {
      _favoriteOverride = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final favorite = _favoriteOverride ?? widget.track['is_favorite'] == true;
    final trackId = _intValue(widget.track['id']);
    final queueActions = _TrackActionScope.maybeOf(context);
    final hasMoreActions =
        widget.onAddToPlaylist != null ||
        (trackId != null && queueActions != null);
    final actions = <Widget>[
      _AppTooltip(
        message: favorite ? 'Unfavorite' : 'Favorite',
        child: IconButton(
          onPressed: () async {
            setState(() => _favoriteOverride = !favorite);
            await widget.onToggleFavorite(widget.track);
          },
          icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
        ),
      ),
      if (hasMoreActions)
        PopupMenuButton<_TrackMoreAction>(
          tooltip: _tr(context, 'More'),
          icon: const Icon(Icons.more_horiz),
          onSelected: (action) {
            switch (action) {
              case _TrackMoreAction.playNext:
                unawaited(queueActions!.onPlayNext(trackId!));
              case _TrackMoreAction.addToQueue:
                unawaited(queueActions!.onAddToQueue(trackId!));
              case _TrackMoreAction.addToPlaylist:
                widget.onAddToPlaylist?.call();
              case _TrackMoreAction.distribute:
                unawaited(queueActions!.onDistributeCollection([trackId!]));
            }
          },
          itemBuilder: (context) => [
            if (trackId != null && queueActions != null)
              PopupMenuItem(
                value: _TrackMoreAction.playNext,
                child: ListTile(
                  leading: const Icon(Icons.playlist_play),
                  title: Text(_tr(context, 'Play next')),
                ),
              ),
            if (trackId != null && queueActions != null)
              PopupMenuItem(
                value: _TrackMoreAction.addToQueue,
                child: ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(_tr(context, 'Add to queue')),
                ),
              ),
            if (widget.onAddToPlaylist != null)
              PopupMenuItem(
                value: _TrackMoreAction.addToPlaylist,
                child: ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: Text(_tr(context, 'Add to playlist')),
                ),
              ),
            if (trackId != null && queueActions != null)
              PopupMenuItem(
                value: _TrackMoreAction.distribute,
                child: ListTile(
                  leading: const Icon(Icons.send_to_mobile_outlined),
                  title: Text(_tr(context, 'Distribute to device')),
                ),
              ),
          ],
        ),
      if (widget.onPlay != null)
        _AppTooltip(
          message: 'Play',
          child: IconButton(
            onPressed: widget.onPlay,
            icon: const Icon(Icons.play_arrow),
          ),
        ),
    ];
    final width = actions.length * (widget.compact ? 48.0 : 50.0);
    return SizedBox(
      width: width,
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
    );
  }
}

enum _TrackMoreAction { playNext, addToQueue, addToPlaylist, distribute }

int _compareLibraryText(
  Object? a,
  Object? b, {
  Object? secondaryA,
  Object? secondaryB,
}) {
  final primary = (a?.toString() ?? '').toLowerCase().compareTo(
    (b?.toString() ?? '').toLowerCase(),
  );
  if (primary != 0) {
    return primary;
  }
  return (secondaryA?.toString() ?? '').toLowerCase().compareTo(
    (secondaryB?.toString() ?? '').toLowerCase(),
  );
}

int _compareLibraryNumber(
  Object? a,
  Object? b, {
  Object? secondaryA,
  Object? secondaryB,
}) {
  final primary = (_intValue(a) ?? 0).compareTo(_intValue(b) ?? 0);
  if (primary != 0) {
    return primary;
  }
  return _compareLibraryText(secondaryA, secondaryB);
}
