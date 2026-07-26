part of '../intmusic_client.dart';

class _HistoryPage extends StatelessWidget {
  const _HistoryPage({
    required this.coreBaseUrl,
    required this.stats,
    required this.events,
    required this.onOpenTrack,
    required this.onPlayTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? stats;
  final List<dynamic> events;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(int) onPlayTrack;

  @override
  Widget build(BuildContext context) {
    final topTracks = (stats?['top_tracks'] as List?) ?? const [];
    final eventMaps = events
        .map((item) => (item as Map).cast<String, dynamic>())
        .take(100)
        .toList(growable: false);
    final metrics = <(String, Object, IconData)>[
      ('Sessions', stats?['total_sessions'] ?? 0, Icons.playlist_play_outlined),
      ('Events', stats?['total_events'] ?? 0, Icons.timeline_outlined),
      (
        'Played',
        _formatDuration(stats?['total_played_ms']),
        Icons.schedule_outlined,
      ),
      (
        'Interrupted',
        stats?['interrupted_sessions'] ?? 0,
        Icons.call_split_outlined,
      ),
    ];

    return _PageFrame(
      title: 'History',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
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
          const SizedBox(height: 16),
          _HomePanel(
            title: 'Top Tracks',
            padding: EdgeInsets.zero,
            child: topTracks.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No playback stats'),
                  )
                : Column(
                    children: [
                      for (
                        var index = 0;
                        index < topTracks.take(20).length;
                        index++
                      ) ...[
                        _TopTrackRow(
                          coreBaseUrl: coreBaseUrl,
                          track: (topTracks[index] as Map)
                              .cast<String, dynamic>(),
                          rank: index + 1,
                          onOpenTrack: onOpenTrack,
                          onPlayTrack: onPlayTrack,
                        ),
                        if (index != topTracks.take(20).length - 1)
                          const Divider(height: 1),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          _HomePanel(
            title: 'Recent Events',
            padding: EdgeInsets.zero,
            child: eventMaps.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No playback events'),
                  )
                : Column(
                    children: [
                      for (
                        var index = 0;
                        index < eventMaps.length;
                        index++
                      ) ...[
                        _RecentEventRow(
                          event: eventMaps[index],
                          onOpenTrack: onOpenTrack,
                          onPlayTrack: onPlayTrack,
                        ),
                        if (index != eventMaps.length - 1)
                          const Divider(height: 1),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
