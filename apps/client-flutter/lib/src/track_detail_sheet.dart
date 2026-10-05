part of '../intmusic_client.dart';

class _TrackInfoPage extends StatelessWidget {
  const _TrackInfoPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onClose,
    required this.onPlayTrack,
    required this.onOpenAlbum,
    required this.onOpenArtist,
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
  final Future<void> Function(String) onOpenArtist;
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
    final summary = _asMap(detail['track']);
    final track =
        _TrackActionScope.maybeOf(context)?.displayState?.project(summary) ??
        summary;
    final lyrics = detail['lyrics'] == null ? null : _asMap(detail['lyrics']);
    final genres = (detail['genres'] as List?) ?? const [];
    final composers = (detail['composers'] as List?) ?? const [];
    final lyricists = (detail['lyricists'] as List?) ?? const [];
    final media = detail['media'] == null ? null : _asMap(detail['media']);
    final trackId = _intValue(track['id']);
    final albumId = _intValue(track['album_id']);
    final artist = track['artist_display']?.toString().trim() ?? '';
    final album = track['album_title']?.toString().trim() ?? '';

    Widget overview() => Column(
      children: [
        _TrackSummaryCard(track: track, genres: genres),
        const SizedBox(height: 14),
        _TrackCreditsCard(
          artist: artist,
          composers: composers,
          lyricists: lyricists,
          onOpenArtist: onOpenArtist,
        ),
      ],
    );

    Widget details() => Column(
      children: [
        _TrackMediaOverview(
          coreBaseUrl: coreBaseUrl,
          detail: detail,
          media: media,
          onManage: onManageVersions,
        ),
        const SizedBox(height: 14),
        _TrackLyricsCard(lyrics: lyrics),
      ],
    );

    final hero = _TrackDetailHero(
      coreBaseUrl: coreBaseUrl,
      track: track,
      trackId: trackId,
      albumId: albumId,
      artist: artist,
      album: album,
      onPlayTrack: onPlayTrack,
      onOpenAlbum: onOpenAlbum,
      onOpenArtist: onOpenArtist,
      onToggleFavorite: onToggleFavorite,
      onAddToPlaylist: onAddToPlaylist,
      onEdit: onEdit,
      onClose: onClose,
    );

