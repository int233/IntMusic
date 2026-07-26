part of '../intmusic_client.dart';

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
