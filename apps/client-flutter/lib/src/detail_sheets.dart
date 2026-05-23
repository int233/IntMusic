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
    return _PageFrame(
      title: 'Album detail',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
            child: Row(
              children: [
                Expanded(
                  child: _DetailHeader(
                    icon: Icons.album_outlined,
                    title: album['title']?.toString() ?? 'Untitled',
                    subtitle: _joinParts([
                      album['album_artist_display'],
                      album['year'],
                      '${album['track_count'] ?? tracks.length} tracks',
                    ]),
                    imageUrl: _albumArtworkUrl(coreBaseUrl, album['id']),
                  ),
                ),
                _AppTooltip(
                  message: _tr(context, 'Close'),
                  child: IconButton.filledTonal(
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: tracks.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final track = (tracks[index] as Map).cast<String, dynamic>();
                final id = _intValue(track['id']);
                return _SheetTrackRow(
                  coreBaseUrl: coreBaseUrl,
                  track: track,
                  indexLabel: _trackNumber(track),
                  subtitle: _joinParts([
                    track['artist_display'],
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
          ),
        ],
      ),
    );
  }
}

class _ArtistInfoPage extends StatelessWidget {
  const _ArtistInfoPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onClose,
    required this.onOpenAlbum,
    required this.onPlayTrack,
    required this.onOpenTrack,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? detail;
  final VoidCallback onClose;
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
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
        children: [
          Row(
            children: [
              Expanded(
                child: _DetailHeader(
                  icon: Icons.person_outline,
                  title: artist['name']?.toString() ?? 'Unknown Artist',
                  subtitle: '${albums.length} albums - ${tracks.length} tracks',
                ),
              ),
              _AppTooltip(
                message: _tr(context, 'Close'),
                child: IconButton.filledTonal(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            _tr(context, 'Albums'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 190,
            child: albums.isEmpty
                ? Center(child: Text(_tr(context, 'No albums')))
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: albums.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final album = (albums[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(album['id']);
                      return SizedBox(
                        width: 132,
                        child: InkWell(
                          onTap: id == null
                              ? null
                              : () => unawaited(onOpenAlbum(id)),
                          borderRadius: BorderRadius.circular(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ArtworkTile(
                                title: album['title']?.toString() ?? 'Untitled',
                                subtitle:
                                    album['album_artist_display']?.toString() ??
                                    '',
                                size: 120,
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
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? detail;
  final VoidCallback onClose;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;

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
                    border: Border.all(color: const Color(0xff2a3238)),
                    borderRadius: BorderRadius.circular(8),
                    color: const Color(0xff12171b),
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
