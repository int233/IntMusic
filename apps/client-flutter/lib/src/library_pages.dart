part of '../main.dart';

class _AlbumsPage extends StatelessWidget {
  const _AlbumsPage({
    required this.coreBaseUrl,
    required this.albums,
    required this.onOpenAlbum,
  });

  final String coreBaseUrl;
  final List<dynamic> albums;
  final Future<void> Function(int) onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: 'Albums',
      child: albums.isEmpty
          ? const Center(child: Text('No albums'))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 214,
                mainAxisSpacing: 20,
                crossAxisSpacing: 18,
                childAspectRatio: 0.72,
              ),
              itemCount: albums.length,
              itemBuilder: (context, index) {
                final album = (albums[index] as Map).cast<String, dynamic>();
                final id = _intValue(album['id']);
                return _AlbumCard(
                  coreBaseUrl: coreBaseUrl,
                  album: album,
                  onTap: id == null ? null : () => unawaited(onOpenAlbum(id)),
                );
              },
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
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xff9ea5ae)),
              ),
            ],
          ),
        ),
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
  });

  final String coreBaseUrl;
  final List<dynamic> tracks;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  State<_TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<_TracksPage> {
  Timer? _scrollIdleTimer;
  bool _deferArtwork = false;

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
    return _PageFrame(
      title: 'Tracks',
      child: widget.tracks.isEmpty
          ? const Center(child: Text('No tracks'))
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
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            220,
                          ),
                          itemExtent: 67,
                          itemCount: widget.tracks.length,
                          itemBuilder: (context, index) {
                            final track = (widget.tracks[index] as Map)
                                .cast<String, dynamic>();
                            final id = _intValue(track['id']);
                            return DecoratedBox(
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: appBorder),
                                ),
                              ),
                              child: _TrackTableRow(
                                coreBaseUrl: widget.coreBaseUrl,
                                track: track,
                                showAlbum: showAlbum,
                                deferArtwork: _deferArtwork,
                                onTap: id == null
                                    ? null
                                    : () => unawaited(widget.onOpenTrack(id)),
                                onPlay: id == null
                                    ? null
                                    : () => unawaited(widget.onPlayTrack(id)),
                                onAddToPlaylist: id == null
                                    ? null
                                    : () =>
                                          unawaited(widget.onAddToPlaylist(id)),
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
    );
  }
}

class _TrackTableHeader extends StatelessWidget {
  const _TrackTableHeader({required this.showAlbum});

  final bool showAlbum;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: const Color(0xff8f97a3),
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
  });

  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final bool showAlbum;
  final bool deferArtwork;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final title = track['title']?.toString() ?? 'Untitled';
    final artist = track['artist_display']?.toString() ?? 'Unknown Artist';
    final favorite = track['is_favorite'] == true;

    return Material(
      color: favorite ? appPrimary.withValues(alpha: 0.06) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
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
                          color: const Color(0xff9ea5ae),
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
                        color: const Color(0xffb8bec7),
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
                      color: const Color(0xff9ea5ae),
                    ),
                  ),
                ),
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

class _EntityListPage extends StatelessWidget {
  const _EntityListPage({
    required this.title,
    required this.emptyLabel,
    required this.items,
    required this.leadingIcon,
    required this.titleBuilder,
    required this.subtitleBuilder,
    this.onOpen,
  });

  final String title;
  final String emptyLabel;
  final List<dynamic> items;
  final IconData leadingIcon;
  final String Function(Map<String, dynamic>) titleBuilder;
  final String Function(Map<String, dynamic>) subtitleBuilder;
  final void Function(Map<String, dynamic>)? onOpen;

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: title,
      child: items.isEmpty
          ? Center(child: Text(emptyLabel))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
              itemCount: items.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = (items[index] as Map).cast<String, dynamic>();
                return _SimpleListRow(
                  leading: Icon(leadingIcon),
                  title: titleBuilder(item),
                  subtitle: subtitleBuilder(item),
                  onTap: onOpen == null ? null : () => onOpen!(item),
                );
              },
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
      if (widget.onAddToPlaylist != null)
        _AppTooltip(
          message: 'Add to playlist',
          child: IconButton(
            onPressed: widget.onAddToPlaylist,
            icon: const Icon(Icons.playlist_add),
          ),
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
