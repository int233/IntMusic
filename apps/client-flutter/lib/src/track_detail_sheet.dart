part of '../intmusic_client.dart';

class _TrackInfoPage extends StatelessWidget {
  const _TrackInfoPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onClose,
    required this.onPlayTrack,
    required this.onOpenTrack,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
    required this.onEdit,
    required this.onManageVersions,
    this.loadMedia,
    this.coreOnline = false,
  });
  final bool coreOnline;
  final Future<Map<String, dynamic>> Function(int)? loadMedia;
  final String coreBaseUrl;
  final Map<String, dynamic>? detail;
  final VoidCallback onClose;
  final Future<void> Function(int) onPlayTrack,
      onOpenTrack,
      onOpenAlbum,
      onAddToPlaylist;
  final Future<void> Function(String) onOpenArtist;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function() onEdit, onManageVersions;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final scope = _TrackActionScope.maybeOf(context);
    final summary = _asMap(detail['track']);
    final track = scope?.displayState?.project(summary) ?? summary;
    final editions = songDetailEditions(track, scope?.catalogTracks ?? []);
    final lyrics = detail['lyrics'] is Map ? _asMap(detail['lyrics']) : null;
    final hero = _SongDetailHero(
      coreBaseUrl: coreBaseUrl,
      track: track,
      genres: (detail['genres'] as List?)?.isNotEmpty == true
          ? detail['genres'] as List
          : (track['genres'] as List?) ?? [],
      onPlay: () => onPlayTrack(_intValue(track['id'])!),
      onAlbum: () async {
        final id = _intValue(track['album_id']);
        if (id != null) await onOpenAlbum(id);
      },
      onArtist: () => onOpenArtist(track['artist_display']?.toString() ?? ''),
      onFavorite: () => onToggleFavorite(track),
      onAdd: () => onAddToPlaylist(_intValue(track['id'])!),
      onEdit: onEdit,
      onClose: onClose,
    );
    final releases = _SongEditionsPanel(
      coreBaseUrl: coreBaseUrl,
      detail: detail,
      editions: editions,
      onOpenTrack: onOpenTrack,
      onPlayTrack: onPlayTrack,
      onManage: onManageVersions,
      loadMedia: loadMedia,
      coreOnline: coreOnline,
    );
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TrackLyricsCard(
          key: ValueKey('lyrics-${track['id']}'),
          lyrics: lyrics,
          album: track['album_title']?.toString() ?? '',
        ),
        const SizedBox(height: 16),
        _SongDetailPanel(
          title: '参与人员',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _credit(context, '演唱', [track['artist_display']]),
              if ((detail['composers'] as List? ?? []).isNotEmpty)
                _credit(context, '作曲', detail['composers'] as List),
              if ((detail['lyricists'] as List? ?? []).isNotEmpty)
                _credit(context, '作词', detail['lyricists'] as List),
            ],
          ),
        ),
      ],
    );
    return _PageFrame(
      title: 'Track detail',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1000;
          final narrow = constraints.maxWidth < 600;
          return ListView(
            key: PageStorageKey(
              narrow ? 'track-detail-mobile-scroll' : 'song-detail-scroll',
            ),
            padding: EdgeInsets.fromLTRB(
              narrow ? 12 : 24,
              12,
              narrow ? 12 : 24,
              32,
            ),
            children: [
              hero,
              const SizedBox(height: 24),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: releases),
                    const SizedBox(width: 18),
                    Expanded(flex: 2, child: words),
                  ],
                )
              else ...[
                releases,
                const SizedBox(height: 18),
                words,
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _credit(BuildContext context, String label, List<dynamic> names) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: IntMusicTheme.of(context).textSecondary),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(names.where((n) => n != null).join('、'))),
          ],
        ),
      );
}

class _SongDetailHero extends StatelessWidget {
  const _SongDetailHero({
    required this.coreBaseUrl,
    required this.track,
    required this.genres,
    required this.onPlay,
    required this.onAlbum,
    required this.onArtist,
    required this.onFavorite,
    required this.onAdd,
    required this.onEdit,
    required this.onClose,
  });
  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final List<dynamic> genres;
  final Future<void> Function() onPlay,
      onAlbum,
      onArtist,
      onFavorite,
      onAdd,
      onEdit;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final small = constraints.maxWidth < 600;
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              track['title']?.toString() ?? '',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style:
                  (small
                          ? Theme.of(context).textTheme.titleLarge
                          : Theme.of(context).textTheme.headlineLarge)
                      ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: onArtist,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  track['artist_display']?.toString() ?? '',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: onAlbum,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '当前收录 · ${track['album_title'] ?? '未知专辑'}',
                  style: TextStyle(color: tokens.accent),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _joinParts([
                track['year'],
                _formatDuration(track['duration_ms']),
                if (track['disc_number'] != null) '光盘 ${track['disc_number']}',
                if (track['track_number'] != null)
                  '第 ${track['track_number']} 首',
              ]),
              style: TextStyle(color: tokens.textSecondary, fontSize: 13),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow),
              label: const Text('播放'),
            ),
            IconButton(
              onPressed: onFavorite,
              tooltip: track['is_favorite'] == true ? '取消收藏当前收录' : '收藏当前收录',
              icon: Icon(
                track['is_favorite'] == true
                    ? Icons.favorite
                    : Icons.favorite_border,
                color: tokens.accent,
              ),
            ),
            OutlinedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.playlist_add),
              label: const Text('加入集合'),
            ),
            PopupMenuButton<String>(
              tooltip: '歌曲操作',
              onSelected: (value) {
                if (value == 'edit') {
                  unawaited(onEdit());
                } else {
                  onClose();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑当前收录')),
                PopupMenuItem(value: 'close', child: Text('关闭详情')),
              ],
            ),
          ],
        );
        final artwork = _ArtworkTile(
          title: track['title']?.toString() ?? '',
          subtitle: '',
          size: small ? (constraints.maxWidth < 320 ? 64 : 92) : 170,
          icon: Icons.music_note_outlined,
          imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
        );
        final tags = Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final genre in genres)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(genre.toString()),
              ),
            if (_ratingLabel(track).isNotEmpty)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.star_outline, size: 16),
                label: Text(_ratingLabel(track)),
              ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                artwork,
                SizedBox(width: small ? 12 : 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      if (!small) ...[const SizedBox(height: 8), tags],
                    ],
                  ),
                ),
                if (constraints.maxWidth >= 1200) ...[
                  const SizedBox(width: 20),
                  SizedBox(width: 340, child: actions),
                ],
              ],
            ),
            if (small) ...[const SizedBox(height: 8), tags],
            if (constraints.maxWidth < 1200) ...[
              const SizedBox(height: 14),
              actions,
            ],
          ],
        );
      },
    );
  }
}

/// Flat panels keep the detail screen readable without nested shadows/blur.
class _SongDetailPanel extends StatelessWidget {
  const _SongDetailPanel({
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tokens.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _TrackMetaPill extends StatelessWidget {
  const _TrackMetaPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised.withValues(alpha: 0.76),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: tokens.textSecondary),
            const SizedBox(width: 5),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
