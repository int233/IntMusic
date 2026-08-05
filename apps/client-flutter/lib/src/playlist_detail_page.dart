part of '../intmusic_client.dart';

class _PlaylistDetailPage extends StatefulWidget {
  const _PlaylistDetailPage({
    super.key,
    required this.coreBaseUrl,
    required this.detail,
    required this.initialScrollOffset,
    required this.onScrollOffsetChanged,
    required this.onPlayTrack,
    required this.onOpenTrack,
    required this.onToggleFavorite,
    required this.onEditSmart,
    required this.onRemoveTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> detail;
  final double initialScrollOffset;
  final ValueChanged<double> onScrollOffsetChanged;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function() onEditSmart;
  final Future<void> Function(int) onRemoveTrack;

  @override
  State<_PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<_PlaylistDetailPage> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: max(0, widget.initialScrollOffset),
    )..addListener(_saveScrollOffset);
  }

  void _saveScrollOffset() {
    if (_scrollController.hasClients) {
      widget.onScrollOffsetChanged(_scrollController.offset);
    }
  }

  @override
  void dispose() {
    _saveScrollOffset();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _asMap(widget.detail['playlist']);
    final tracks = (widget.detail['tracks'] as List?) ?? const [];
    final kind = playlist['kind']?.toString() ?? 'manual';
    final rules = widget.detail['rules'];
    final compact = MediaQuery.sizeOf(context).width < 600;
    final horizontalPadding = compact ? 14.0 : 24.0;
    final heading = Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 4, horizontalPadding, 12),
      child: _ResponsiveDetailHeading(
        header: _DetailHeader(
          icon: kind == 'smart'
              ? Icons.auto_awesome_motion_outlined
              : Icons.queue_music_outlined,
          title: playlist['name']?.toString() ?? 'Untitled',
          subtitle: _joinParts([
            kind,
            '${playlist['track_count'] ?? tracks.length} tracks',
            playlist['description'],
          ]),
        ),
        actions: _CollectionActions(tracks: tracks),
      ),
    );
    final ruleSummary = kind != 'smart'
        ? null
        : Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              12,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final label = Text(
                  _smartRulesLabel(rules),
                  maxLines: compact ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                );
                final button = OutlinedButton.icon(
                  onPressed: () => unawaited(widget.onEditSmart()),
                  icon: const Icon(Icons.tune_outlined),
                  label: Text(_tr(context, 'Edit rules')),
                );
                if (constraints.maxWidth < 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      label,
                      const SizedBox(height: 10),
                      Align(alignment: Alignment.centerRight, child: button),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 12),
                    button,
                  ],
                );
              },
            ),
          );

    Widget trackRow(int index) {
      final track = (tracks[index] as Map).cast<String, dynamic>();
      final id = _intValue(track['id']);
      return _SheetTrackRow(
        coreBaseUrl: widget.coreBaseUrl,
        track: track,
        indexLabel: '${index + 1}',
        subtitle: _joinParts([
          track['artist_display'],
          track['album_title'],
          _formatDuration(track['duration_ms']),
        ]),
        onOpen: id == null ? null : () => unawaited(widget.onOpenTrack(id)),
        onPlay: id == null ? null : () => unawaited(widget.onPlayTrack(id)),
        onToggleFavorite: widget.onToggleFavorite,
        onRemove: kind == 'manual' && id != null
            ? () => unawaited(widget.onRemoveTrack(id))
            : null,
      );
    }

    return _PageFrame(
      title: 'Playlist detail',
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 600) {
            return CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [heading, ?ruleSummary, const Divider(height: 1)],
                  ),
                ),
                if (tracks.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: Text('No matching tracks')),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    sliver: SliverList.builder(
                      itemCount: tracks.length,
                      itemBuilder: (context, index) => Column(
                        children: [
                          trackRow(index),
                          if (index != tracks.length - 1)
                            const Divider(height: 1),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              ?ruleSummary,
              const Divider(height: 1),
              Expanded(
                child: tracks.isEmpty
                    ? const Center(child: Text('No matching tracks'))
                    : ListView.separated(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: tracks.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) => trackRow(index),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
