part of '../intmusic_client.dart';

class _CollectionRuleEditor extends StatelessWidget {
  const _CollectionRuleEditor({
    super.key,
    required this.value,
    required this.entityType,
    required this.schema,
    required this.sources,
    required this.onChanged,
    this.depth = 0,
  });
  final JsonMap value, schema;
  final String entityType;
  final List<JsonMap> sources;
  final ValueChanged<JsonMap> onChanged;
  final int depth;
  JsonMap _field() => {
    'kind': 'field',
    'field': 'name',
    'op': 'contains',
    'value': '',
  };
  @override
  Widget build(BuildContext context) {
    final kind = value['kind'];
    final fields = _collectionFields(schema, entityType);
    if (kind == 'all' || kind == 'any') {
      final children = ((value['conditions'] as List?) ?? [])
          .map(_asMap)
          .toList();
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: IntMusicTheme.of(context).stroke),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: kind.toString(),
              decoration: const InputDecoration(labelText: '条件组'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('全部满足')),
                DropdownMenuItem(value: 'any', child: Text('任一满足')),
              ],
              onChanged: (v) => onChanged({...value, 'kind': v}),
            ),
            if (children.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(kind == 'all' ? '没有条件：匹配全部内容' : '没有条件：不会匹配内容'),
              ),
            for (var i = 0; i < children.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _CollectionRuleEditor(
                        key: ValueKey(i),
                        value: children[i],
                        entityType: entityType,
                        schema: schema,
                        sources: sources,
                        depth: depth + 1,
                        onChanged: (v) {
                          children[i] = v;
                          onChanged({...value, 'conditions': children});
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: '删除条件',
                      onPressed: () {
                        children.removeAt(i);
                        onChanged({...value, 'conditions': children});
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => onChanged({
                    ...value,
                    'conditions': [...children, _field()],
                  }),
                  icon: const Icon(Icons.add),
                  label: const Text('条件'),
                ),
                if (depth < 4)
                  TextButton(
                    onPressed: () => onChanged({
                      ...value,
                      'conditions': [
                        ...children,
                        {
                          'kind': 'all',
                          'conditions': [_field()],
                        },
                      ],
                    }),
                    child: const Text('条件组'),
                  ),
                if (entityType != 'track' && depth < 4)
                  TextButton(
                    onPressed: () => onChanged({
                      ...value,
                      'conditions': [
                        ...children,
                        {
                          'kind': 'tracks',
                          'quantifier': 'any',
                          'value': 1,
                          'role': 'performer',
                          'condition': {
                            'kind': 'all',
                            'conditions': [_field()],
                          },
                        },
                      ],
                    }),
                    child: const Text('关联歌曲条件'),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    if (kind == 'tracks') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: value['quantifier'].toString(),
            decoration: const InputDecoration(labelText: '关联歌曲'),
            items: const [
              DropdownMenuItem(value: 'any', child: Text('至少一首满足')),
              DropdownMenuItem(value: 'all', child: Text('全部满足且非空')),
              DropdownMenuItem(value: 'at_least', child: Text('至少指定数量满足')),
              DropdownMenuItem(value: 'percent', child: Text('至少指定比例满足')),
            ],
            onChanged: (v) =>
                onChanged({...value, 'quantifier': v, 'value': 1}),
          ),
          if (['at_least', 'percent'].contains(value['quantifier']))
            TextFormField(
              initialValue: value['value'].toString(),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: value['quantifier'] == 'percent'
                    ? '百分比（1—100）'
                    : '歌曲数量',
              ),
              onChanged: (v) =>
                  onChanged({...value, 'value': int.tryParse(v) ?? 0}),
            ),
          if (entityType == 'artist')
            _collectionRoleDropdown(
              value['role'].toString(),
              (v) => onChanged({...value, 'role': v}),
            ),
          _CollectionRuleEditor(
            value: _collectionMap(value['condition']),
            entityType: 'track',
            schema: schema,
            sources: sources,
            depth: depth + 1,
            onChanged: (v) => onChanged({...value, 'condition': v}),
          ),
        ],
      );
    }
    final spec =
        fields.where((f) => f['field'] == value['field']).firstOrNull ??
        {
          'type': 'text',
          'operators': ['contains'],
        };
    const opNames = {
      'eq': '等于',
      'not_eq': '不等于',
      'contains': '包含',
      'gte': '不少于',
      'lte': '不多于',
      'is_empty': '为空',
      'within_days': '最近若干天',
      'in': '任一来源',
      'all_in': '所有来源',
      'not_in': '不在这些来源',
    };
    final type = spec['type'];
    final boolean = type == 'bool' || value['op'] == 'is_empty';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('field-${value['field']}'),
          initialValue: value['field'].toString(),
          decoration: const InputDecoration(labelText: '属性'),
          items: [
            for (final f in fields)
              DropdownMenuItem(
                value: f['field'].toString(),
                child: Text(f['label'].toString()),
              ),
          ],
          onChanged: (v) {
            final f = fields.firstWhere((f) => f['field'] == v);
            onChanged({
              'kind': 'field',
              'field': v,
              'op': (f['operators'] as List).first,
              'value': switch (f['type']) {
                'bool' => true,
                'number' || 'date' => 1,
                'ids' => <int>[],
                'mode' => 'inherit',
                _ => '',
              },
            });
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          key: ValueKey('op-${value['field']}-${value['op']}'),
          initialValue: value['op'].toString(),
          decoration: const InputDecoration(labelText: '条件'),
          items: [
            for (final op in spec['operators'] as List)
              DropdownMenuItem(
                value: op.toString(),
                child: Text(opNames[op] ?? op.toString()),
              ),
          ],
          onChanged: (op) => onChanged({
            ...value,
            'op': op,
            'value': op == 'is_empty'
                ? true
                : (type == 'bool'
                      ? true
                      : type == 'number' || type == 'date'
                      ? 1
                      : type == 'ids'
                      ? <int>[]
                      : type == 'mode'
                      ? 'inherit'
                      : ''),
          }),
        ),
        const SizedBox(height: 8),
        if (boolean)
          DropdownButtonFormField<bool>(
            key: ValueKey('bool-${value['field']}-${value['op']}'),
            initialValue: value['value'] == true,
            items: const [
              DropdownMenuItem(value: true, child: Text('是')),
              DropdownMenuItem(value: false, child: Text('否')),
            ],
            onChanged: (v) => onChanged({...value, 'value': v}),
          )
        else if (type == 'mode')
          DropdownButtonFormField<String>(
            initialValue: value['value'].toString(),
            items: [
              for (final mode in ['inherit', 'merged', 'independent'])
                DropdownMenuItem(
                  value: mode,
                  child: Text(songDisplayModeLabel(mode)),
                ),
            ],
            onChanged: (v) => onChanged({...value, 'value': v}),
          )
        else if (type == 'ids')
          Wrap(
            spacing: 6,
            children: [
              if (sources.isEmpty) const Text('当前没有可选的音乐来源'),
              for (final source in sources)
                FilterChip(
                  label: Text(source['label'].toString()),
                  selected: (value['value'] as List).contains(source['id']),
                  onSelected: (selected) {
                    final ids = List.of(value['value'] as List);
                    selected ? ids.add(source['id']) : ids.remove(source['id']);
                    onChanged({...value, 'value': ids});
                  },
                ),
            ],
          )
        else
          TextFormField(
            key: ValueKey('value-${value['field']}-${value['op']}'),
            initialValue: value['value']?.toString() ?? '',
            decoration: const InputDecoration(labelText: '值'),
            keyboardType: type == 'number' || type == 'date'
                ? TextInputType.number
                : TextInputType.text,
            onChanged: (v) => onChanged({
              ...value,
              'value': type == 'number' || type == 'date'
                  ? num.tryParse(v) ?? 0
                  : v,
            }),
          ),
      ],
    );
  }
}

