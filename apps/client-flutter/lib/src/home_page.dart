part of '../intmusic_client.dart';

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.store,
    required this.onEditCollection,
    required this.onOpenCollection,
    required this.onOpenEntity,
    required this.onPlayCollection,
    required this.onToggleFavorite,
    required this.coreBaseUrl,
    required this.status,
    required this.playback,
    required this.trackDetail,
    required this.zones,
    required this.stats,
    required this.history,
    required this.onNavigate,
    required this.onOpenTrack,
    required this.onPlayTrack,
  });
  final CollectionStore store;
  final Future<void> Function(int?) onEditCollection;
  final ValueChanged<int> onOpenCollection;
  final _CollectionOpen onOpenEntity;
  final _CollectionPlay onPlayCollection;
  final Future<void> Function(JsonMap) onToggleFavorite;
  final String coreBaseUrl;
  final Map<String, dynamic>? status, playback, trackDetail, stats;
  final List<dynamic> zones, history;
  final ValueChanged<int> onNavigate;
  final Future<void> Function(int) onOpenTrack, onPlayTrack;
  Widget _builtin(String name, String? title) {
    final counts = _collectionMap(status?['counts']);
    return switch (name) {
      'now_playing' => _HomeNowPlayingCard(
        title: title,
        coreBaseUrl: coreBaseUrl,
        playback: playback,
        trackDetail: trackDetail,
        onOpenPlayback: () => onNavigate(5),
      ),
      'library' => _HomeLibraryPanel(
        title: title,
        metrics: [
          ('Albums', counts['albums'] ?? 0, Icons.album_outlined),
          ('Artists', counts['artists'] ?? 0, Icons.person_outline),
          ('Tracks', counts['tracks'] ?? 0, Icons.music_note_outlined),
          ('Files', counts['files'] ?? 0, Icons.insert_drive_file_outlined),
        ],
        problems: _intValue(counts['scan_problems']) ?? 0,
        onOpenAlbums: () => onNavigate(1),
        onOpenTracks: () => onNavigate(3),
      ),
      'history' => _HomeRecentPanel(
        title: title,
        history: history,
        onOpenHistory: () => onNavigate(6),
        onOpenTrack: onOpenTrack,
        onPlayTrack: onPlayTrack,
      ),
      'devices' => _HomeDevicesPanel(
        title: title,
        zones: zones,
        onOpenPlayback: () => onNavigate(5),
      ),
      'stats' => _HomeStatsPanel(
        title: title,
        stats: stats,
        onOpenHistory: () => onNavigate(6),
      ),
      'core' => _HomeCorePanel(
        title: title,
        status: status,
        onOpenSettings: () => onNavigate(8),
      ),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => _PageFrame(
      title: 'Home',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Row(
              children: [
                if (!store.online)
                  const Expanded(child: Text('显示上次保存的首页内容'))
                else
                  const Spacer(),
                TextButton.icon(
                  onPressed: store.online
                      ? () => showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (c) => Dialog.fullscreen(
                            child: _HomeLayoutEditor(
                              store: store,
                              onEditCollection: onEditCollection,
                            ),
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: const Text('编辑首页'),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final sections = ((store.layout['sections'] as List?) ?? [])
                    .map(_asMap)
                    .where((s) => s['hidden'] != true)
                    .toList();
                final width = max(0.0, constraints.maxWidth - 40);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      if (sections.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            store.loading ? '正在读取首页…' : '首页还没有区块，可通过“编辑首页”添加。',
                          ),
                        ),
                      for (final section in sections)
                        SizedBox(
                          key: ValueKey(
                            '${store.identity}:${section['id']}:${section['collection_id']}',
                          ),
                          width:
                              constraints.maxWidth >= 1040 &&
                                  section['width'] == 'narrow'
                              ? (width - 16) / 2
                              : width,
                          child: section['builtin'] != null
                              ? _builtin(
                                  section['builtin'].toString(),
                                  section['title']?.toString(),
                                )
                              : _CollectionBlock(
                                  store: store,
                                  id: section['collection_id'] as int,
                                  section: section,
                                  coreBaseUrl: coreBaseUrl,
                                  onOpenEntity: onOpenEntity,
                                  onPlay: onPlayCollection,
                                  onToggleFavorite: onToggleFavorite,
                                  onEdit: onEditCollection,
                                  onOpenCollection: () => onOpenCollection(
                                    section['collection_id'] as int,
                                  ),
                                ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _HomePanel extends StatelessWidget {
  const _HomePanel({
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(tokens.radiusLarge),
        border: Border.all(color: tokens.stroke),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final heading = Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                );
                if (trailing != null && constraints.maxWidth < 420) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      heading,
                      const SizedBox(height: 8),
                      Align(alignment: Alignment.centerRight, child: trailing),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: heading),
                    if (trailing != null) ...[
                      const SizedBox(width: 12),
                      trailing!,
                    ],
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class _HomeNowPlayingCard extends StatelessWidget {
  const _HomeNowPlayingCard({
    this.title,
    required this.coreBaseUrl,
    required this.playback,
    required this.trackDetail,
    required this.onOpenPlayback,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? playback;
  final Map<String, dynamic>? trackDetail;
  final VoidCallback onOpenPlayback;

  final String? title;

  @override
  Widget build(BuildContext context) {
    final track = trackDetail == null ? null : _asMap(trackDetail!['track']);
    final title =
        track?['title']?.toString() ??
        playback?['track_title']?.toString() ??
        'Not playing';
    final artist = track?['artist_display']?.toString() ?? 'No active queue';
    final album = track?['album_title']?.toString();
    final state = playback?['state']?.toString() ?? 'stopped';
    final durationMs = _intValue(track?['duration_ms']) ?? 0;

    return _HomePanel(
      title: this.title ?? 'Now Playing',
      trailing: TextButton.icon(
        onPressed: onOpenPlayback,
        icon: const Icon(Icons.graphic_eq),
        label: const Text('Playback'),
      ),
      child: Row(
        children: [
          _ArtworkTile(
            title: title,
            subtitle: artist,
            size: 118,
            icon: Icons.album_outlined,
            imageUrl: _trackArtworkUrl(coreBaseUrl, playback?['track_id']),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _joinParts([artist, album, _formatDuration(durationMs)]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: Icon(_zoneStateIcon(state), size: 18),
                      label: Text(state),
                    ),
                    Chip(
                      avatar: const Icon(Icons.speaker_outlined, size: 18),
                      label: Text(playback?['zone_id']?.toString() ?? 'local'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeLibraryPanel extends StatelessWidget {
  const _HomeLibraryPanel({
    this.title,
    required this.metrics,
    required this.problems,
    required this.onOpenAlbums,
    required this.onOpenTracks,
  });

  final List<(String, Object, IconData)> metrics;
  final int problems;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenTracks;

  final String? title;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: title ?? 'Library',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onOpenAlbums, child: const Text('Albums')),
          TextButton(onPressed: onOpenTracks, child: const Text('Tracks')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: metrics
                .map(
                  (metric) => _MetricTile(
                    label: metric.$1,
                    value: metric.$2,
                    icon: metric.$3,
                  ),
                )
                .toList(growable: false),
          ),
          if (problems > 0) ...[
            const SizedBox(height: 12),
            Chip(
              avatar: const Icon(Icons.report_problem_outlined, size: 18),
              label: Text('$problems scan problems'),
            ),
          ],
        ],
      ),
    );
  }
}

class _HomeDevicesPanel extends StatelessWidget {
  const _HomeDevicesPanel({
    this.title,
    required this.zones,
    required this.onOpenPlayback,
  });

  final List<dynamic> zones;
  final VoidCallback onOpenPlayback;

  final String? title;

  @override
  Widget build(BuildContext context) {
    final zoneMaps = zones
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    final online = zoneMaps.where((zone) => zone['is_online'] != false).length;
    final playing = zoneMaps
        .where((zone) => zone['state']?.toString() == 'playing')
        .length;

    return _HomePanel(
      title: title ?? 'Devices',
      trailing: TextButton(
        onPressed: onOpenPlayback,
        child: const Text('Manage'),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _CompactStat(label: 'Online', value: '$online'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CompactStat(label: 'Playing', value: '$playing'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (zoneMaps.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('No playback zones'),
            )
          else
            for (final zone in zoneMaps.take(5)) _DeviceSummaryRow(zone: zone),
        ],
      ),
    );
  }
}

class _HomeStatsPanel extends StatelessWidget {
  const _HomeStatsPanel({
    this.title,
    required this.stats,
    required this.onOpenHistory,
  });

  final Map<String, dynamic>? stats;
  final VoidCallback onOpenHistory;

  final String? title;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: title ?? 'Listening',
      trailing: TextButton(
        onPressed: onOpenHistory,
        child: const Text('History'),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _CompactStat(
                  label: 'Sessions',
                  value: '${stats?['total_sessions'] ?? 0}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CompactStat(
                  label: 'Played',
                  value: _formatDuration(stats?['total_played_ms']).isEmpty
                      ? '0:00'
                      : _formatDuration(stats?['total_played_ms']),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CompactStat(
            label: 'Interrupted sessions',
            value: '${stats?['interrupted_sessions'] ?? 0}',
          ),
        ],
      ),
    );
  }
}

class _HomeRecentPanel extends StatelessWidget {
  const _HomeRecentPanel({
    this.title,
    required this.history,
    required this.onOpenHistory,
    required this.onOpenTrack,
    required this.onPlayTrack,
  });

  final List<dynamic> history;
  final VoidCallback onOpenHistory;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onPlayTrack;

  final String? title;

  @override
  Widget build(BuildContext context) {
    final events = _displayHistoryEvents(context, history)
        .map((item) => (item as Map).cast<String, dynamic>())
        .take(6)
        .toList(growable: false);

    return _HomePanel(
      title: title ?? 'Recent Activity',
      trailing: TextButton(onPressed: onOpenHistory, child: const Text('All')),
      padding: EdgeInsets.zero,
      child: events.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No playback events'),
            )
          : Column(
              children: [
                for (var index = 0; index < events.length; index++) ...[
                  _RecentEventRow(
                    event: events[index],
                    onOpenTrack: onOpenTrack,
                    onPlayTrack: onPlayTrack,
                  ),
                  if (index != events.length - 1) const Divider(height: 1),
                ],
              ],
            ),
    );
  }
}

class _HomeCorePanel extends StatelessWidget {
  const _HomeCorePanel({
    this.title,
    required this.status,
    required this.onOpenSettings,
  });

  final Map<String, dynamic>? status;
  final VoidCallback onOpenSettings;

  final String? title;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: title ?? 'Core',
      trailing: TextButton(
        onPressed: onOpenSettings,
        child: const Text('Settings'),
      ),
      child: Column(
        children: [
          _InfoRow(
            label: 'Version',
            value: status?['version']?.toString() ?? '-',
          ),
          _InfoRow(
            label: 'API',
            value: status?['api_version']?.toString() ?? '-',
          ),
          _InfoRow(
            label: 'Database',
            value: status?['database_path']?.toString() ?? '-',
          ),
        ],
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  const _CompactStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: IntMusicTheme.of(context).stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 5),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _DeviceSummaryRow extends StatelessWidget {
  const _DeviceSummaryRow({required this.zone});

  final Map<String, dynamic> zone;

  @override
  Widget build(BuildContext context) {
    final state = zone['state']?.toString() ?? 'stopped';
    final online = zone['is_online'] != false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(
            _zoneStateIcon(state),
            size: 20,
            color: state == 'playing'
                ? IntMusicTheme.of(context).playing
                : IntMusicTheme.of(context).textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  zone['name']?.toString() ??
                      zone['id']?.toString() ??
                      'Output',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _joinParts([online ? 'online' : 'offline', state]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
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

class _RecentEventRow extends StatelessWidget {
  const _RecentEventRow({
    required this.event,
    this.onOpenTrack,
    this.onPlayTrack,
  });

  final Map<String, dynamic> event;
  final Future<void> Function(int)? onOpenTrack;
  final Future<void> Function(int)? onPlayTrack;

  @override
  Widget build(BuildContext context) {
    final members = event['_display_members'];
    if (members is List) {
      return ExpansionTile(
        title: Text(
          event['track_title']?.toString() ??
              event['title']?.toString() ??
              '歌曲',
        ),
        subtitle: Text('${members.length} 条播放记录'),
        children: [
          for (final value in members)
            _RecentEventRow(
              event: Map<String, dynamic>.from(value as Map),
              onOpenTrack: onOpenTrack,
              onPlayTrack: onPlayTrack,
            ),
        ],
      );
    }
    final trackId = _intValue(event['track_id']);
    return _SimpleListRow(
      leading: Icon(_historyEventIcon(event['event_type']), size: 20),
      title: _joinParts([
        event['track_title'] ?? 'Track ${event['track_id']}',
        event['event_type'],
      ]),
      subtitle: _joinParts([
        event['zone_id'],
        _formatDuration(event['position_ms']),
        event['created_at'],
      ]),
      trailing: trackId == null || onPlayTrack == null
          ? null
          : IconButton(
              tooltip: _tr(context, 'Play'),
              onPressed: () => unawaited(onPlayTrack!(trackId)),
              icon: const Icon(Icons.play_arrow),
            ),
      onTap: trackId == null || onOpenTrack == null
          ? null
          : () => unawaited(onOpenTrack!(trackId)),
    );
  }
}

class _TopTrackRow extends StatelessWidget {
  const _TopTrackRow({
    required this.coreBaseUrl,
    required this.track,
    required this.rank,
    this.onOpenTrack,
    this.onPlayTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final int rank;
  final Future<void> Function(int)? onOpenTrack;
  final Future<void> Function(int)? onPlayTrack;

  @override
  Widget build(BuildContext context) {
    final title = track['title']?.toString() ?? 'Untitled';
    final artist = track['artist_display']?.toString() ?? 'Unknown Artist';
    final trackId = _intValue(track['id']);
    return _SimpleListRow(
      leading: SizedBox(
        width: 32,
        child: Text(
          '$rank',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: IntMusicTheme.of(context).textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: title,
      subtitle: _joinParts([
        artist,
        track['album_title'],
        '${track['play_count'] ?? 0} plays',
        _formatDuration(track['total_played_ms']),
      ]),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (track['_display_members'] is List) _SongGroupButton(track: track),
          _ArtworkTile(
            title: title,
            subtitle: artist,
            size: 38,
            icon: Icons.music_note_outlined,
            imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
          ),
          if (trackId != null && onPlayTrack != null)
            IconButton(
              tooltip: _tr(context, 'Play'),
              onPressed: () => unawaited(onPlayTrack!(trackId)),
              icon: const Icon(Icons.play_arrow),
            ),
        ],
      ),
      onTap: trackId == null || onOpenTrack == null
          ? null
          : () => unawaited(onOpenTrack!(trackId)),
    );
  }
}
