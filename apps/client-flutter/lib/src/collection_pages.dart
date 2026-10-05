part of '../intmusic_client.dart';

typedef _CollectionPlay = Future<void> Function(int, List<dynamic>, JsonMap?);
typedef _CollectionOpen = Future<void> Function(String, int);

class _CollectionsPage extends StatelessWidget {
  const _CollectionsPage({
    required this.store,
    required this.onOpen,
    required this.onEdit,
  });
  final CollectionStore store;
  final ValueChanged<int> onOpen;
  final Future<void> Function(int?) onEdit;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final user = store.items.where((i) => i['system_key'] == null).toList();
      final system = store.items.where((i) => i['system_key'] != null).toList();
      return _PageFrame(
        title: '集合',
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Expanded(child: Text('歌单、专辑、艺术家与流派，共用指定内容和自动筛选。')),
                  FilledButton.icon(
                    onPressed: store.online ? () => onEdit(null) : null,
                    icon: const Icon(Icons.add),
                    label: const Text('新建集合'),
                  ),
                ],
              ),
            ),
            if (!store.online)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('离线缓存：连接 Core 后可编辑'),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final item in user) _tile(context, item),
                  if (user.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('还没有集合。可以逐项添加，也可以设置自动筛选。'),
                    ),
                  if (store.settings['management_enabled'] == true) ...[
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('系统集合 · 始终保留'),
                    ),
                    for (final item in system) _tile(context, item),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget _tile(BuildContext context, JsonMap item) => ListTile(
    leading: Icon(_collectionIcon(item['entity_type']?.toString())),
    title: Text(item['name'].toString()),
    subtitle: Text(
      '${_collectionTypeName(item['entity_type']?.toString())} · ${item['result_total']} 项',
    ),
    onTap: () => onOpen(item['id'] as int),
    trailing: PopupMenuButton<String>(
      onSelected: (action) async {
        if (action == 'edit') {
          await onEdit(item['id'] as int);
        } else {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('删除“${item['name']}”？'),
              content: const Text('会同时移除关联的首页区块，音乐文件不受影响。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            try {
              await store.remove(item['id'] as int, item['revision'] as int);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(_collectionError(e))));
              }
            }
          }
        }
      },
      itemBuilder: (context) => [
        if (item['can_edit'] == true)
          const PopupMenuItem(value: 'edit', child: Text('编辑')),
        if (item['can_delete'] == true)
          const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    ),
  );
}

class _CollectionSettingsPanel extends StatefulWidget {
  const _CollectionSettingsPanel({required this.store, required this.onEdit});
  final CollectionStore store;
  final Future<void> Function(int?) onEdit;
  @override
  State<_CollectionSettingsPanel> createState() =>
      _CollectionSettingsPanelState();
}

class _CollectionSettingsPanelState extends State<_CollectionSettingsPanel> {
  String? _error;
  bool _busy = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _HomePanel(
      title: '系统集合',
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许管理系统集合'),
            subtitle: const Text('在集合中使用同一个编辑器调整系统规则。关闭后仍可浏览、播放、换一批和自定义首页。'),
            value: widget.store.settings['management_enabled'] == true,
            onChanged: _busy || !widget.store.online
                ? null
                : (v) async {
                    setState(() => _busy = true);
                    try {
                      await widget.store.setManagement(v);
                    } catch (e) {
                      if (mounted) setState(() => _error = _collectionError(e));
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
          if (_error != null) Text(_error!),
          if (widget.store.settings['management_enabled'] == true)
            for (final item in widget.store.items.where(
              (i) => i['system_key'] != null,
            ))
              ListTile(
                title: Text(item['name'].toString()),
                trailing: TextButton(
                  onPressed: () => widget.onEdit(item['id'] as int),
                  child: const Text('编辑'),
                ),
              ),
        ],
      ),
    ),
  );
}

class _CollectionBlock extends StatefulWidget {
  const _CollectionBlock({
    super.key,
    required this.store,
    required this.id,
    required this.coreBaseUrl,
    required this.onOpenEntity,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onEdit,
    this.onOpenCollection,
    this.section,
    this.fullPage = false,
  });
  final CollectionStore store;
  final int id;
  final String coreBaseUrl;
  final _CollectionOpen onOpenEntity;
  final _CollectionPlay onPlay;
  final Future<void> Function(JsonMap) onToggleFavorite;
  final Future<void> Function(int?) onEdit;
  final VoidCallback? onOpenCollection;
  final JsonMap? section;
  final bool fullPage;
  @override
  State<_CollectionBlock> createState() => _CollectionBlockState();
}

