part of '../main.dart';

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.coreBaseUrl,
    required this.status,
    required this.playback,
    required this.trackDetail,
    required this.zones,
    required this.stats,
    required this.history,
    required this.onNavigate,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? status;
  final Map<String, dynamic>? playback;
  final Map<String, dynamic>? trackDetail;
  final List<dynamic> zones;
  final Map<String, dynamic>? stats;
  final List<dynamic> history;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final counts =
        (status?['counts'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final metrics = <(String, Object, IconData)>[
      ('Albums', counts['albums'] ?? 0, Icons.album_outlined),
      ('Artists', counts['artists'] ?? 0, Icons.person_outline),
      ('Tracks', counts['tracks'] ?? 0, Icons.music_note_outlined),
      ('Files', counts['files'] ?? 0, Icons.insert_drive_file_outlined),
    ];
    final problems = _intValue(counts['scan_problems']) ?? 0;

    return _PageFrame(
      title: 'Home',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1040;
          final mainColumn = Column(
            children: [
              _HomeNowPlayingCard(
                coreBaseUrl: coreBaseUrl,
                playback: playback,
                trackDetail: trackDetail,
                onOpenPlayback: () => onNavigate(5),
              ),
              const SizedBox(height: 14),
              _HomeLibraryPanel(
                metrics: metrics,
                problems: problems,
                onOpenAlbums: () => onNavigate(1),
                onOpenTracks: () => onNavigate(3),
              ),
              const SizedBox(height: 14),
              _HomeRecentPanel(
                history: history,
                onOpenHistory: () => onNavigate(6),
              ),
            ],
          );
          final sideColumn = Column(
            children: [
              _HomeDevicesPanel(
                zones: zones,
                onOpenPlayback: () => onNavigate(5),
              ),
              const SizedBox(height: 14),
              _HomeStatsPanel(stats: stats, onOpenHistory: () => onNavigate(6)),
              const SizedBox(height: 14),
              _HomeCorePanel(
                status: status,
                onOpenSettings: () => onNavigate(7),
              ),
            ],
          );

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: mainColumn),
                      const SizedBox(width: 18),
                      Expanded(flex: 4, child: sideColumn),
                    ],
                  )
                : Column(
                    children: [
                      mainColumn,
                      const SizedBox(height: 14),
                      sideColumn,
                    ],
                  ),
          );
        },
      ),
    );
  }
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: appSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
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
    required this.coreBaseUrl,
    required this.playback,
    required this.trackDetail,
    required this.onOpenPlayback,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? playback;
  final Map<String, dynamic>? trackDetail;
  final VoidCallback onOpenPlayback;

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
      title: 'Now Playing',
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
                    color: const Color(0xffa8afb8),
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
    required this.metrics,
    required this.problems,
    required this.onOpenAlbums,
    required this.onOpenTracks,
  });

  final List<(String, Object, IconData)> metrics;
  final int problems;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenTracks;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: 'Library',
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
  const _HomeDevicesPanel({required this.zones, required this.onOpenPlayback});

  final List<dynamic> zones;
  final VoidCallback onOpenPlayback;

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
      title: 'Devices',
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
  const _HomeStatsPanel({required this.stats, required this.onOpenHistory});

  final Map<String, dynamic>? stats;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: 'Listening',
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
  const _HomeRecentPanel({required this.history, required this.onOpenHistory});

  final List<dynamic> history;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final events = history
        .map((item) => (item as Map).cast<String, dynamic>())
        .take(6)
        .toList(growable: false);

    return _HomePanel(
      title: 'Recent Activity',
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
                  _RecentEventRow(event: events[index]),
                  if (index != events.length - 1) const Divider(height: 1),
                ],
              ],
            ),
    );
  }
}

class _HomeCorePanel extends StatelessWidget {
  const _HomeCorePanel({required this.status, required this.onOpenSettings});

  final Map<String, dynamic>? status;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: 'Core',
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
        color: appSurfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: const Color(0xff9aa1ab)),
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
            color: state == 'playing' ? appPlaying : const Color(0xffb8bec7),
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
                    color: const Color(0xff9aa1ab),
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
  const _RecentEventRow({required this.event});

  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Icon(_historyEventIcon(event['event_type']), size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _joinParts([
                    event['track_title'] ?? 'Track ${event['track_id']}',
                    event['event_type'],
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _joinParts([
                    event['zone_id'],
                    _formatDuration(event['position_ms']),
                    event['created_at'],
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xff9aa1ab),
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

class _TopTrackRow extends StatelessWidget {
  const _TopTrackRow({
    required this.coreBaseUrl,
    required this.track,
    required this.rank,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> track;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final title = track['title']?.toString() ?? 'Untitled';
    final artist = track['artist_display']?.toString() ?? 'Unknown Artist';
    return _SimpleListRow(
      leading: SizedBox(
        width: 32,
        child: Text(
          '$rank',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: const Color(0xff9aa1ab),
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
      trailing: _ArtworkTile(
        title: title,
        subtitle: artist,
        size: 38,
        icon: Icons.music_note_outlined,
        imageUrl: _trackArtworkUrl(coreBaseUrl, track['id']),
      ),
    );
  }
}
