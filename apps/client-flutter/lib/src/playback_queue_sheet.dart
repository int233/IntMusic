part of '../intmusic_client.dart';

class _QueueSheet extends StatefulWidget {
  const _QueueSheet({
    required this.coreBaseUrl,
    required this.items,
    required this.currentIndex,
    required this.onPlayTrack,
    required this.onMove,
    required this.onRemove,
    required this.onClearUpcoming,
    required this.onClearAll,
  });

  final String coreBaseUrl;
  final List<Map<String, dynamic>> items;
  final int? currentIndex;
  final Future<void> Function(int) onPlayTrack;
  final Future<Map<String, dynamic>?> Function(int, int) onMove;
  final Future<Map<String, dynamic>?> Function(int) onRemove;
  final Future<Map<String, dynamic>?> Function() onClearUpcoming;
  final Future<Map<String, dynamic>?> Function() onClearAll;

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  static const _rowExtent = 72.0;

  late List<Map<String, dynamic>> _items = widget.items;
  late int? _currentIndex = widget.currentIndex;
  late final ScrollController _scrollController;
  bool _mutating = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: max(0, (widget.currentIndex ?? 0) - 2) * _rowExtent,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _applyQueue(Map<String, dynamic> queue) {
    _items = ((queue['items'] as List?) ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    _currentIndex = _intValue(queue['current_index']);
  }

  Future<void> _move(int oldIndex, int newIndex) async {
    if (_mutating || oldIndex == newIndex) {
      return;
    }
    setState(() => _mutating = true);
    final queue = await widget.onMove(oldIndex, newIndex);
    if (!mounted) {
      return;
    }
    setState(() {
      if (queue != null) {
        _applyQueue(queue);
      }
      _mutating = false;
    });
  }

  Future<void> _remove(int itemId) async {
    if (_mutating) {
      return;
    }
    setState(() => _mutating = true);
    final queue = await widget.onRemove(itemId);
    if (!mounted) {
      return;
    }
    setState(() {
      if (queue != null) {
        _applyQueue(queue);
      }
      _mutating = false;
    });
  }

  Future<void> _clear({required bool all}) async {
    if (_mutating) {
      return;
    }
    setState(() => _mutating = true);
    final queue = await (all ? widget.onClearAll() : widget.onClearUpcoming());
    if (!mounted) {
      return;
    }
    setState(() {
      if (queue != null) {
        _applyQueue(queue);
      }
      _mutating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    return SizedBox(
      height: min(520, MediaQuery.sizeOf(context).height * 0.72),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 10 : 18,
          0,
          compact ? 10 : 18,
          12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tr(context, 'Queue'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (compact)
                  _AppTooltip(
                    message: _tr(context, 'Clear upcoming'),
                    child: IconButton(
                      onPressed: _mutating || _items.isEmpty
                          ? null
                          : () => unawaited(_clear(all: false)),
                      icon: const Icon(Icons.playlist_remove_rounded),
                    ),
                  )
                else
                  TextButton(
                    onPressed: _mutating || _items.isEmpty
                        ? null
                        : () => unawaited(_clear(all: false)),
                    child: Text(_tr(context, 'Clear upcoming')),
                  ),
                PopupMenuButton<bool>(
                  enabled: !_mutating && _items.isNotEmpty,
                  tooltip: _tr(context, 'More'),
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (all) => unawaited(_clear(all: all)),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: true,
                      child: ListTile(
                        leading: const Icon(Icons.delete_sweep_outlined),
                        title: Text(_tr(context, 'Clear all')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _tr(context, 'Drag to reorder. Queue is synced across devices.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _items.isEmpty
                  ? Center(child: Text(_tr(context, 'No upcoming tracks')))
                  : ReorderableListView.builder(
                      scrollController: _scrollController,
                      itemExtent: _rowExtent,
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) =>
                          unawaited(_move(oldIndex, newIndex)),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final itemId = _intValue(item['id']);
                        final track = (item['track'] as Map)
                            .cast<String, dynamic>();
                        final id = _intValue(track['id']);
                        final title = track['title']?.toString() ?? 'Untitled';
                        final artist =
                            track['artist_display']?.toString() ?? '';
                        final isCurrent = _currentIndex == index;
                        final subtitle = _joinParts([
                          isCurrent ? _tr(context, 'Now playing') : artist,
                          track['album_title'],
                          _formatDuration(track['duration_ms']),
                        ]);
                        final leading = SizedBox(
                          width: 42,
                          child: isCurrent
                              ? Icon(
                                  Icons.graphic_eq_rounded,
                                  color: IntMusicTheme.of(context).playing,
                                )
                              : _ArtworkTile(
                                  title: title,
                                  subtitle: artist,
                                  size: 42,
                                  icon: Icons.music_note_outlined,
                                  imageUrl: _trackArtworkUrl(
                                    widget.coreBaseUrl,
                                    id,
                                  ),
                                ),
                        );
                        final remove = IconButton(
                          onPressed: itemId == null || _mutating
                              ? null
                              : () => unawaited(_remove(itemId)),
                          icon: const Icon(Icons.close_rounded, size: 18),
                          tooltip: _tr(context, 'Remove from queue'),
                        );
                        final drag = ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.drag_handle_rounded),
                          ),
                        );
                        return Container(
                          key: ValueKey(itemId ?? 'queue-$index-$id'),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? IntMusicTheme.of(
                                    context,
                                  ).accent.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: compact
                              ? Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: id == null
                                        ? null
                                        : () =>
                                              unawaited(widget.onPlayTrack(id)),
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: Row(
                                        children: [
                                          leading,
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyLarge
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                                const SizedBox(height: 3),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        subtitle,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color:
                                                                  IntMusicTheme.of(
                                                                    context,
                                                                  ).textSecondary,
                                                            ),
                                                      ),
                                                    ),
                                                    if (track['_availability']
                                                        is Map) ...[
                                                      const SizedBox(width: 5),
                                                      _TrackAvailabilityBadge(
                                                        track: track,
                                                        compact: true,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          remove,
                                          drag,
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                              : _SimpleListRow(
                                  leading: leading,
                                  title: title,
                                  subtitle: subtitle,
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _TrackAvailabilityBadge(
                                        track: track,
                                        compact: true,
                                      ),
                                      const SizedBox(width: 4),
                                      remove,
                                      drag,
                                    ],
                                  ),
                                  onTap: id == null
                                      ? null
                                      : () => unawaited(widget.onPlayTrack(id)),
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
}
