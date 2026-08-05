part of '../intmusic_client.dart';

class _AlbumInfoPage extends StatelessWidget {
  const _AlbumInfoPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onClose,
    required this.onPlayTrack,
    required this.onOpenTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? detail;
  final VoidCallback onClose;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final album = _asMap(detail['album']);
    final tracks = (detail['tracks'] as List?) ?? const [];
    final discNumbers = tracks
        .map((item) => _intValue((item as Map)['disc_number']) ?? 1)
        .toSet();
    final showDiscSeparators =
        discNumbers.length > 1 || discNumbers.any((disc) => disc > 1);
    return _PageFrame(
      title: 'Album detail',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
            child: _ResponsiveDetailHeading(
              header: _DetailHeader(
                icon: Icons.album_outlined,
                title: album['title']?.toString() ?? 'Untitled',
                subtitle: _joinParts([
                  album['album_artist_display'],
                  album['year'],
                  '${album['track_count'] ?? tracks.length} tracks',
                ]),
                imageUrl: _albumArtworkUrl(coreBaseUrl, album['id']),
              ),
              actions: _CollectionActions(tracks: tracks, onClose: onClose),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = (tracks[index] as Map).cast<String, dynamic>();
                final id = _intValue(track['id']);
                final discNumber = _intValue(track['disc_number']) ?? 1;
                final previousDiscNumber = index == 0
                    ? null
                    : _intValue((tracks[index - 1] as Map)['disc_number']) ?? 1;
                final startsDisc =
                    showDiscSeparators && discNumber != previousDiscNumber;
                return Column(
                  children: [
                    if (startsDisc) _DiscSeparator(discNumber: discNumber),
                    if (index > 0 && !startsDisc) const Divider(height: 1),
                    _SheetTrackRow(
                      coreBaseUrl: coreBaseUrl,
                      track: track,
                      indexLabel: showDiscSeparators
                          ? (_intValue(track['track_number'])?.toString() ??
                                '-')
                          : _trackNumber(track),
                      subtitle: _joinParts([
                        track['artist_display'],
                        _formatDuration(track['duration_ms']),
                        _ratingLabel(track),
                      ]),
                      onOpen: id == null
                          ? null
                          : () => unawaited(onOpenTrack(id)),
                      onPlay: id == null
                          ? null
                          : () => unawaited(onPlayTrack(id)),
                      onToggleFavorite: onToggleFavorite,
                      onAddToPlaylist: id == null
                          ? null
                          : () => unawaited(onAddToPlaylist(id)),
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

class _DiscSeparator extends StatelessWidget {
  const _DiscSeparator({required this.discNumber});

  final int discNumber;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
        child: Row(
          children: [
            Text(
              '${_tr(context, 'Disc')} $discNumber',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: tokens.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Divider(color: tokens.stroke)),
          ],
        ),
      ),
    );
  }
}

class _ArtistInfoPage extends StatelessWidget {
  const _ArtistInfoPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onClose,
    required this.onEdit,
    required this.onOpenAlbum,
    required this.onPlayTrack,
    required this.onOpenTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? detail;
  final VoidCallback onClose;
  final Future<void> Function() onEdit;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final artist = _asMap(detail['artist']);
    final profile = detail['profile'] == null
        ? <String, dynamic>{}
        : _asMap(detail['profile']);
    final albums = (detail['albums'] as List?) ?? const [];
    final tracks = (detail['tracks'] as List?) ?? const [];
    final trackMaps = tracks
        .map((track) => (track as Map).cast<String, dynamic>())
        .toList(growable: false);
    final singleTracks = trackMaps
        .where(_isSingleTrack)
        .toList(growable: false);
    final albumTracks = trackMaps
        .where((track) => !_isSingleTrack(track))
        .toList(growable: false);
    return _PageFrame(
      title: 'Artist detail',
      child: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          _ArtistHero(
            coreBaseUrl: coreBaseUrl,
            artist: artist,
            profile: profile,
            albumCount: albums.length,
            trackCount: tracks.length,
            collectionTracks: tracks,
            onEdit: onEdit,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ((profile['biography']?.toString().trim() ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 880),
                      child: Text(
                        profile['biography'].toString(),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          height: 1.55,
                          color: IntMusicTheme.of(context).textSecondary,
                        ),
                      ),
                    ),
                  ),
                if ((profile['genres'] as List? ?? const []).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: (profile['genres'] as List)
                          .map((genre) => Chip(label: Text(genre.toString())))
                          .toList(),
                    ),
                  ),
                Text(
                  _tr(context, 'Albums'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 196,
                  child: albums.isEmpty
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_tr(context, 'No albums')),
                        )
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: albums.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 14),
                          itemBuilder: (context, index) {
                            final album = (albums[index] as Map)
                                .cast<String, dynamic>();
                            final id = _intValue(album['id']);
                            return SizedBox(
                              width: 136,
                              child: InkWell(
                                onTap: id == null
                                    ? null
                                    : () => unawaited(onOpenAlbum(id)),
                                borderRadius: BorderRadius.circular(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _ArtworkTile(
                                      title:
                                          album['title']?.toString() ??
                                          'Untitled',
                                      subtitle:
                                          album['album_artist_display']
                                              ?.toString() ??
                                          '',
                                      size: 126,
                                      icon: Icons.album_outlined,
                                      imageUrl: _albumArtworkUrl(
                                        coreBaseUrl,
                                        album['id'],
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      album['title']?.toString() ?? 'Untitled',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                if (singleTracks.isNotEmpty)
                  _ArtistTrackSection(
                    title: 'Singles',
                    coreBaseUrl: coreBaseUrl,
                    tracks: singleTracks,
                    onOpenTrack: onOpenTrack,
                    onPlayTrack: onPlayTrack,
                    onToggleFavorite: onToggleFavorite,
                    onAddToPlaylist: onAddToPlaylist,
                  ),
                if (albumTracks.isNotEmpty)
                  _ArtistTrackSection(
                    title: 'Tracks',
                    coreBaseUrl: coreBaseUrl,
                    tracks: albumTracks,
                    onOpenTrack: onOpenTrack,
                    onPlayTrack: onPlayTrack,
                    onToggleFavorite: onToggleFavorite,
                    onAddToPlaylist: onAddToPlaylist,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistHero extends StatelessWidget {
  const _ArtistHero({
    required this.coreBaseUrl,
    required this.artist,
    required this.profile,
    required this.albumCount,
    required this.trackCount,
    required this.collectionTracks,
    required this.onEdit,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> artist;
  final Map<String, dynamic> profile;
  final int albumCount;
  final int trackCount;
  final List<dynamic> collectionTracks;
  final Future<void> Function() onEdit;

  @override
  Widget build(BuildContext context) {
    final artistId = _intValue(artist['id']);
    final name = artist['name']?.toString() ?? 'Unknown Artist';
    final revision = artist['artwork_revision'];
    final heroUrl = _artistArtworkUrl(
      coreBaseUrl,
      artistId,
      'detail_hero',
      revision: revision,
      width: 1800,
      height: 620,
    );
    final avatarUrl = _artistArtworkUrl(
      coreBaseUrl,
      artistId,
      'avatar',
      revision: revision,
      width: 420,
      height: 420,
    );
    final metadata =
        [
              profile['artist_type'],
              profile['country'],
              if ((profile['begin_date']?.toString() ?? '').isNotEmpty)
                (profile['end_date']?.toString() ?? '').isEmpty
                    ? '${profile['begin_date']}–'
                    : '${profile['begin_date']}–${profile['end_date']}',
            ]
            .where((item) => item != null && item.toString().trim().isNotEmpty)
            .join(' · ');

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final heroCacheWidth =
            (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(640, 2560);
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _CollectionActions(tracks: collectionTracks),
            OutlinedButton.icon(
              onPressed: () => unawaited(onEdit()),
              icon: const Icon(Icons.edit_outlined),
              label: Text(_tr(context, 'Edit')),
            ),
          ],
        );
        return SizedBox(
          height: compact ? 350 : 320,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_seededColor(name, 0), _seededColor(name, 1)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              if (heroUrl != null)
                ValueListenableBuilder<int>(
                  valueListenable: artworkCacheCoordinator.retryRevision,
                  builder: (context, retryRevision, child) {
                    return CachedNetworkImage(
                      key: ValueKey(
                        '${artworkCacheCoordinator.cacheKey(heroUrl)}:'
                        '$retryRevision',
                      ),
                      cacheManager: _artworkCacheManager,
                      cacheKey: artworkCacheCoordinator.cacheKey(heroUrl),
                      imageUrl: heroUrl,
                      fit: BoxFit.cover,
                      memCacheWidth: heroCacheWidth,
                      filterQuality: FilterQuality.medium,
                      fadeInDuration: const Duration(milliseconds: 220),
                      errorWidget: (context, url, error) =>
                          const SizedBox.shrink(),
                    );
                  },
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: compact
                        ? const [
                            Color(0xc8000000),
                            Color(0x77000000),
                            Color(0x22000000),
                          ]
                        : const [
                            Color(0xe6000000),
                            Color(0xa8000000),
                            Color(0x33000000),
                            Color(0x08000000),
                          ],
                    stops: compact
                        ? const [0, 0.7, 1]
                        : const [0, 0.36, 0.7, 1],
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x33000000),
                      Colors.transparent,
                      Color(0x88000000),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: compact ? 20 : 28,
                right: compact ? 20 : 28,
                bottom: compact ? 22 : 28,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ClipOval(
                      child: _ArtworkTile(
                        title: name,
                        subtitle: 'artist',
                        size: compact ? 84 : 112,
                        icon: Icons.person_outline,
                        imageUrl: avatarUrl,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style:
                                (compact
                                        ? Theme.of(
                                            context,
                                          ).textTheme.headlineSmall
                                        : Theme.of(
                                            context,
                                          ).textTheme.headlineMedium)
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      shadows: const [
                                        Shadow(
                                          color: Colors.black54,
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                          ),
                          if (metadata.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              metadata,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: Colors.white70),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            '$albumCount albums · $trackCount tracks',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Colors.white70),
                          ),
                          if (compact) ...[
                            const SizedBox(height: 12),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: actions,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (!compact)
                Positioned(
                  top: 20,
                  right: 24,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: actions,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

bool _isSingleTrack(Map<String, dynamic> track) {
  final albumTitle = track['album_title']?.toString().trim();
  return _intValue(track['album_id']) == null ||
      albumTitle == null ||
      albumTitle.isEmpty;
}

class _ArtistTrackSection extends StatelessWidget {
  const _ArtistTrackSection({
    required this.title,
    required this.coreBaseUrl,
    required this.tracks,
    required this.onOpenTrack,
    required this.onPlayTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String title;
  final String coreBaseUrl;
  final List<Map<String, dynamic>> tracks;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr(context, title),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < tracks.length; index++) ...[
            Builder(
              builder: (context) {
                final track = tracks[index];
                final id = _intValue(track['id']);
                return _SheetTrackRow(
                  coreBaseUrl: coreBaseUrl,
                  track: track,
                  indexLabel: '${index + 1}',
                  subtitle: _joinParts([
                    track['album_title'],
                    _formatDuration(track['duration_ms']),
                    _ratingLabel(track),
                  ]),
                  onOpen: id == null ? null : () => unawaited(onOpenTrack(id)),
                  onPlay: id == null ? null : () => unawaited(onPlayTrack(id)),
                  onToggleFavorite: onToggleFavorite,
                  onAddToPlaylist: id == null
                      ? null
                      : () => unawaited(onAddToPlaylist(id)),
                );
              },
            ),
            if (index != tracks.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}
