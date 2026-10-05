part of '../intmusic_client.dart';

JsonMap _collectionMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

String _collectionTypeName(String? type) => switch (type) {
  'album' => '专辑',
  'artist' => '艺术家',
  'genre' => '流派',
  _ => '歌曲',
};
IconData _collectionIcon(String? type) => switch (type) {
  'album' => Icons.album_outlined,
  'artist' => Icons.person_outline,
  'genre' => Icons.sell_outlined,
  _ => Icons.queue_music,
};
String _collectionError(Object error) {
  if (error is StateError) return error.message.toString();
  if (error is HttpException) {
    final start = error.message.indexOf('{');
    if (start >= 0) {
      try {
        return _collectionMap(
              jsonDecode(error.message.substring(start)),
            )['error']?.toString() ??
            error.message;
      } catch (_) {}
    }
  }
  if (error is SocketException || error is TimeoutException) {
    return '无法连接 Core，请检查连接后重试';
  }
  return error.toString();
}

String _entityName(JsonMap item) {
  final d = _collectionMap(item['data']);
  return (d['title'] ?? d['name'] ?? '未知内容').toString();
}

String _entitySubtitle(JsonMap item) {
  final d = _collectionMap(item['data']);
  return _joinParts([
    d['artist_display'] ?? d['album_artist_display'],
    d['album_title'],
    d['year'],
    if (d['track_count'] != null) '${d['track_count']} 首',
  ]);
}

Future<JsonMap?> _showCollectionEditor(
  BuildContext context,
  CollectionStore store, {
  JsonMap? page,
  String? type,
  required String coreBaseUrl,
  required Future<List<JsonMap>> Function() loadSources,
}) => showDialog<JsonMap>(
  context: context,
  barrierDismissible: false,
  builder: (context) => Dialog.fullscreen(
    child: _CollectionEditor(
      store: store,
      initial: page,
      type: type,
      coreBaseUrl: coreBaseUrl,
      loadSources: loadSources,
    ),
  ),
);

class _CollectionEditor extends StatefulWidget {
  const _CollectionEditor({
    required this.store,
    required this.coreBaseUrl,
    required this.loadSources,
    this.initial,
    this.type,
  });
  final CollectionStore store;
  final String coreBaseUrl;
  final Future<List<JsonMap>> Function() loadSources;
  final JsonMap? initial;
  final String? type;
  @override
  State<_CollectionEditor> createState() => _CollectionEditorState();
}

class _CollectionEditorState extends State<_CollectionEditor> {
  late JsonMap _def = _collectionMap(
    jsonDecode(
      jsonEncode(
        widget.initial?['definition'] ??
            emptyCollection(widget.type ?? 'track'),
      ),
    ),
  );
  late final String? _identity = widget.store.identity;
  late final _name = TextEditingController(text: _def['name'].toString());
  late final _description = TextEditingController(
    text: _def['description'].toString(),
  );
  final Map<int, JsonMap> _members = {};
  List<JsonMap> _sources = [];
  JsonMap? _preview;
  String? _error;
  bool _busy = false, _dirty = false;
  Timer? _debounce;
  int _previewRequest = 0;
  String get _type => _def['entity_type'].toString();
  JsonMap get _summary => _collectionMap(widget.initial?['collection']);
  bool get _system => _summary['system_key'] != null;
  int? get _id => _intValue(_summary['id']);
  @override
  void initState() {
    super.initState();
    for (final value in (widget.initial?['items'] as List?) ?? []) {
      final item = _collectionMap(value);
      _members[_intValue(item['entity_id'])!] = item;
    }
    unawaited(_load());
    _schedulePreview();
  }