class _CollectionBlockState extends State<_CollectionBlock> {
  bool _loading = false, _playing = false, _selecting = false;
  String? _error;
  final Set<int> _selected = {};
  late int _count = widget.fullPage
      ? 50
      : _intValue(widget.section?['preview_count']) ?? 6;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _CollectionBlock old) {
    super.didUpdateWidget(old);
    final next = widget.fullPage
        ? _count
        : _intValue(widget.section?['preview_count']) ?? 6;
    if (old.id != widget.id || next != _count) {
      _count = next;
      unawaited(_load());
    }
  }

  Future<void> _load({bool fresh = false, bool more = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      if (more) {
        _count += widget.fullPage
            ? 200
            : widget.section?['preview_count'] as int? ?? 10;
      }
      await widget.store.load(widget.id, count: _count, fresh: fresh);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = _collectionError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play({
    List<int>? ids,
    int? startId,
    bool shuffle = false,
  }) async {
    final page = widget.store.pages[widget.id];
    if (_playing || page?['result_version'] == null) return;
    setState(() => _playing = true);
    try {
      final version = page!['result_version'].toString();
      List<dynamic> tracks;
      JsonMap? source;
      if (widget.store.online) {
        final plan = await widget.store.playPlan(
          widget.id,
          version,
          entityIds: ids,
        );
        tracks = plan['tracks'] as List;
        source = _collectionMap(plan['source']);
        if ((plan['missing_count'] as num? ?? 0) > 0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已跳过 ${plan['missing_count']} 首已移除的歌曲')),
          );
        }
      } else {
        if (_collectionMap(page['collection'])['entity_type'] != 'track' ||
            page['next_offset'] != null) {
          throw StateError('此集合的完整歌曲尚未缓存，请连接 Core 后播放');
        }
        tracks = (page['items'] as List)
            .where((v) => ids == null || ids.contains((v as Map)['entity_id']))
            .map((v) => (v as Map)['data'])
            .toList();
      }
      if (!mounted) return;
      final displayed = _displayTracks(context, tracks);
      if (displayed.isEmpty) throw StateError('当前展示条件下没有歌曲');
      if (shuffle) displayed.shuffle();
      var start = startId;
      if (start != null && !displayed.any((t) => t['id'] == start)) {
        start = null;
      }
      await widget.onPlay(
        start ?? displayed.first['id'] as int,
        displayed,
        source,
      );
    } catch (e) {
      if (mounted) setState(() => _error = _collectionError(e));
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _exclude([List<int>? ids]) async {
    final removed = ids?.toSet() ?? Set<int>.from(_selected);
    try {
      final latest = await widget.store.load(widget.id, fresh: true);
      final def = _collectionMap(jsonDecode(jsonEncode(latest['definition'])));
      def['included'] = (def['included'] as List)
          .where((v) => !removed.contains(v))
          .toList();
      def['excluded'] = {
        ...(def['excluded'] as List).cast<int>(),
        ...removed,
      }.toList();
      await widget.store.save(
        def,
        id: widget.id,
        revision: _collectionMap(latest['collection'])['revision'] as int,
      );
      if (mounted) setState(() => _selected.clear());
    } catch (e) {
      if (mounted) setState(() => _error = _collectionError(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.store,
      _TrackActionScope.maybeOf(context)?.displayState,
    ]),
    builder: (context, _) {
      final page = widget.store.pages[widget.id];
      final summary =
          widget.store.summary(widget.id) ??
          _collectionMap(page?['collection']);
      final type = summary['entity_type']?.toString() ?? 'track';
      final loaded = ((page?['items'] as List?) ?? []).map(_asMap).toList();
      final raw = widget.fullPage ? loaded : loaded.take(_count).toList();
      final currentTracks = <Object?, JsonMap>{
        for (final t in _TrackActionScope.maybeOf(context)?.catalogTracks ?? [])
          if (t is Map) t['release_identity_id']: _collectionMap(t),
      };
      final items = type == 'track'
          ? _displayTracks(
                  context,
                  raw
                      .map(
                        (i) => {
                          ..._collectionMap(i['data']),
                          ...?currentTracks[i['entity_id']],
                        },
                      )
                      .toList(),
                )
                .map(
                  (t) => {
                    'entity_id': t['release_identity_id'],
                    'entity_type': 'track',
                    'data': t,
                    'reason': raw
                        .where(
                          (i) => i['entity_id'] == t['release_identity_id'],
                        )
                        .firstOrNull?['reason'],
                  },
                )
                .toList()
          : raw;
      final title = widget.section?['title']?.toString().trim();
      final name = title != null && title.isNotEmpty
          ? title
          : summary['name']?.toString() ?? '集合';
      final layout =
          widget.section?['layout']?.toString() ??
          (type == 'track'
              ? 'list'
              : type == 'genre'
              ? 'chips'
              : 'grid');
      final header = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (summary['cover_album_id'] != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _ArtworkTile(
                    title: name,
                    subtitle: type,
                    size: 64,
                    icon: _collectionIcon(type),
                    imageUrl: _albumArtworkUrl(
                      widget.coreBaseUrl,
                      summary['cover_album_id'],
                    ),
                  ),
                ),
              Expanded(
                child: InkWell(
                  onTap: widget.onOpenCollection,
                  child: Text(
                    name,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (summary['can_edit'] == true)
                IconButton(
                  tooltip: '编辑关联集合',
                  onPressed: () => widget.onEdit(widget.id),
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
          Text(
            '${page?['result_total'] ?? summary['result_total'] ?? 0} 项${!widget.store.online ? ' · 离线缓存' : ''}',
          ),
          if (_error != null || page?['error'] != null)
            Text(
              _error ?? page!['error'].toString(),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                onPressed: _playing || page?['result_version'] == null
                    ? null
                    : () => _play(),
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放全部'),
              ),
              TextButton(
                onPressed: _playing ? null : () => _play(shuffle: true),
                child: const Text('随机播放'),
              ),
              if (widget.fullPage || summary['system_key'] == 'daily_mix')
                TextButton(
                  onPressed: !widget.store.online || _loading
                      ? null
                      : () async {
                          try {
                            await widget.store.refreshBatch(widget.id);
                            await _load(fresh: true);
                          } catch (e) {
                            if (mounted) {
                              setState(() => _error = _collectionError(e));
                            }
                          }
                        },
                  child: Text(
                    summary['system_key'] == 'daily_mix' ? '换一批' : '刷新结果',
                  ),
                ),
              if (layout != 'card')
                TextButton(
                  onPressed: () => setState(() => _selecting = !_selecting),
                  child: Text(_selecting ? '结束选择' : '选择'),
                ),
              if (widget.onOpenCollection != null)
                TextButton(
                  onPressed: widget.onOpenCollection,
                  child: const Text('查看全部'),
                ),
            ],
          ),
          if (_selecting)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _selected.addAll(
                      items.map((i) => i['entity_id'] as int),
                    ),
                  ),
                  child: const Text('选择已显示内容'),
                ),
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: const Text('清除选择'),
                ),
                TextButton(
                  onPressed: _selected.isEmpty || _playing
                      ? null
                      : () => _play(ids: _selected.toList()),
                  child: Text('播放所选 ${_selected.length} 项'),
                ),
                if (summary['system_key'] == null)
                  TextButton(
                    onPressed: _selected.isEmpty ? null : _exclude,
                    child: const Text('从集合排除'),
                  ),
              ],
            ),
          if (_loading || _playing) const LinearProgressIndicator(),
          const SizedBox(height: 12),
        ],
      );
      final content = _collectionResultSlivers(
        context,
        items: layout == 'card' ? const [] : items,
        layout: layout,
        coreBaseUrl: widget.coreBaseUrl,
        columns:
            ((widget.section?['track_columns'] as List?) ??
                    ['artist', 'album', 'duration', 'availability'])
                .cast<String>(),
        selected: _selecting ? _selected : null,
        onSelect: (id) => setState(
          () =>
              _selected.contains(id) ? _selected.remove(id) : _selected.add(id),
        ),
        onOpen: widget.onOpenEntity,
        onPlay: (item) {
          if (type == 'track') {
            unawaited(
              _play(startId: _collectionMap(item['data'])['id'] as int),
            );
          } else {
            unawaited(_play(ids: [item['entity_id'] as int]));
          }
        },
        onFavorite: widget.onToggleFavorite,
        onRemove: summary['system_key'] == null && widget.store.online
            ? (id) => unawaited(_exclude([id]))
            : null,
      );
      final more =
          layout != 'card' &&
          ((page?['result_total'] as num? ?? 0) > raw.length);
      final slivers = <Widget>[
        SliverToBoxAdapter(child: header),
        ...content,
        if (items.isEmpty && !_loading && layout != 'card')
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('没有符合条件的内容'),
            ),
          ),
        if (more)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: _loading ? null : () => _load(more: true),
              child: const Text('加载更多'),
            ),
          ),
      ];
      if (widget.fullPage) {
        return _PageFrame(
          title: name,
          child: CustomScrollView(
            key: PageStorageKey('collection-${widget.id}'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(20),
                sliver: SliverMainAxisGroup(slivers: slivers),
              ),
            ],
          ),
        );
      }
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: CustomScrollView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            slivers: slivers,
          ),
        ),
      );
    },
  );
}