    return _PageFrame(
      title: 'Track detail',
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return ListView(
              key: const PageStorageKey('track-detail-mobile-scroll'),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                  child: hero,
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                  child: Column(
                    children: [
                      overview(),
                      const SizedBox(height: 14),
                      details(),
                    ],
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: hero,
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                  children: [
                    if (constraints.maxWidth >= 980)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 340, child: overview()),
                          const SizedBox(width: 18),
                          Expanded(child: details()),
                        ],
                      )
                    else ...[
                      overview(),
                      const SizedBox(height: 14),
                      details(),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TrackDetailHero extends StatelessWidget {
  const _TrackDetailHero({
    required this.coreBaseUrl,
    required this.track,
    required this.trackId,
    required this.albumId,
    required this.artist,
    required this.album,
    required this.onPlayTrack,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onToggleFavorite,
    required this.onAddToPlaylist,
    required this.onEdit,
    required this.onClose,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final int? trackId;
  final int? albumId;
  final String artist;
  final String album;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenAlbum;
  final Future<void> Function(String) onOpenArtist;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onAddToPlaylist;
  final Future<void> Function() onEdit;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final compactScreen = MediaQuery.sizeOf(context).width < 600;
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          track['title']?.toString() ?? _tr(context, 'Untitled'),
          maxLines: compactScreen ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style:
              (compactScreen
                      ? Theme.of(context).textTheme.titleLarge
                      : Theme.of(context).textTheme.headlineMedium)
                  ?.copyWith(fontWeight: FontWeight.w800, height: 1.08),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (artist.isNotEmpty)
              _TrackIdentityLink(
                icon: Icons.person_outline,
                label: artist,
                onPressed: () => unawaited(onOpenArtist(artist)),
              ),
            if (album.isNotEmpty)
              _TrackIdentityLink(
                icon: Icons.album_outlined,
                label: album,
                onPressed: albumId == null
                    ? null
                    : () => unawaited(onOpenAlbum(albumId!)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            if (_formatDuration(track['duration_ms']).isNotEmpty)
              _TrackMetaPill(
                icon: Icons.schedule,
                label: _formatDuration(track['duration_ms']),
              ),
            if (_intValue(track['year']) != null)
              _TrackMetaPill(
                icon: Icons.calendar_today_outlined,
                label: track['year'].toString(),
              ),
            if (_ratingLabel(track).isNotEmpty)
              _TrackMetaPill(
                icon: Icons.star_outline,
                label: _ratingLabel(track),
              ),
          ],
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: trackId == null
              ? null
              : () => unawaited(onPlayTrack(trackId!)),
          icon: const Icon(Icons.play_arrow),
          label: Text(_tr(context, 'Play')),
        ),
        _TrackActions(
          track: track,
          compact: compactScreen,
          onToggleFavorite: onToggleFavorite,
          onAddToPlaylist: trackId == null
              ? null
              : () => onAddToPlaylist(trackId!),
        ),
        OutlinedButton.icon(
          onPressed: trackId == null ? null : () => unawaited(onEdit()),
          icon: const Icon(Icons.edit_outlined),
          label: Text(_tr(context, 'Edit')),
        ),
        if (!compactScreen)
          _AppTooltip(
            message: _tr(context, 'Close'),
            child: IconButton.filledTonal(
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ),
      ],
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tokens.accent.withValues(alpha: 0.13),
            tokens.surface.withValues(alpha: 0.72),
          ],
        ),
        border: Border.all(color: tokens.stroke),
        borderRadius: BorderRadius.circular(tokens.radiusLarge),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final artwork = _ArtworkTile(
              title: track['title']?.toString() ?? '',
              subtitle: artist,
              size: constraints.maxWidth < 440
                  ? 92
                  : constraints.maxWidth < 600
                  ? 104
                  : 132,
              icon: Icons.music_note_outlined,
              imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
            );
            if (constraints.maxWidth < 720) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      artwork,
                      SizedBox(width: constraints.maxWidth < 440 ? 12 : 16),
                      Expanded(child: identity),
                    ],
                  ),
                  const SizedBox(height: 14),
                  actions,
                ],
              );
            }
            return Row(
              children: [
                artwork,
                const SizedBox(width: 20),
                Expanded(child: identity),
                const SizedBox(width: 18),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 370),
                  child: actions,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TrackIdentityLink extends StatelessWidget {
  const _TrackIdentityLink({
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 17),
      label: Text(label, overflow: TextOverflow.ellipsis),
      onPressed: onPressed,
      side: BorderSide(color: IntMusicTheme.of(context).stroke),
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

class _TrackSummaryCard extends StatelessWidget {
  const _TrackSummaryCard({required this.track, required this.genres});

  final Map<String, dynamic> track;
  final List<dynamic> genres;

  @override
  Widget build(BuildContext context) {
    final position = _joinParts([
      if (_intValue(track['disc_number']) != null)
        '${_tr(context, 'Disc')} ${track['disc_number']}',
      if (_intValue(track['track_number']) != null) '#${track['track_number']}',
    ]);
    return _HomePanel(
      title: _tr(context, 'At a glance'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TrackFactGrid(
            facts: [
              (
                Icons.schedule_outlined,
                _tr(context, 'Duration'),
                _formatDuration(track['duration_ms']).isEmpty
                    ? '—'
                    : _formatDuration(track['duration_ms']),
              ),
              (
                Icons.calendar_today_outlined,
                _tr(context, 'Year'),
                track['year']?.toString() ?? '—',
              ),
              (
                Icons.format_list_numbered,
                _tr(context, 'Position'),
                position.isEmpty ? '—' : position,
              ),
              (
                Icons.favorite_outline,
                _tr(context, 'Favorite'),
                track['is_favorite'] == true
                    ? _tr(context, 'Yes')
                    : _tr(context, 'No'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ActionChip(
            label: Text(songDisplayModeLabel(track['display_mode'])),
            avatar: const Icon(Icons.layers_outlined, size: 18),
            onPressed: () => unawaited(_showSongDisplay(context, track)),
          ),
          if (genres.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _tr(context, 'Genres'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 7),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: genres
                  .map((genre) => Chip(label: Text(genre.toString())))
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrackFactGrid extends StatelessWidget {
  const _TrackFactGrid({required this.facts});

  final List<(IconData, String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: facts
          .map(
            (fact) => SizedBox(
              width: 142,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.surfaceRaised.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tokens.stroke),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(fact.$1, size: 18, color: tokens.accent),
                      const SizedBox(height: 9),
                      Text(
                        fact.$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        fact.$2,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _TrackCreditsCard extends StatelessWidget {
  const _TrackCreditsCard({
    required this.artist,
    required this.composers,
    required this.lyricists,
    required this.onOpenArtist,
  });

  final String artist;
  final List<dynamic> composers;
  final List<dynamic> lyricists;
  final Future<void> Function(String) onOpenArtist;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: _tr(context, 'Credits'),
      child: Column(
        children: [
          if (artist.isNotEmpty)
            _CreditEntry(
              icon: Icons.mic_none_outlined,
              role: _tr(context, 'Artist'),
              names: <String>[artist],
              onPressed: (_) => unawaited(onOpenArtist(artist)),
            ),
          if (composers.isNotEmpty)
            _CreditEntry(
              icon: Icons.music_note_outlined,
              role: _tr(context, 'Composer'),
              names: composers.map((item) => item.toString()).toList(),
            ),
          if (lyricists.isNotEmpty)
            _CreditEntry(
              icon: Icons.edit_note_outlined,
              role: _tr(context, 'Lyricist'),
              names: lyricists.map((item) => item.toString()).toList(),
            ),
          if (artist.isEmpty && composers.isEmpty && lyricists.isEmpty)
            Text(_tr(context, 'No credits available')),
        ],
      ),
    );
  }
}

class _CreditEntry extends StatelessWidget {
  const _CreditEntry({
    required this.icon,
    required this.role,
    required this.names,
    this.onPressed,
  });

  final IconData icon;
  final String role;
  final List<String> names;
  final ValueChanged<String>? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: tokens.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  role,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: names
                      .map(
                        (name) => InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: onPressed == null
                              ? null
                              : () => onPressed!(name),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              name,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackMediaOverview extends StatefulWidget {
  const _TrackMediaOverview({
    required this.coreBaseUrl,
    required this.detail,
    required this.media,
    required this.onManage,
  });
  final String coreBaseUrl;
  final Map<String, dynamic> detail;
  final Map<String, dynamic>? media;
  final Future<void> Function() onManage;
  @override
  State<_TrackMediaOverview> createState() => _TrackMediaOverviewState();
}

class _TrackMediaOverviewState extends State<_TrackMediaOverview> {
  Timer? _timer;
  Map<String, dynamic>? _media;
  bool _connected = false;
  bool _refreshing = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _media = widget.media;
    unawaited(_refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void didUpdateWidget(covariant _TrackMediaOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail != widget.detail ||
        oldWidget.coreBaseUrl != widget.coreBaseUrl) {
      _generation++;
      _media = widget.media;
      _connected = false;
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = _intValue(_asMap(widget.detail['track'])['id']);
    if (_refreshing || id == null) return;
    _refreshing = true;
    final generation = _generation;
    try {
      final media = _asMap(
        await CoreApiClient(widget.coreBaseUrl).getJson('/tracks/$id/media'),
      );
      if (mounted && generation == _generation) {
        setState(() {
          _media = media;
          _connected = true;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _connected = false);
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final localCopy = widget.detail['_client_local_copy'];
    final groups = groupReleaseMedia(
      _media ?? const {},
      localCopy: localCopy is Map ? _asMap(localCopy) : null,
    );
    return _HomePanel(
      title: _tr(context, 'Album editions'),
      trailing: TextButton.icon(
        onPressed: () async {
          await widget.onManage();
          await _refresh();
        },
        icon: const Icon(Icons.link, size: 18),
        label: Text(_tr(context, 'Manage versions')),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (groups.isEmpty) Text(_tr(context, 'No linked release tracks')),
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _ReleaseMediaCard(group: groups[i], coreConnected: _connected),
          ],
        ],
      ),
    );
  }
}
