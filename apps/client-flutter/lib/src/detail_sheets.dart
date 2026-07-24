part of '../main.dart';

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
                CachedNetworkImage(
                  cacheManager: _artworkCacheManager,
                  imageUrl: heroUrl,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 220),
                  errorWidget: (context, url, error) => const SizedBox.shrink(),
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

class _TrackInfoPage extends StatelessWidget {
  const _TrackInfoPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onClose,
    required this.onPlayTrack,
    required this.onOpenAlbum,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
    required this.onEdit,
    required this.onManageVersions,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? detail;
  final VoidCallback onClose;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;
  final Future<void> Function() onEdit;
  final Future<void> Function() onManageVersions;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) {
      return _PageFrame(
        title: 'Track detail',
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final track = _asMap(detail['track']);
    final lyrics = detail['lyrics'] == null ? null : _asMap(detail['lyrics']);
    final genres = (detail['genres'] as List?) ?? const [];
    final composers = (detail['composers'] as List?) ?? const [];
    final lyricists = (detail['lyricists'] as List?) ?? const [];
    final media = detail['media'] == null ? null : _asMap(detail['media']);
    final trackId = _intValue(track['id']);
    final albumId = _intValue(track['album_id']);

    return _PageFrame(
      title: 'Track detail',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final header = _DetailHeader(
                  icon: Icons.music_note_outlined,
                  title: track['title']?.toString() ?? 'Untitled',
                  subtitle: _joinParts([
                    track['artist_display'],
                    track['album_title'],
                    _formatDuration(track['duration_ms']),
                    _ratingLabel(track),
                  ]),
                  imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
                );
                final actions = <Widget>[
                  OutlinedButton.icon(
                    onPressed: trackId == null
                        ? null
                        : () => unawaited(onEdit()),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(_tr(context, 'Edit')),
                  ),
                  _TrackActions(
                    track: track,
                    onToggleFavorite: onToggleFavorite,
                    onAddToPlaylist: trackId == null
                        ? null
                        : () => onAddToPlaylist(trackId),
                  ),
                  FilledButton.icon(
                    onPressed: trackId == null
                        ? null
                        : () {
                            onPlayTrack(trackId);
                          },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                  OutlinedButton.icon(
                    onPressed: albumId == null
                        ? null
                        : () => unawaited(onOpenAlbum(albumId)),
                    icon: const Icon(Icons.album_outlined),
                    label: Text(_tr(context, 'Album')),
                  ),
                  _AppTooltip(
                    message: _tr(context, 'Close'),
                    child: IconButton.filledTonal(
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ];
                final actionBar = Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                );

                if (constraints.maxWidth < 680) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [header, const SizedBox(height: 12), actionBar],
                  );
                }

                return Row(
                  children: [
                    Expanded(child: header),
                    const SizedBox(width: 12),
                    actionBar,
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
              children: [
                _InfoRow(
                  label: 'Album',
                  value: track['album_title']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: 'Artist',
                  value: track['artist_display']?.toString() ?? '-',
                ),
                if (composers.isNotEmpty)
                  _InfoRow(
                    label: 'Composer',
                    value: composers.map((item) => item.toString()).join(', '),
                  ),
                if (lyricists.isNotEmpty)
                  _InfoRow(
                    label: 'Lyricist',
                    value: lyricists.map((item) => item.toString()).join(', '),
                  ),
                _InfoRow(
                  label: 'Year',
                  value: track['year']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: 'Favorite',
                  value: track['is_favorite'] == true ? 'yes' : 'no',
                ),
                _InfoRow(
                  label: 'Rating',
                  value: _ratingLabel(track).isEmpty
                      ? '-'
                      : _ratingLabel(track),
                ),
                if (media != null) ...[
                  const SizedBox(height: 18),
                  _TrackMediaOverview(media: media, onManage: onManageVersions),
                  const SizedBox(height: 18),
                ],
                _InfoRow(
                  label: 'Format',
                  value: _joinParts([
                    detail['extension']?.toString().toUpperCase(),
                    _formatBytes(detail['size_bytes']),
                    detail['scan_status'],
                  ]),
                ),
                _InfoRow(
                  label: 'Modified',
                  value: detail['modified_at']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: 'File',
                  value: detail['file_path']?.toString() ?? '-',
                ),
                if (genres.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: genres
                        .map((genre) => Chip(label: Text(genre.toString())))
                        .toList(),
                  ),
                ],
                const SizedBox(height: 20),
                Text('Lyrics', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: IntMusicTheme.of(context).stroke),
                    borderRadius: BorderRadius.circular(8),
                    color: IntMusicTheme.of(context).surface,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: SelectableText(
                      lyrics?['text']?.toString().trim().isNotEmpty == true
                          ? lyrics!['text'].toString()
                          : _tr(context, 'No embedded lyrics'),
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackMediaOverview extends StatelessWidget {
  const _TrackMediaOverview({required this.media, required this.onManage});

  final Map<String, dynamic> media;
  final Future<void> Function() onManage;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final work = _asMap(media['work']);
    final recording = _asMap(media['recording']);
    final release = media['release'] == null
        ? <String, dynamic>{}
        : _asMap(media['release']);
    final variants = (media['variants'] as List? ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    final related = (media['related_release_tracks'] as List? ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .where((item) => item['is_current'] != true)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.library_music_outlined, color: tokens.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _tr(context, 'Versions and availability'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              onPressed: () => unawaited(onManage()),
              icon: const Icon(Icons.account_tree_outlined, size: 18),
              label: Text(_tr(context, 'Manage versions')),
            ),
          ],
        ),
        const SizedBox(height: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: tokens.stroke),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MediaIdentityChip(
                      icon: Icons.music_note,
                      label: work['title']?.toString() ?? '-',
                    ),
                    _MediaIdentityChip(
                      icon: recording['recording_kind'] == 'live'
                          ? Icons.mic_external_on_outlined
                          : Icons.graphic_eq,
                      label: _recordingKindLabel(
                        context,
                        recording['recording_kind']?.toString(),
                      ),
                    ),
                    if ((release['title']?.toString() ?? '').isNotEmpty)
                      _MediaIdentityChip(
                        icon: Icons.album_outlined,
                        label: release['title'].toString(),
                      ),
                  ],
                ),
                if (variants.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (var index = 0; index < variants.length; index++) ...[
                    _MediaVariantRow(variant: variants[index]),
                    if (index != variants.length - 1)
                      Divider(height: 18, color: tokens.stroke),
                  ],
                ],
                if (related.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Divider(height: 1, color: tokens.stroke),
                  const SizedBox(height: 12),
                  Text(
                    _tr(context, 'Also appears on'),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: related
                        .map((item) {
                          final relatedRelease = item['release'] == null
                              ? <String, dynamic>{}
                              : _asMap(item['release']);
                          final title =
                              relatedRelease['title']?.toString() ??
                              item['title']?.toString() ??
                              '-';
                          final position = _joinParts([
                            relatedRelease['year'],
                            if (_intValue(item['disc_number']) != null)
                              '${_tr(context, 'Disc')} ${item['disc_number']}',
                            if (_intValue(item['track_number']) != null)
                              '#${item['track_number']}',
                          ]);
                          return Chip(
                            avatar: const Icon(Icons.album_outlined, size: 16),
                            label: Text(
                              position.isEmpty ? title : '$title · $position',
                            ),
                          );
                        })
                        .toList(growable: false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaIdentityChip extends StatelessWidget {
  const _MediaIdentityChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _MediaVariantRow extends StatelessWidget {
  const _MediaVariantRow({required this.variant});

  final Map<String, dynamic> variant;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final master = _asMap(variant['master']);
    final replicas = (variant['replicas'] as List? ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    final format = _joinParts([
      variant['codec']?.toString().toUpperCase(),
      _audioResolutionLabel(variant),
      _audioBitrateLabel(variant),
    ]);
    final masterLabel = _joinParts([
      master['label'],
      master['mastering_kind'] == 'unknown' ? null : master['mastering_kind'],
    ]);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: tokens.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            variant['is_preferred'] == true
                ? Icons.high_quality_outlined
                : Icons.audio_file_outlined,
            color: tokens.accent,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      format.isEmpty ? _tr(context, 'Unknown format') : format,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (variant['is_preferred'] == true) ...[
                    const SizedBox(width: 8),
                    Text(
                      _tr(context, 'Preferred'),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: tokens.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
              if (masterLabel.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  masterLabel,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
                ),
              ],
              if (replicas.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: replicas
                      .map((replica) {
                        final available =
                            replica['availability_state']?.toString() ==
                            'ready';
                        return Chip(
                          avatar: Icon(
                            available
                                ? Icons.check_circle_outline
                                : Icons.cloud_off_outlined,
                            size: 15,
                            color: available
                                ? tokens.playing
                                : tokens.textSecondary,
                          ),
                          label: Text(
                            replica['device_name']?.toString() ??
                                _tr(context, 'Unknown device'),
                          ),
                          visualDensity: VisualDensity.compact,
                        );
                      })
                      .toList(growable: false),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _recordingKindLabel(BuildContext context, String? kind) {
  return switch (kind) {
    'live' => _tr(context, 'Live recording'),
    'acoustic' => _tr(context, 'Acoustic recording'),
    'demo' => _tr(context, 'Demo recording'),
    _ => _tr(context, 'Studio recording'),
  };
}

String? _audioResolutionLabel(Map<String, dynamic> variant) {
  final bitDepth = _intValue(variant['bit_depth']);
  final sampleRate = _intValue(variant['sample_rate']);
  if (bitDepth == null && sampleRate == null) {
    return null;
  }
  final sampleRateLabel = sampleRate == null
      ? null
      : sampleRate >= 1000
      ? '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz'
      : '$sampleRate Hz';
  return _joinParts([if (bitDepth != null) '$bitDepth-bit', sampleRateLabel]);
}

String? _audioBitrateLabel(Map<String, dynamic> variant) {
  final bitrate = _intValue(variant['bitrate']);
  if (bitrate == null || bitrate <= 0) {
    return null;
  }
  return '${(bitrate / 1000).round()} kbps';
}

class _TrackVersionManagerDialog extends StatefulWidget {
  const _TrackVersionManagerDialog({
    required this.api,
    required this.trackId,
    required this.detail,
  });

  final CoreApiClient api;
  final int trackId;
  final Map<String, dynamic> detail;

  @override
  State<_TrackVersionManagerDialog> createState() =>
      _TrackVersionManagerDialogState();
}

class _TrackVersionManagerDialogState
    extends State<_TrackVersionManagerDialog> {
  late Map<String, dynamic> _media;
  List<Map<String, dynamic>> _candidates = const [];
  bool _loading = true;
  bool _saving = false;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _media = widget.detail['media'] == null
        ? <String, dynamic>{}
        : _asMap(widget.detail['media']);
    unawaited(_loadCandidates());
  }

  Future<void> _loadCandidates() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await widget.api.getJson(
        '/tracks/${widget.trackId}/recording/candidates',
      );
      final candidates = (response as List? ?? const [])
          .map((item) => (item as Map).cast<String, dynamic>())
          .toList(growable: false);
      if (!mounted) {
        return;
      }
      setState(() {
        _candidates = candidates;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _linkCandidate(Map<String, dynamic> candidate) async {
    final sourceTrackId = _intValue(candidate['track_id']);
    if (sourceTrackId == null || candidate['already_linked'] == true) {
      return;
    }
    final album = candidate['album_title']?.toString() ?? '-';
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_tr(context, 'Link the same recording?')),
            content: Text(
              '${_tr(context, 'This release track will be associated with the recording used by')} “$album”. '
              '${_tr(context, 'Albums, files, masters, and lyric timing remain independent.')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_tr(context, 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_tr(context, 'Link recording')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    await _mutate('/tracks/${widget.trackId}/recording/link', <String, dynamic>{
      'source_track_id': sourceTrackId,
    });
  }

  Future<void> _detach() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_tr(context, 'Separate this recording?')),
            content: Text(
              _tr(
                context,
                'This release track will receive an independent recording identity. Its album and audio files will not change.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_tr(context, 'Cancel')),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_tr(context, 'Separate')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    await _mutate(
      '/tracks/${widget.trackId}/recording/detach',
      const <String, dynamic>{},
    );
  }

  Future<void> _mutate(String path, Map<String, dynamic> payload) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final media = _asMap(await widget.api.postJson(path, payload));
      if (!mounted) {
        return;
      }
      setState(() {
        _media = media;
        _saving = false;
        _changed = true;
      });
      await _loadCandidates();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final recording = _media['recording'] == null
        ? <String, dynamic>{}
        : _asMap(_media['recording']);
    final related = (_media['related_release_tracks'] as List? ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    final unlinked = _candidates
        .where((candidate) => candidate['already_linked'] != true)
        .toList(growable: false);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, color: tokens.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Manage recording versions'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          _tr(
                            context,
                            'Connect release tracks only when they use the same recorded performance.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.pop(context, _changed),
                    icon: const Icon(Icons.close),
                    tooltip: _tr(context, 'Close'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  _VersionManagerNotice(),
                  const SizedBox(height: 18),
                  _VersionManagerSection(
                    title: _tr(context, 'Current recording'),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: tokens.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.graphic_eq, color: tokens.accent),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                recording['title']?.toString() ?? '-',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                _joinParts([
                                  _recordingKindLabel(
                                    context,
                                    recording['recording_kind']?.toString(),
                                  ),
                                  '${related.length} ${_tr(context, 'release tracks')}',
                                ]),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: tokens.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        if (related.length > 1)
                          OutlinedButton.icon(
                            onPressed: _saving ? null : _detach,
                            icon: const Icon(Icons.call_split_outlined),
                            label: Text(_tr(context, 'Separate')),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  _VersionManagerSection(
                    title: _tr(context, 'Release tracks using this recording'),
                    child: related.isEmpty
                        ? Text(_tr(context, 'No linked release tracks'))
                        : Column(
                            children: [
                              for (
                                var index = 0;
                                index < related.length;
                                index++
                              ) ...[
                                _LinkedReleaseRow(item: related[index]),
                                if (index != related.length - 1)
                                  Divider(height: 18, color: tokens.stroke),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 18),
                  _VersionManagerSection(
                    title: _tr(context, 'Possible matches'),
                    trailing: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            onPressed: _saving ? null : _loadCandidates,
                            icon: const Icon(Icons.refresh, size: 19),
                            tooltip: _tr(context, 'Refresh'),
                          ),
                    child: _loading
                        ? const SizedBox(height: 72)
                        : unlinked.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              _tr(
                                context,
                                'No safe metadata candidates found.',
                              ),
                              style: TextStyle(color: tokens.textSecondary),
                            ),
                          )
                        : Column(
                            children: [
                              for (
                                var index = 0;
                                index < unlinked.length;
                                index++
                              ) ...[
                                _RecordingCandidateRow(
                                  candidate: unlinked[index],
                                  enabled: !_saving,
                                  onLink: () => _linkCandidate(unlinked[index]),
                                ),
                                if (index != unlinked.length - 1)
                                  Divider(height: 18, color: tokens.stroke),
                              ],
                            ],
                          ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, style: TextStyle(color: tokens.danger)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionManagerNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.accent.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: tokens.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _tr(
                  context,
                  'Linking shares only the recording identity. Every album keeps its own track, artwork, master, audio file, and lyric timing.',
                ),
                style: const TextStyle(height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionManagerSection extends StatelessWidget {
  const _VersionManagerSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _LinkedReleaseRow extends StatelessWidget {
  const _LinkedReleaseRow({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final release = item['release'] == null
        ? <String, dynamic>{}
        : _asMap(item['release']);
    return Row(
      children: [
        Icon(
          item['is_current'] == true
              ? Icons.radio_button_checked
              : Icons.album_outlined,
          color: item['is_current'] == true
              ? tokens.accent
              : tokens.textSecondary,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                release['title']?.toString() ??
                    item['title']?.toString() ??
                    '-',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                _joinParts([
                  release['year'],
                  if (_intValue(item['disc_number']) != null)
                    '${_tr(context, 'Disc')} ${item['disc_number']}',
                  if (_intValue(item['track_number']) != null)
                    '#${item['track_number']}',
                  if (item['is_current'] == true) _tr(context, 'Current'),
                ]),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecordingCandidateRow extends StatelessWidget {
  const _RecordingCandidateRow({
    required this.candidate,
    required this.enabled,
    required this.onLink,
  });

  final Map<String, dynamic> candidate;
  final bool enabled;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final confidence = (candidate['confidence'] as num?)?.toDouble() ?? 0;
    final reasons = (candidate['reasons'] as List? ?? const [])
        .map((reason) => _candidateReasonLabel(context, reason.toString()))
        .toList(growable: false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Column(
            children: [
              Text(
                '${(confidence * 100).round()}%',
                style: TextStyle(
                  color: confidence >= 0.85
                      ? tokens.playing
                      : tokens.accentWarm,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                _tr(context, 'match'),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                candidate['album_title']?.toString() ??
                    candidate['title']?.toString() ??
                    '-',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                _joinParts([
                  candidate['artist_display'],
                  candidate['year'],
                  _formatDuration(candidate['duration_ms']),
                ]),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
              ),
              if (reasons.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: reasons
                      .map(
                        (reason) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: tokens.surfaceRaised,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            reason,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          onPressed: enabled ? onLink : null,
          child: Text(_tr(context, 'Link')),
        ),
      ],
    );
  }
}

String _candidateReasonLabel(BuildContext context, String reason) {
  return switch (reason) {
    'same_title' => _tr(context, 'same title'),
    'same_primary_artist' => _tr(context, 'same artist'),
    'duration_within_1s' => _tr(context, 'duration ±1s'),
    'duration_within_3s' => _tr(context, 'duration ±3s'),
    'duration_within_10s' => _tr(context, 'duration ±10s'),
    'same_recording_kind' => _tr(context, 'same recording type'),
    'already_linked' => _tr(context, 'already linked'),
    _ => reason,
  };
}
