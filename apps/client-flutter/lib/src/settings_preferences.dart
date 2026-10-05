part of '../intmusic_client.dart';

class _DeviceRegionPreferencesPanel extends StatelessWidget {
  const _DeviceRegionPreferencesPanel({
    required this.pinCurrentClientRegion,
    required this.regionSort,
    required this.onPinChanged,
    required this.onSortChanged,
  });

  final bool pinCurrentClientRegion;
  final _ZoneRegionSort regionSort;
  final ValueChanged<bool> onPinChanged;
  final ValueChanged<_ZoneRegionSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final orderSelector = DropdownButton<_ZoneRegionSort>(
      key: const Key('region-sort-dropdown'),
      value: regionSort,
      onChanged: (value) {
        if (value != null) {
          onSortChanged(value);
        }
      },
      items: [
        DropdownMenuItem(
          value: _ZoneRegionSort.playingFirst,
          child: Text(_tr(context, 'Playing first')),
        ),
        DropdownMenuItem(
          value: _ZoneRegionSort.name,
          child: Text(_tr(context, 'Name')),
        ),
      ],
    );
    return _HomePanel(
      title: _tr(context, 'Playback device regions'),
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _SettingsSwitchRow(
            key: const Key('pin-current-client-region'),
            value: pinCurrentClientRegion,
            title: "Pin this client's region",
            subtitle: "Keep this client's outputs at the top",
            onChanged: onPinChanged,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final description = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr(context, 'Region order'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      regionSort == _ZoneRegionSort.playingFirst
                          ? _tr(
                              context,
                              'Playing regions appear before idle regions',
                            )
                          : _tr(context, 'Regions are sorted by name'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  ],
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      description,
                      const SizedBox(height: 8),
                      orderSelector,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: description),
                    const SizedBox(width: 16),
                    orderSelector,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AliasEditor extends StatelessWidget {
  const _AliasEditor({
    required this.controller,
    required this.label,
    required this.icon,
    required this.loading,
    required this.onSave,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
            ),
            onSubmitted: (_) => onSave(),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: loading ? null : onSave,
          icon: const Icon(Icons.save_outlined),
          label: Text(_tr(context, 'Save')),
        ),
      ],
    );
  }
}

class _MetadataTagRulesPanel extends StatefulWidget {
  const _MetadataTagRulesPanel({
    required this.settings,
    required this.onUpdate,
  });
  final Map<String, dynamic>? settings;
  final Future<bool> Function(Map<String, dynamic>) onUpdate;
  @override
  State<_MetadataTagRulesPanel> createState() => _MetadataTagRulesPanelState();
}

const _tagMappingFields = <String, String>{
  'genres': '流派',
  'track_artists': '艺术家',
  'album_artists': '专辑艺术家',
  'composers': '作曲',
  'lyricists': '作词',
};

class _TagMappingDraft {
  _TagMappingDraft([Map<String, dynamic> value = const {}])
    : source = TextEditingController(text: value['source']?.toString() ?? ''),
      targets = [
        for (final text in (value['targets'] as List?) ?? [''])
          TextEditingController(text: text.toString()),
      ],
      fields = ((value['fields'] as List?) ?? [])
          .map((v) => v.toString())
          .toSet();
  final TextEditingController source;
  final List<TextEditingController> targets;
  final Set<String> fields;
  Map<String, dynamic> toJson() => {
    'source': source.text.trim(),
    'targets': targets.map((t) => t.text.trim()).toList(),
    'fields': _tagMappingFields.keys.where(fields.contains).toList(),
  };
  void dispose() {
    source.dispose();
    for (final target in targets) {
      target.dispose();
    }
  }
}