class _CollectionEntityPicker extends StatefulWidget {
  const _CollectionEntityPicker({
    required this.store,
    required this.type,
    required this.selected,
    this.single = false,
  });
  final CollectionStore store;
  final String type;
  final Set<int> selected;
  final bool single;
  @override
  State<_CollectionEntityPicker> createState() =>
      _CollectionEntityPickerState();
}

class _CollectionEntityPickerState extends State<_CollectionEntityPicker> {
  final _search = TextEditingController();
  final Map<int, JsonMap> _picked = {};
  List<JsonMap> _items = [];
  int? _next;
  bool _loading = true;
  String? _error;
  Timer? _debounce;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final request = ++_request;
    setState(() => _loading = true);
    try {
      final result = await widget.store.browse(
        widget.type,
        _search.text,
        offset: more ? _next ?? 0 : 0,
      );
      if (mounted && request == _request) {
        setState(() {
          _items = [
            if (more) ..._items,
            ...(result['items'] as List).map(_asMap),
          ];
          _next = _intValue(result['next_offset']);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && request == _request) {
        setState(() => _error = _collectionError(e));
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '选择${_collectionTypeName(widget.type)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        TextField(
          controller: _search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '搜索名称、艺术家、流派…',
          ),
          onChanged: (_) {
            _request++;
            _debounce?.cancel();
            _debounce = Timer(
              const Duration(milliseconds: 300),
              () => unawaited(_load()),
            );
          },
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        Expanded(
          child: ListView.builder(
            itemCount: _items.length + (_next == null ? 0 : 1),
            itemBuilder: (c, index) {
              if (index == _items.length) {
                return TextButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: const Text('加载更多'),
                );
              }
              final item = _items[index];
              final id = item['entity_id'] as int;
              return CheckboxListTile(
                value: widget.selected.contains(id) || _picked.containsKey(id),
                title: Text(_entityName(item)),
                subtitle: Text(_entitySubtitle(item)),
                onChanged: widget.selected.contains(id)
                    ? null
                    : (selected) {
                        setState(() {
                          if (widget.single) _picked.clear();
                          if (selected == true) {
                            _picked[id] = item;
                          } else {
                            _picked.remove(id);
                          }
                        });
                        if (widget.single && selected == true) {
                          Navigator.pop(context, _picked.values.toList());
                        }
                      },
              );
            },
          ),
        ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.pop(context, _picked.values.toList()),
          child: Text('添加 ${_picked.length} 项'),
        ),
      ],
    ),
  );
}