List<Widget> _collectionResultSlivers(
  BuildContext context, {
  required List<JsonMap> items,
  required String layout,
  required String coreBaseUrl,
  required List<String> columns,
  Set<int>? selected,
  required ValueChanged<int> onSelect,
  required _CollectionOpen onOpen,
  required ValueChanged<JsonMap> onPlay,
  required Future<void> Function(JsonMap) onFavorite,
  ValueChanged<int>? onRemove,
}) {
  Widget tile(int index, {bool card = false}) {
    final item = items[index];
    final data = _collectionMap(item['data']);
    final kind = item['entity_type'].toString();
    final id = item['entity_id'] as int;
    Widget content;
    if (kind == 'track' && !card) {
      content = _SheetTrackRow(
        coreBaseUrl: coreBaseUrl,
        track: data,
        indexLabel: '${index + 1}',
        subtitle: _joinParts([
          if (columns.contains('artist')) data['artist_display'],
          if (columns.contains('album')) data['album_title'],
          if (columns.contains('year')) data['year'],
          if (columns.contains('genres'))
            (data['genres'] as List?)?.join(' · '),
          if (columns.contains('duration'))
            _formatDuration(data['duration_ms']),
        ]),
        onOpen: () => onOpen('track', data['id'] as int),
        onPlay: () => onPlay(item),
        onToggleFavorite: onFavorite,
        onRemove: onRemove == null ? null : () => onRemove(id),
        showAvailability: columns.contains('availability'),
      );
    } else {
      final artwork = _ArtworkTile(
        title: _entityName(item),
        subtitle: _entitySubtitle(item),
        size: card ? 110 : 48,
        icon: _collectionIcon(kind),
        imageUrl: switch (kind) {
          'album' => _albumArtworkUrl(coreBaseUrl, data['id']),
          'artist' => _artistArtworkUrl(coreBaseUrl, data['id'], 'artist_card'),
          'track' => _trackArtworkUrl(coreBaseUrl, data['id']),
          _ => null,
        },
      );
      content = card
          ? InkWell(
              onTap: () => onOpen(kind, data['id'] as int),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    artwork,
                    const SizedBox(height: 8),
                    Text(
                      _entityName(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      _entitySubtitle(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    IconButton(
                      tooltip: '播放此项',
                      onPressed: () => onPlay(item),
                      icon: const Icon(Icons.play_arrow),
                    ),
                  ],
                ),
              ),
            )
          : ListTile(
              leading: artwork,
              title: Text(_entityName(item)),
              subtitle: Text(_entitySubtitle(item)),
              onTap: () => onOpen(kind, data['id'] as int),
              trailing: IconButton(
                tooltip: '播放此项',
                onPressed: () => onPlay(item),
                icon: const Icon(Icons.play_arrow),
              ),
            );
    }
    return selected == null
        ? content
        : Row(
            children: [
              Checkbox(
                value: selected.contains(id),
                onChanged: (_) => onSelect(id),
              ),
              Expanded(child: content),
            ],
          );
  }

  if (layout == 'chips') {
    return [
      SliverToBoxAdapter(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final item in items)
              InputChip(
                label: Text(
                  '${_entityName(item)} · ${_collectionMap(item['data'])['track_count'] ?? 0} 首',
                ),
                selected: selected?.contains(item['entity_id']) ?? false,
                onPressed: () => selected != null
                    ? onSelect(item['entity_id'] as int)
                    : onOpen(
                        'genre',
                        _collectionMap(item['data'])['id'] as int,
                      ),
                onDeleted: () => onPlay(item),
                deleteIcon: const Icon(Icons.play_arrow),
                deleteButtonTooltipMessage: '播放此流派',
              ),
          ],
        ),
      ),
    ];
  }
  if (layout == 'grid') {
    return [
      SliverLayoutBuilder(
        builder: (c, constraints) => SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: max(1, (constraints.crossAxisExtent / 190).floor()),
            mainAxisExtent: 240,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: items.length,
          itemBuilder: (c, i) => tile(i, card: true),
        ),
      ),
    ];
  }
  if (layout == 'carousel') {
    return [
      SliverToBoxAdapter(
        child: SizedBox(
          height: 240,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (c, i) => const SizedBox(width: 12),
            itemBuilder: (c, i) =>
                SizedBox(width: 190, child: tile(i, card: true)),
          ),
        ),
      ),
    ];
  }
  return [
    SliverList.builder(itemCount: items.length, itemBuilder: (c, i) => tile(i)),
  ];
}
