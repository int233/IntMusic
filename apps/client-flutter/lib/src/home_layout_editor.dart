part of '../intmusic_client.dart';

const _homeBuiltinLabels = {
  'now_playing': '正在播放',
  'library': '资料库概况',
  'history': '最近播放',
  'devices': '播放设备',
  'stats': '聆听统计',
  'core': 'Core 连接',
};
List<String> _homeLayouts(String type) => switch (type) {
  'track' => ['card', 'list', 'carousel'],
  'genre' => ['card', 'list', 'chips'],
  _ => ['card', 'list', 'grid', 'carousel'],
};
const _homeLayoutNames = {
  'card': '摘要卡片',
  'list': '直接列表',
  'grid': '封面网格',
  'carousel': '横向列表',
  'chips': '流派标签',
};

class _HomeLayoutEditor extends StatefulWidget {
  const _HomeLayoutEditor({
    required this.store,
    required this.onEditCollection,
  });
  final CollectionStore store;
  final Future<void> Function(int?) onEditCollection;
  @override
  State<_HomeLayoutEditor> createState() => _HomeLayoutEditorState();
}

class _HomeLayoutEditorState extends State<_HomeLayoutEditor> {
  late final _identity = widget.store.identity;
  late final int _revision = widget.store.layout['revision'] as int;
  late final List<JsonMap> _sections =
      (jsonDecode(jsonEncode(widget.store.layout['sections'])) as List)
          .map(_asMap)
          .toList();
  bool _busy = false;
  String? _error;
  JsonMap _section({int? id, String? builtin}) => {
    'id':
        'section-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(100000)}',
    'collection_id': id,
    'builtin': builtin,
    'title': null,
    'layout': id == null ? 'card' : 'list',
    'preview_count': 6,
    'width': id == null ? 'narrow' : 'wide',
    'hidden': false,
    'track_columns': ['artist', 'album', 'duration', 'availability'],
  };
  Future<void> _add({bool create = false}) async {
    int? id;
    if (create) {
      final before = widget.store.items.map((i) => i['id']).toSet();
      await widget.onEditCollection(null);
      id =
          widget.store.items
                  .where((i) => !before.contains(i['id']))
                  .firstOrNull?['id']
              as int?;
    } else {
      id = await showDialog<int>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('选择关联集合'),
          children: [
            for (final item in widget.store.items)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, item['id']),
                child: Text(
                  '${item['name']} · ${_collectionTypeName(item['entity_type']?.toString())}',
                ),
              ),
          ],
        ),
      );
    }
    if (id != null && mounted) setState(() => _sections.add(_section(id: id)));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      if (_identity != widget.store.identity) throw StateError('资料库已切换');
      await widget.store.saveLayout(_sections, _revision);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = _collectionError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _restore() {
    setState(() {
      for (final item in widget.store.items.where(
        (i) => i['system_key'] != null,
      )) {
        final index = _sections.indexWhere(
          (s) => s['collection_id'] == item['id'],
        );
        if (index < 0) {
          _sections.add(_section(id: item['id'] as int));
        } else {
          _sections[index]['hidden'] = false;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              IconButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
              Expanded(
                child: Text(
                  '编辑首页',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('保存布局'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _add(),
                icon: const Icon(Icons.add),
                label: const Text('关联已有集合'),
              ),
              OutlinedButton(
                onPressed: () => _add(create: true),
                child: const Text('创建集合并展示'),
              ),
              PopupMenuButton<String>(
                onSelected: (v) =>
                    setState(() => _sections.add(_section(builtin: v))),
                itemBuilder: (c) => [
                  for (final entry in _homeBuiltinLabels.entries)
                    PopupMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('添加内置内容'),
                ),
              ),
              TextButton(onPressed: _restore, child: const Text('恢复默认集合入口')),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('拖动调整顺序。区块显示数量不限制集合总数；布局在设备间同步，手机自动排成单列。'),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.all(16),
            itemCount: _sections.length,
            onReorderItem: (from, to) => setState(() {
              _sections.insert(to, _sections.removeAt(from));
            }),
            itemBuilder: (c, index) {
              final section = _sections[index];
              final item = widget.store.summary(
                section['collection_id'] as int? ?? -1,
              );
              final type = item?['entity_type']?.toString() ?? 'track';
              final builtin = section['builtin']?.toString();
              return Card(
                key: ValueKey(section['id']),
                child: ExpansionTile(
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(
                    section['title']?.toString().isNotEmpty == true
                        ? section['title'].toString()
                        : item?['name']?.toString() ??
                              _homeBuiltinLabels[builtin] ??
                              '已删除的集合',
                  ),
                  subtitle: Text(
                    '${_homeLayoutNames[section['layout']] ?? '卡片'}${section['hidden'] == true ? ' · 已隐藏' : ''}',
                  ),
                  childrenPadding: const EdgeInsets.all(16),
                  children: [
                    TextFormField(
                      initialValue: section['title']?.toString() ?? '',
                      decoration: const InputDecoration(
                        labelText: '区块标题（留空跟随内容）',
                      ),
                      onChanged: (v) =>
                          section['title'] = v.trim().isEmpty ? null : v,
                    ),
                    if (builtin == null) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: section['collection_id'] as int?,
                        decoration: const InputDecoration(labelText: '关联集合'),
                        items: [
                          for (final item in widget.store.items)
                            DropdownMenuItem(
                              value: item['id'] as int,
                              child: Text(item['name'].toString()),
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          section['collection_id'] = v;
                          section['layout'] = 'list';
                        }),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          '${section['id']}-${section['collection_id']}-${section['layout']}',
                        ),
                        initialValue: section['layout'].toString(),
                        decoration: const InputDecoration(labelText: '展示方式'),
                        items: [
                          for (final layout in _homeLayouts(type))
                            DropdownMenuItem(
                              value: layout,
                              child: Text(_homeLayoutNames[layout]!),
                            ),
                        ],
                        onChanged: (v) => setState(() => section['layout'] = v),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: section['preview_count'].toString(),
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '首次展示数量（1—100）',
                        ),
                        onChanged: (v) =>
                            section['preview_count'] = int.tryParse(v) ?? 0,
                      ),
                      if (type == 'track')
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final column in {
                              'artist': '艺术家',
                              'album': '专辑',
                              'year': '年份',
                              'genres': '流派',
                              'duration': '时长',
                              'availability': '可用来源',
                            }.entries)
                              FilterChip(
                                label: Text(column.value),
                                selected: (section['track_columns'] as List)
                                    .contains(column.key),
                                onSelected: (v) => setState(() {
                                  final cols = section['track_columns'] as List;
                                  v
                                      ? cols.add(column.key)
                                      : cols.remove(column.key);
                                }),
                              ),
                          ],
                        ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: section['width'].toString(),
                      decoration: const InputDecoration(labelText: '桌面宽度'),
                      items: const [
                        DropdownMenuItem(value: 'wide', child: Text('宽区块')),
                        DropdownMenuItem(value: 'narrow', child: Text('窄区块')),
                      ],
                      onChanged: (v) => section['width'] = v,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('显示区块'),
                      value: section['hidden'] != true,
                      onChanged: (v) => setState(() => section['hidden'] = !v),
                    ),
                    Row(
                      children: [
                        if (builtin == null)
                          TextButton(
                            onPressed: item?['can_edit'] == true
                                ? () => widget.onEditCollection(
                                    section['collection_id'] as int,
                                  )
                                : null,
                            child: const Text('编辑关联集合'),
                          ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              setState(() => _sections.removeAt(index)),
                          child: const Text('移除区块'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