class _MetadataTagRulesPanelState extends State<_MetadataTagRulesPanel> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _artistController;
  late final TextEditingController _genreController;
  List<_TagMappingDraft> _rules = [];
  bool _dirty = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _artistController = TextEditingController();
    _genreController = TextEditingController();
    _loadSettings();
  }

  void _loadSettings() {
    _artistController.text = _separatorText(
      widget.settings?['artist_separators'],
    );
    _genreController.text = _separatorText(
      widget.settings?['genre_separators'],
    );
    for (final rule in _rules) {
      rule.dispose();
    }
    _rules = [
      for (final value in (widget.settings?['tag_mappings'] as List?) ?? [])
        _TagMappingDraft(_asMap(value)),
    ];
  }

  @override
  void didUpdateWidget(covariant _MetadataTagRulesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Background settings refreshes must not erase an unfinished rule.
    if (!_dirty && !_saving && oldWidget.settings != widget.settings) {
      _loadSettings();
    }
  }

  @override
  void dispose() {
    _artistController.dispose();
    _genreController.dispose();
    for (final rule in _rules) {
      rule.dispose();
    }
    super.dispose();
  }

  void _changed() {
    _dirty = true;
  }

  @override
  Widget build(BuildContext context) => _HomePanel(
    title: '标签处理规则',
    child: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _artistController,
            onChanged: (_) => _changed(),
            decoration: InputDecoration(
              labelText: _tr(context, 'Artist / composer / lyricist'),
              helperText: _tr(context, 'Separate delimiter tokens with spaces'),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _genreController,
            onChanged: (_) => _changed(),
            decoration: InputDecoration(
              labelText: _tr(context, 'Genre'),
              helperText: _tr(context, 'Default: comma and semicolon'),
            ),
          ),
          const SizedBox(height: 20),
          Text('自定义标签映射', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text(
            '先按分隔符拆分，再完整匹配原始标签。每条规则输出 1～5 个标签，仅应用于勾选的字段；输出不会继续拆分或触发其他规则。',
          ),
          const SizedBox(height: 12),
          if (_rules.isEmpty) const Text('暂无映射规则，不会自动拆分复合标签。'),
          for (final (index, rule) in _rules.indexed)
            Card(
              key: ObjectKey(rule),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('规则 ${index + 1}')),
                        IconButton(
                          tooltip: '删除规则',
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _rules.remove(rule);
                                  rule.dispose();
                                  _changed();
                                }),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    TextFormField(
                      key: ValueKey('mapping-source-$index'),
                      controller: rule.source,
                      enabled: !_saving,
                      onChanged: (_) => _changed(),
                      validator: (v) =>
                          (v?.trim().isEmpty ?? true) ? '请输入原始标签' : null,
                      decoration: const InputDecoration(
                        labelText: '原始标签',
                        hintText: '例如：国语流行',
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final (targetIndex, target) in rule.targets.indexed)
                      Padding(
                        key: ObjectKey(target),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: target,
                                enabled: !_saving,
                                onChanged: (_) => _changed(),
                                validator: (v) => (v?.trim().isEmpty ?? true)
                                    ? '请输入输出标签'
                                    : null,
                                decoration: InputDecoration(
                                  labelText: '输出标签 ${targetIndex + 1}',
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '删除输出标签',
                              onPressed: _saving || rule.targets.length == 1
                                  ? null
                                  : () => setState(() {
                                      rule.targets.remove(target);
                                      target.dispose();
                                      _changed();
                                    }),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _saving || rule.targets.length == 5
                            ? null
                            : () => setState(() {
                                rule.targets.add(TextEditingController());
                                _changed();
                              }),
                        icon: const Icon(Icons.add),
                        label: Text('添加输出标签（${rule.targets.length}/5）'),
                      ),
                    ),
                    const Text('应用字段（可多选）'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final field in _tagMappingFields.entries)
                          FilterChip(
                            label: Text(field.value),
                            selected: rule.fields.contains(field.key),
                            onSelected: _saving
                                ? null
                                : (selected) => setState(() {
                                    selected
                                        ? rule.fields.add(field.key)
                                        : rule.fields.remove(field.key);
                                    _changed();
                                  }),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                      _rules.add(_TagMappingDraft());
                      _changed();
                    }),
              icon: const Icon(Icons.add),
              label: const Text('添加映射规则'),
            ),
          ),
          const SizedBox(height: 12),
          const Text('“应用到已有资料”会根据原始标签及手工编辑值重新计算，支持修改或删除规则后重新应用，不改写音乐文件。'),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: _saving ? null : () => unawaited(_save(apply: true)),
                icon: const Icon(Icons.call_split),
                label: const Text('保存并应用到已有资料'),
              ),
              FilledButton.icon(
                onPressed: _saving ? null : () => unawaited(_save()),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('保存规则'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _save({bool apply = false}) async {
    if (!(_form.currentState?.validate() ?? false)) return;
    String? error;
    final occupied = <String>{};
    for (final rule in _rules) {
      if (rule.fields.isEmpty) {
        error = '请为每条规则选择至少一个应用字段';
        break;
      }
      final targets = rule.targets
          .map((t) => t.text.trim().toLowerCase())
          .toSet();
      if (targets.length != rule.targets.length) {
        error = '同一规则的输出标签不能重复';
        break;
      }
      for (final field in rule.fields) {
        if (!occupied.add('$field\u0000${rule.source.text.trim()}')) {
          error = '同一原始标签在同一字段中只能有一条规则';
        }
      }
    }
    setState(() => _error = error);
    if (error != null) return;
    setState(() => _saving = true);
    try {
      final saved = await widget.onUpdate({
        'artist_separators': _parseSeparators(_artistController.text),
        'genre_separators': _parseSeparators(_genreController.text),
        'tag_mappings': _rules.map((r) => r.toJson()).toList(),
      });
      if (!mounted) return;
      if (!saved) {
        setState(() => _error = '保存失败，规则尚未应用，请重试。');
        return;
      }
      _dirty = false;
      if (apply) {
        await _TrackActionScope.maybeOf(context)?.onApplyTagMappings?.call();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('规则已保存')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

String _separatorText(Object? value) {
  final items = (value as List?)?.map((item) => item.toString()).toList();
  if (items == null || items.isEmpty) {
    return ', ;';
  }
  return items.join(' ');
}

List<String> _parseSeparators(String text) {
  final values = text
      .split(RegExp(r'\s+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList();
  return values.isEmpty ? [',', ';'] : values;
}

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    super.key,
    required this.value,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  final bool value;
  final String title;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr(context, title),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _tr(context, subtitle),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}
