part of '../intmusic_client.dart';

class _SearchSuggestion {
  const _SearchSuggestion({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final _ResultKind kind;
  final int id;
  final String title;
  final String subtitle;
  final IconData icon;
}

class _SearchPage extends StatelessWidget {
  const _SearchPage({
    required this.coreBaseUrl,
    required this.query,
    required this.search,
    required this.scope,
    required this.sort,
    required this.onScopeChanged,
    required this.onSortChanged,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenTrack,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String coreBaseUrl;
  final String query;
  final Map<String, dynamic>? search;
  final _SearchScope scope;
  final _SearchSort sort;
  final ValueChanged<_SearchScope> onScopeChanged;
  final ValueChanged<_SearchSort> onSortChanged;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(int) onOpenArtist;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onOpenPlaylist;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final tracks = (search?['tracks'] as List?) ?? const [];
    final albums = (search?['albums'] as List?) ?? const [];
    final artists = (search?['artists'] as List?) ?? const [];
    final playlists = (search?['playlists'] as List?) ?? const [];

    return _PageFrame(
      title: 'Search results',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
        children: [
          Row(
            children: [
              const Icon(Icons.search),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${_tr(context, 'Search results')}: $query',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_tr(context, 'Filter')),
              SegmentedButton<_SearchScope>(
                showSelectedIcon: false,
                segments: [
                  for (final value in _SearchScope.values)
                    ButtonSegment<_SearchScope>(
                      value: value,
                      label: Text(_searchScopeLabel(context, value)),
                    ),
                ],
                selected: {scope},
                onSelectionChanged: (value) => onScopeChanged(value.first),
              ),
              Text(_tr(context, 'Sort')),
              DropdownButton<_SearchSort>(
                value: sort,
                items: [
                  for (final value in _SearchSort.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_searchSortLabel(context, value)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    onSortChanged(value);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (scope == _SearchScope.all || scope == _SearchScope.tracks)
            _ResultGroup(
              coreBaseUrl: coreBaseUrl,
              title: 'Tracks',
              icon: Icons.music_note_outlined,
              items: _sortedTracks(tracks, sort),
              itemKind: _ResultKind.track,
              onOpenAlbum: onOpenAlbum,
              onOpenArtist: onOpenArtist,
              onOpenTrack: onOpenTrack,
              onOpenPlaylist: onOpenPlaylist,
              onPlayTrack: onPlayTrack,
              onToggleFavorite: onToggleFavorite,
              onAddToPlaylist: onAddToPlaylist,
            ),
          if (scope == _SearchScope.all || scope == _SearchScope.albums)
            _ResultGroup(
              coreBaseUrl: coreBaseUrl,
              title: 'Albums',
              icon: Icons.album_outlined,
              items: _sortedAlbums(albums, sort),
              itemKind: _ResultKind.album,
              onOpenAlbum: onOpenAlbum,
              onOpenArtist: onOpenArtist,
              onOpenTrack: onOpenTrack,
              onOpenPlaylist: onOpenPlaylist,
              onPlayTrack: onPlayTrack,
              onToggleFavorite: onToggleFavorite,
              onAddToPlaylist: onAddToPlaylist,
            ),
          if (scope == _SearchScope.all || scope == _SearchScope.artists)
            _ResultGroup(
              coreBaseUrl: coreBaseUrl,
              title: 'Artists',
              icon: Icons.person_outline,
              items: _sortedArtists(artists, sort),
              itemKind: _ResultKind.artist,
              onOpenAlbum: onOpenAlbum,
              onOpenArtist: onOpenArtist,
              onOpenTrack: onOpenTrack,
              onOpenPlaylist: onOpenPlaylist,
              onPlayTrack: onPlayTrack,
              onToggleFavorite: onToggleFavorite,
              onAddToPlaylist: onAddToPlaylist,
            ),
          if (scope == _SearchScope.all || scope == _SearchScope.playlists)
            _ResultGroup(
              coreBaseUrl: coreBaseUrl,
              title: 'Playlists',
              icon: Icons.queue_music_outlined,
              items: _sortedPlaylists(playlists, sort),
              itemKind: _ResultKind.playlist,
              onOpenAlbum: onOpenAlbum,
              onOpenArtist: onOpenArtist,
              onOpenTrack: onOpenTrack,
              onOpenPlaylist: onOpenPlaylist,
              onPlayTrack: onPlayTrack,
              onToggleFavorite: onToggleFavorite,
              onAddToPlaylist: onAddToPlaylist,
            ),
        ],
      ),
    );
  }
}

enum _ResultKind { track, album, artist, playlist }

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({
    required this.coreBaseUrl,
    required this.title,
    required this.icon,
    required this.items,
    required this.itemKind,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenTrack,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String coreBaseUrl;
  final String title;
  final IconData icon;
  final List<dynamic> items;
  final _ResultKind itemKind;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(int) onOpenArtist;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onOpenPlaylist;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final resultMaps = items
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _HomePanel(
        title: title,
        trailing: Chip(
          avatar: Icon(icon, size: 18),
          label: Text('${items.length}'),
        ),
        padding: EdgeInsets.zero,
        child: resultMaps.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_tr(context, 'No results')),
              )
            : Column(
                children: [
                  for (var index = 0; index < resultMaps.length; index++) ...[
                    _SearchResultRow(
                      coreBaseUrl: coreBaseUrl,
                      item: resultMaps[index],
                      kind: itemKind,
                      onOpenAlbum: onOpenAlbum,
                      onOpenArtist: onOpenArtist,
                      onOpenTrack: onOpenTrack,
                      onOpenPlaylist: onOpenPlaylist,
                      onPlayTrack: onPlayTrack,
                      onToggleFavorite: onToggleFavorite,
                      onAddToPlaylist: onAddToPlaylist,
                    ),
                    if (index != resultMaps.length - 1)
                      const Divider(height: 1),
                  ],
                ],
              ),
      ),
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({
    required this.coreBaseUrl,
    required this.item,
    required this.kind,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onOpenTrack,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> item;
  final _ResultKind kind;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(int) onOpenArtist;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onOpenPlaylist;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final id = _intValue(item['id']);
    final title = (item['title'] ?? item['name'] ?? 'Untitled').toString();
    final icon = switch (kind) {
      _ResultKind.track => Icons.music_note_outlined,
      _ResultKind.album => Icons.album_outlined,
      _ResultKind.artist => Icons.person_outline,
      _ResultKind.playlist => Icons.queue_music_outlined,
    };
    final trailing = switch (kind) {
      _ResultKind.track => _TrackActions(
        track: item,
        compact: true,
        onToggleFavorite: onToggleFavorite,
        onAddToPlaylist: id == null
            ? null
            : () => unawaited(onAddToPlaylist(id)),
        onPlay: id == null ? null : () => unawaited(onPlayTrack(id)),
      ),
      _ResultKind.album => const Icon(Icons.chevron_right),
      _ResultKind.artist => const Icon(Icons.chevron_right),
      _ResultKind.playlist => const Icon(Icons.chevron_right),
    };
    final imageUrl = switch (kind) {
      _ResultKind.track => null,
      _ResultKind.album => _albumArtworkUrl(coreBaseUrl, item['id']),
      _ResultKind.artist => _artistArtworkUrl(
        coreBaseUrl,
        item['id'],
        'search_list',
        revision: item['artwork_revision'],
        width: 128,
        height: 128,
      ),
      _ResultKind.playlist => null,
    };

    return _SimpleListRow(
      leading: _ArtworkTile(
        title: title,
        subtitle: _searchSubtitle(item, kind),
        size: 42,
        icon: icon,
        imageUrl: imageUrl,
      ),
      title: title,
      subtitle: _searchSubtitle(item, kind),
      trailing: trailing,
      onTap: id == null
          ? null
          : () {
              switch (kind) {
                case _ResultKind.track:
                  unawaited(onOpenTrack(id));
                case _ResultKind.album:
                  unawaited(onOpenAlbum(id));
                case _ResultKind.artist:
                  unawaited(onOpenArtist(id));
                case _ResultKind.playlist:
                  unawaited(onOpenPlaylist(id));
              }
            },
    );
  }
}

List<dynamic> _sortedTracks(List<dynamic> items, _SearchSort sort) {
  final sorted = [...items];
  int textCompare(Object? left, Object? right) => (left?.toString() ?? '')
      .toLowerCase()
      .compareTo((right?.toString() ?? '').toLowerCase());
  int intCompare(Object? left, Object? right) =>
      (_intValue(right) ?? 0).compareTo(_intValue(left) ?? 0);
  switch (sort) {
    case _SearchSort.relevance:
      return sorted;
    case _SearchSort.titleAz:
      sorted.sort(
        (a, b) => textCompare(_asMap(a)['title'], _asMap(b)['title']),
      );
    case _SearchSort.albumAz:
      sorted.sort(
        (a, b) =>
            textCompare(_asMap(a)['album_title'], _asMap(b)['album_title']),
      );
    case _SearchSort.artistAz:
      sorted.sort(
        (a, b) => textCompare(
          _asMap(a)['artist_display'],
          _asMap(b)['artist_display'],
        ),
      );
    case _SearchSort.fileSize:
      sorted.sort(
        (a, b) => intCompare(_asMap(a)['size_bytes'], _asMap(b)['size_bytes']),
      );
    case _SearchSort.addedAt:
      sorted.sort(
        (a, b) => textCompare(_asMap(b)['added_at'], _asMap(a)['added_at']),
      );
    case _SearchSort.playCount:
      sorted.sort(
        (a, b) => intCompare(_asMap(a)['play_count'], _asMap(b)['play_count']),
      );
    case _SearchSort.favorite:
      sorted.sort((a, b) {
        final left = _asMap(a)['is_favorite'] == true ? 1 : 0;
        final right = _asMap(b)['is_favorite'] == true ? 1 : 0;
        return right.compareTo(left);
      });
  }
  return sorted;
}

List<dynamic> _sortedAlbums(List<dynamic> items, _SearchSort sort) {
  final sorted = [...items];
  if (sort == _SearchSort.titleAz || sort == _SearchSort.albumAz) {
    sorted.sort(
      (a, b) => (_asMap(a)['title']?.toString() ?? '').compareTo(
        _asMap(b)['title']?.toString() ?? '',
      ),
    );
  }
  return sorted;
}

List<dynamic> _sortedArtists(List<dynamic> items, _SearchSort sort) {
  final sorted = [...items];
  if (sort == _SearchSort.titleAz || sort == _SearchSort.artistAz) {
    sorted.sort(
      (a, b) => (_asMap(a)['name']?.toString() ?? '').compareTo(
        _asMap(b)['name']?.toString() ?? '',
      ),
    );
  }
  return sorted;
}

List<dynamic> _sortedPlaylists(List<dynamic> items, _SearchSort sort) {
  final sorted = [...items];
  if (sort == _SearchSort.titleAz) {
    sorted.sort(
      (a, b) => (_asMap(a)['name']?.toString() ?? '').compareTo(
        _asMap(b)['name']?.toString() ?? '',
      ),
    );
  }
  return sorted;
}

class _SheetTrackRow extends StatelessWidget {
  const _SheetTrackRow({
    required this.track,
    required this.indexLabel,
    required this.subtitle,
    required this.onToggleFavorite,
    this.coreBaseUrl,
    this.onOpen,
    this.onPlay,
    this.onAddToPlaylist,
    this.onRemove,
  });

  final Map<String, dynamic> track;
  final String indexLabel;
  final String subtitle;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final String? coreBaseUrl;
  final VoidCallback? onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final title = track['title']?.toString() ?? 'Untitled';
    final artist = track['artist_display']?.toString() ?? '';
    final regularLeading = coreBaseUrl == null
        ? SizedBox(
            width: 42,
            child: Text(
              indexLabel,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
          )
        : SizedBox(
            width: 84,
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    indexLabel,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _ArtworkTile(
                  title: title,
                  subtitle: artist,
                  size: 42,
                  icon: Icons.music_note_outlined,
                  imageUrl: _trackArtworkUrl(coreBaseUrl!, track['id']),
                ),
              ],
            ),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          final compactLeading = coreBaseUrl == null
              ? SizedBox(
                  width: 28,
                  child: Text(
                    indexLabel,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                )
              : SizedBox(
                  width: 72,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          indexLabel,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: IntMusicTheme.of(context).textSecondary,
                              ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _ArtworkTile(
                        title: title,
                        subtitle: artist,
                        size: 42,
                        icon: Icons.music_note_outlined,
                        imageUrl: _trackArtworkUrl(coreBaseUrl!, track['id']),
                      ),
                    ],
                  ),
                );
          final trailing = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TrackActions(
                track: track,
                compact: true,
                onToggleFavorite: onToggleFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlay: onPlay,
              ),
              if (onRemove != null)
                _AppTooltip(
                  message: 'Remove',
                  child: IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
            ],
          );
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onOpen,
              child: SizedBox(
                height: 78,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      compactLeading,
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
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
                                ),
                                if (track['_availability'] is Map) ...[
                                  const SizedBox(width: 6),
                                  _TrackAvailabilityBadge(
                                    track: track,
                                    compact: true,
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      trailing,
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return _SimpleListRow(
          height: 70,
          leading: regularLeading,
          title: title,
          subtitle: subtitle,
          onTap: onOpen,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TrackAvailabilityBadge(track: track, compact: true),
              const SizedBox(width: 4),
              _TrackActions(
                track: track,
                compact: true,
                onToggleFavorite: onToggleFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlay: onPlay,
              ),
              if (onRemove != null)
                _AppTooltip(
                  message: 'Remove',
                  child: IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