  Future<void> _load() async {
    try {
      final values = await widget.loadSources();
      if (mounted) setState(() => _sources = values);
    } catch (_) {}
    try {
      final ids = {
        ...(_def['included'] as List).cast<int>(),
        ...(_def['excluded'] as List).cast<int>(),
      }.toList();
      final members = await widget.store.lookup(_type, ids);
      if (mounted) {
        setState(() {
          for (final item in members) {
            _members[item['entity_id'] as int] = item;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _collectionError(e));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _change(VoidCallback change) {
    setState(() {
      change();
      _dirty = true;
    });
    _schedulePreview();
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _previewRequest++;
    if (!mounted || !widget.store.online) return;
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_runPreview()),
    );
  }

  JsonMap _payload() => {
    ..._def,
    'name': _name.text.trim(),
    'description': _description.text.trim(),
  };
  Future<void> _runPreview() async {
    final request = ++_previewRequest;
    try {
      final payload = _payload();
      if ((payload['name'] as String).isEmpty) payload['name'] = '未命名集合';
      final result = await widget.store.preview(payload);
      if (mounted &&
          request == _previewRequest &&
          _identity == widget.store.identity) {
        setState(() {
          _preview = result;
          _error = null;
          for (final v in result['items'] as List) {
            final item = _collectionMap(v);
            _members[item['entity_id'] as int] = item;
          }
        });
      }
    } catch (e) {
      if (mounted && request == _previewRequest) {
        setState(() => _error = _collectionError(e));
      }
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    _debounce?.cancel();
    _previewRequest++;
    try {
      if (_identity != widget.store.identity) {
        throw StateError('资料库已切换，不能保存此草稿');
      }
      final result = await widget.store.save(
        _payload(),
        id: _id,
        revision: _intValue(_summary['revision']),
      );
      if (mounted) {
        setState(() => _dirty = false);
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _collectionError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('放弃未保存的修改？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) {
      setState(() => _dirty = false);
      Navigator.pop(context);
    }
  }

  Future<void> _pick(String field) async {
    final values = await showDialog<List<JsonMap>>(
      context: context,
      builder: (c) => Dialog(
        child: SizedBox(
          width: 760,
          height: 640,
          child: _CollectionEntityPicker(
            store: widget.store,
            type: _type,
            selected: (_def[field] as List).cast<int>().toSet(),
          ),
        ),
      ),
    );
    if (values == null || !mounted) return;
    _change(() {
      final ids = (_def[field] as List).cast<int>().toList();
      for (final item in values) {
        final id = item['entity_id'] as int;
        if (!ids.contains(id)) ids.add(id);
        _members[id] = item;
        (_def[field == 'included' ? 'excluded' : 'included'] as List).remove(
          id,
        );
      }
      _def[field] = ids;
    });
  }

  Widget _memberList(String field) {
    final ids = (_def[field] as List).cast<int>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${field == 'included' ? '指定内容' : '排除内容'} · ${ids.length}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _system ? null : () => _pick(field),
              icon: const Icon(Icons.add),
              label: const Text('添加'),
            ),
          ],
        ),
        if (ids.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              field == 'included' ? '指定内容按手动顺序排在规则结果之前。' : '排除后不会因自动规则再次出现。',
            ),
          ),
        if (ids.isNotEmpty)
          SizedBox(
            height: min(300.0, ids.length * 68.0),
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: ids.length,
              onReorderItem: (from, to) => _change(() {
                final id = ids.removeAt(from);
                ids.insert(to, id);
                _def[field] = ids;
              }),
              itemBuilder: (c, index) {
                final id = ids[index];
                final item = _members[id];
                return ListTile(
                  key: ValueKey('$field-$id'),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(
                    item == null
                        ? '${_collectionTypeName(_type)} #$id'
                        : _entityName(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: item == null
                      ? null
                      : Text(
                          _entitySubtitle(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: IconButton(
                    tooltip: '移除',
                    onPressed: () => _change(() {
                      ids.removeAt(index);
                      _def[field] = ids;
                    }),
                    icon: const Icon(Icons.close),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _number(String label, String key, {String? help}) => SizedBox(
    width: 230,
    child: TextFormField(
      key: ValueKey(key),
      initialValue: _def[key]?.toString() ?? '',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, helperText: help),
      onChanged: (v) {
        _def[key] = v.trim().isEmpty ? null : int.tryParse(v) ?? 0;
        _dirty = true;
        _schedulePreview();
      },
    ),
  );
  Widget _form() {
    final auto = _def['automatic'];
    final playback = _collectionMap(_def['playback']);
    final sorts = (_def['sort'] as List).map(_asMap).toList();
    return Column(
      key: ValueKey(_type),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          readOnly: _system,
          decoration: const InputDecoration(labelText: '名称'),
          onChanged: (_) => _change(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _description,
          decoration: const InputDecoration(labelText: '描述'),
          maxLines: 2,
          onChanged: (_) => _change(() {}),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _type,
          decoration: const InputDecoration(labelText: '集合内容'),
          items: [
            for (final type in ['track', 'album', 'artist', 'genre'])
              DropdownMenuItem(
                value: type,
                child: Text(_collectionTypeName(type)),
              ),
          ],
          onChanged: _id != null
              ? null
              : (type) {
                  if (type != null) {
                    _change(() {
                      _def = emptyCollection(type);
                      _preview = null;
                      _members.clear();
                    });
                  }
                },
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('封面跟随内容，也可选择已入库的专辑封面')),
            TextButton(
              onPressed: () async {
                final picks = await showDialog<List<JsonMap>>(
                  context: context,
                  builder: (c) => Dialog(
                    child: SizedBox(
                      width: 760,
                      height: 640,
                      child: _CollectionEntityPicker(
                        store: widget.store,
                        type: 'album',
                        selected: const {},
                        single: true,
                      ),
                    ),
                  ),
                );
                if (picks != null && picks.isNotEmpty && mounted) {
                  _change(
                    () => _def['cover_album_id'] = _collectionMap(
                      picks.first['data'],
                    )['id'],
                  );
                }
              },
              child: const Text('选择封面'),
            ),
            if (_def['cover_album_id'] != null)
              IconButton(
                onPressed: () => _change(() => _def['cover_album_id'] = null),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        const Divider(height: 32),
        if (!_system) ...[_memberList('included'), const Divider(height: 32)],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动筛选'),
          subtitle: const Text('关闭时只保留手动指定的内容。'),
          value: auto != null,
          onChanged: _system
              ? null
              : (enabled) => _change(
                  () => _def['automatic'] = enabled
                      ? {'kind': 'all', 'conditions': <dynamic>[]}
                      : null,
                ),
        ),
        if (auto != null)
          _CollectionRuleEditor(
            value: _collectionMap(auto),
            entityType: _type,
            schema: widget.store.schema,
            sources: _sources,
            onChanged: (v) => _change(() => _def['automatic'] = v),
          ),
        if (!_system) ...[const Divider(height: 32), _memberList('excluded')],
        const Divider(height: 32),
        Text('结果安排', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        for (var i = 0; i < sorts.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('sort-$i-${sorts[i]['field']}'),
                    initialValue: sorts[i]['field'].toString(),
                    decoration: InputDecoration(
                      labelText: i == 0 ? '排序' : '次级排序',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'random',
                        child: Text('随机'),
                      ),
                      for (final f
                          in _collectionFields(
                            widget.store.schema,
                            _type,
                          ).where(
                            (f) => [
                              'text',
                              'number',
                              'date',
                              'bool',
                              'mode',
                            ].contains(f['type']),
                          ))
                        DropdownMenuItem(
                          value: f['field'].toString(),
                          child: Text(f['label'].toString()),
                        ),
                    ],
                    onChanged: _system
                        ? null
                        : (v) => _change(() {
                            sorts[i]['field'] = v;
                            if (v == 'random') {
                              _def['sort'] = [sorts[i]];
                            } else {
                              _def['sort'] = sorts;
                            }
                          }),
                  ),
                ),
                IconButton(
                  tooltip: sorts[i]['descending'] == true ? '倒序' : '正序',
                  onPressed: _system || sorts[i]['field'] == 'random'
                      ? null
                      : () => _change(() {
                          sorts[i]['descending'] =
                              sorts[i]['descending'] != true;
                          _def['sort'] = sorts;
                        }),
                  icon: Icon(
                    sorts[i]['descending'] == true ? Icons.south : Icons.north,
                  ),
                ),
                if (!_system)
                  IconButton(
                    onPressed: () => _change(() {
                      sorts.removeAt(i);
                      _def['sort'] = sorts;
                    }),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
        if (!_system &&
            sorts.length < 5 &&
            !sorts.any((s) => s['field'] == 'random'))
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _change(
                () => _def['sort'] = [
                  ...sorts,
                  {'field': 'name', 'descending': false},
                ],
              ),
              icon: const Icon(Icons.add),
              label: const Text('增加排序'),
            ),
          ),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _number('结果上限（留空为不限）', 'limit', help: '包含指定内容'),
            if (_type == 'track') ...[
              _number('每位艺术家最多', 'max_per_artist', help: '仅限制自动选入部分'),
              _number('每张专辑最多', 'max_per_album', help: '仅限制自动选入部分'),
            ],
          ],
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _def['refresh'].toString(),
          decoration: const InputDecoration(
            labelText: '刷新方式',
            helperText: '每日刷新以 Core 的 UTC 日期为准。',
          ),
          items: const [
            DropdownMenuItem(value: 'live', child: Text('随资料库变化更新')),
            DropdownMenuItem(value: 'daily', child: Text('每日更新')),
            DropdownMenuItem(value: 'manual', child: Text('仅手动刷新')),
          ],
          onChanged: _system ? null : (v) => _change(() => _def['refresh'] = v),
        ),
        if (_type != 'track') ...[
          const Divider(height: 32),
          Text('播放范围', style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('仅播放符合条件的歌曲'),
            subtitle: Text(
              _type == 'album'
                  ? '关闭时播放整张专辑；开启后单独指定歌曲条件。'
                  : '关闭时播放所有关联歌曲；开启后单独指定歌曲条件。',
            ),
            value: playback['filter'] != null,
            onChanged: (v) => _change(
              () => _def['playback'] = {
                ...playback,
                'filter': v ? {'kind': 'all', 'conditions': <dynamic>[]} : null,
              },
            ),
          ),
          if (_type == 'artist')
            _collectionRoleDropdown(
              playback['artist_role'].toString(),
              (v) => _change(
                () => _def['playback'] = {...playback, 'artist_role': v},
              ),
            ),
          if (playback['filter'] != null)
            _CollectionRuleEditor(
              value: _collectionMap(playback['filter']),
              entityType: 'track',
              schema: widget.store.schema,
              sources: _sources,
              onChanged: (v) =>
                  _change(() => _def['playback'] = {...playback, 'filter': v}),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: playback['order'].toString(),
            decoration: const InputDecoration(labelText: '关联歌曲的播放顺序'),
            items: const [
              DropdownMenuItem(value: 'album', child: Text('按专辑、碟号和曲号')),
              DropdownMenuItem(value: 'name', child: Text('按歌曲名称')),
              DropdownMenuItem(value: 'random', child: Text('随机')),
            ],
            onChanged: (v) =>
                _change(() => _def['playback'] = {...playback, 'order': v}),
          ),
        ],
        if (_system)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: OutlinedButton(
              onPressed: () async {
                final reset = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('恢复系统默认规则？'),
                    content: const Text('当前规则会被默认规则替换，正在播放的队列保持不变。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('恢复'),
                      ),
                    ],
                  ),
                );
                if (reset != true) return;
                try {
                  final result = await widget.store.resetRules(
                    _id!,
                    _summary['revision'] as int,
                  );
                  if (mounted) {
                    setState(() => _dirty = false);
                    Navigator.pop(context, result);
                  }
                } catch (e) {
                  if (mounted) setState(() => _error = _collectionError(e));
                }
              },
              child: const Text('恢复默认规则'),
            ),
          ),
        if (_id != null && !_system)
          Padding(
            padding: const EdgeInsets.only(top: 20),
            child: OutlinedButton(
              onPressed: () async {
                try {
                  final page = await widget.store.load(
                    _id!,
                    count: 100000,
                    fresh: true,
                  );
                  if (mounted) {
                    _change(() {
                      _def['included'] = (page['items'] as List)
                          .map((v) => (v as Map)['entity_id'])
                          .toList();
                      _def['excluded'] = [];
                      _def['automatic'] = null;
                    });
                  }
                } catch (e) {
                  if (mounted) setState(() => _error = _collectionError(e));
                }
              },
              child: const Text('将当前结果固定为指定内容'),
            ),
          ),
      ],
    );
  }

  Widget _previewPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('实时预览', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(
        _preview == null
            ? '设置条件后显示结果。'
            : '规则匹配 ${_preview!['matched_total']} 项 · 最终 ${_preview!['result_total']} 项',
      ),
      const Text('预览最多显示 50 项，不会保存或更改正在播放的队列。'),
      if ((_preview?['missing_members'] as List?)?.isNotEmpty == true)
        const Text('部分指定内容已从资料库移除，请检查。'),
      const SizedBox(height: 12),
      for (final value in (_preview?['items'] as List?) ?? [])
        Builder(
          builder: (c) {
            final item = _collectionMap(value);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(_collectionIcon(item['entity_type']?.toString())),
              title: Text(_entityName(item)),
              subtitle: Text(_entitySubtitle(item)),
              trailing: Text(item['reason'] == 'specified' ? '指定' : '规则'),
            );
          },
        ),
    ],
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_busy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_close());
    },
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                IconButton(
                  onPressed: _busy ? null : _close,
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    _id == null ? '新建集合' : '编辑集合',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? '正在保存…' : '保存'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (c, constraints) {
                if (constraints.maxWidth >= 1000) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _form(),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        flex: 2,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _previewPanel(),
                        ),
                      ),
                    ],
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      _form(),
                      const Divider(height: 36),
                      _previewPanel(),
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

List<JsonMap> _collectionFields(JsonMap schema, String type) =>
    ((_collectionMap(
                  ((schema['types'] as List?) ?? [])
                      .where((v) => (v as Map)['entity_type'] == type)
                      .firstOrNull,
                )['fields']
                as List?) ??
            [])
        .map(_asMap)
        .toList();
Widget _collectionRoleDropdown(String value, ValueChanged<String?> onChanged) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      decoration: const InputDecoration(labelText: '艺术家参与关系'),
      items: const [
        DropdownMenuItem(value: 'performer', child: Text('主唱或合作演唱')),
        DropdownMenuItem(value: 'album_artist', child: Text('专辑艺术家')),
        DropdownMenuItem(value: 'composer', child: Text('作曲')),
        DropdownMenuItem(value: 'lyricist', child: Text('作词')),
      ],
      onChanged: onChanged,
    );
