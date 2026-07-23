part of '../main.dart';

class _PlaylistsPage extends StatefulWidget {
  const _PlaylistsPage({
    required this.playlists,
    required this.onOpenPlaylist,
    required this.onCreateManual,
    required this.onCreateSmart,
    required this.onDeletePlaylist,
    required this.viewMode,
    required this.onViewModeChanged,
  });

  final List<dynamic> playlists;
  final Future<void> Function(int) onOpenPlaylist;
  final Future<void> Function() onCreateManual;
  final Future<void> Function() onCreateSmart;
  final Future<void> Function(int) onDeletePlaylist;
  final _LibraryViewMode viewMode;
  final ValueChanged<_LibraryViewMode> onViewModeChanged;

  @override
  State<_PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<_PlaylistsPage> {
  String _query = '';
  String _sort = 'name';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final playlists = widget.playlists
        .where((item) {
          if (query.isEmpty) {
            return true;
          }
          final playlist = (item as Map).cast<String, dynamic>();
          return '${playlist['name'] ?? ''}\u0000'
                  '${playlist['description'] ?? ''}\u0000'
                  '${playlist['kind'] ?? ''}'
              .toLowerCase()
              .contains(query);
        })
        .toList(growable: false);
    playlists.sort((left, right) {
      final a = (left as Map).cast<String, dynamic>();
      final b = (right as Map).cast<String, dynamic>();
      return switch (_sort) {
        'tracks' => _compareLibraryNumber(
          b['track_count'],
          a['track_count'],
          secondaryA: a['name'],
          secondaryB: b['name'],
        ),
        'kind' => _compareLibraryText(
          a['kind'],
          b['kind'],
          secondaryA: a['name'],
          secondaryB: b['name'],
        ),
        _ => _compareLibraryText(a['name'], b['name']),
      };
    });
    return _PageFrame(
      title: 'Playlists',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: widget.onCreateManual,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Manual'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: widget.onCreateSmart,
                  icon: const Icon(Icons.auto_awesome_motion_outlined),
                  label: const Text('Smart'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
            child: _LibraryToolbar(
              countLabel: query.isEmpty
                  ? '${playlists.length} playlists'
                  : '${playlists.length} of ${widget.playlists.length} playlists',
              searchHint: _tr(context, 'Filter playlists'),
              onQueryChanged: (value) => setState(() => _query = value),
              sortValue: _sort,
              sortOptions: {
                'name': _tr(context, 'Name'),
                'tracks': _tr(context, 'Most tracks'),
                'kind': _tr(context, 'Type'),
              },
              onSortChanged: (value) => setState(() => _sort = value),
              viewMode: widget.viewMode,
              onViewModeChanged: widget.onViewModeChanged,
            ),
          ),
          Expanded(
            child: playlists.isEmpty
                ? const Center(child: Text('No playlists'))
                : widget.viewMode == _LibraryViewMode.grid
                ? GridView.builder(
                    key: const PageStorageKey('playlists-grid'),
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 360,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: 2.35,
                        ),
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = (playlists[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(playlist['id']);
                      return _PlaylistCard(
                        playlist: playlist,
                        onOpen: id == null
                            ? null
                            : () => unawaited(widget.onOpenPlaylist(id)),
                        onDelete: id == null
                            ? null
                            : () => unawaited(widget.onDeletePlaylist(id)),
                      );
                    },
                  )
                : ListView.separated(
                    key: const PageStorageKey('playlists-list'),
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
                    itemCount: playlists.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final playlist = (playlists[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(playlist['id']);
                      final kind = playlist['kind']?.toString() ?? 'manual';
                      final name = playlist['name']?.toString() ?? 'Untitled';
                      return _SimpleListRow(
                        leading: _ArtworkTile(
                          title: name,
                          subtitle: kind,
                          size: 48,
                          icon: kind == 'smart'
                              ? Icons.auto_awesome_motion_outlined
                              : Icons.queue_music_outlined,
                        ),
                        title: name,
                        subtitle: _joinParts([
                          kind,
                          '${playlist['track_count'] ?? 0} tracks',
                          playlist['description'],
                        ]),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: _tr(context, 'Delete'),
                              onPressed: id == null
                                  ? null
                                  : () =>
                                        unawaited(widget.onDeletePlaylist(id)),
                              icon: const Icon(Icons.delete_outline),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: id == null
                            ? null
                            : () => unawaited(widget.onOpenPlaylist(id)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({
    required this.playlist,
    required this.onOpen,
    required this.onDelete,
  });

  final Map<String, dynamic> playlist;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final kind = playlist['kind']?.toString() ?? 'manual';
    final smart = kind == 'smart';
    final name = playlist['name']?.toString() ?? 'Untitled';
    final description = _joinParts([
      kind,
      '${playlist['track_count'] ?? 0} tracks',
      playlist['description'],
    ]);

    return Material(
      color: IntMusicTheme.of(context).surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: IntMusicTheme.of(context).stroke),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                _ArtworkTile(
                  title: name,
                  subtitle: kind,
                  size: 68,
                  icon: smart
                      ? Icons.auto_awesome_motion_outlined
                      : Icons.queue_music_outlined,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: IntMusicTheme.of(context).textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                _AppTooltip(
                  message: 'Delete',
                  child: IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistDetailPage extends StatelessWidget {
  const _PlaylistDetailPage({
    required this.coreBaseUrl,
    required this.detail,
    required this.onPlayTrack,
    required this.onOpenTrack,
    required this.onToggleFavorite,
    required this.onEditSmart,
    required this.onRemoveTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic> detail;
  final Future<void> Function(int) onPlayTrack;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function() onEditSmart;
  final Future<void> Function(int) onRemoveTrack;

  @override
  Widget build(BuildContext context) {
    final playlist = _asMap(detail['playlist']);
    final tracks = (detail['tracks'] as List?) ?? const [];
    final kind = playlist['kind']?.toString() ?? 'manual';
    final rules = detail['rules'];

    return _PageFrame(
      title: 'Playlist detail',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
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
          ),
          if (kind == 'smart')
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _smartRulesLabel(rules),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(onEditSmart()),
                    icon: const Icon(Icons.tune_outlined),
                    label: Text(_tr(context, 'Edit rules')),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: tracks.isEmpty
                ? const Center(child: Text('No matching tracks'))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: tracks.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final track = (tracks[index] as Map)
                          .cast<String, dynamic>();
                      final id = _intValue(track['id']);
                      return _SheetTrackRow(
                        coreBaseUrl: coreBaseUrl,
                        track: track,
                        indexLabel: '${index + 1}',
                        subtitle: _joinParts([
                          track['artist_display'],
                          track['album_title'],
                          _formatDuration(track['duration_ms']),
                        ]),
                        onOpen: id == null
                            ? null
                            : () => unawaited(onOpenTrack(id)),
                        onPlay: id == null
                            ? null
                            : () => unawaited(onPlayTrack(id)),
                        onToggleFavorite: onToggleFavorite,
                        onRemove: kind == 'manual' && id != null
                            ? () => unawaited(onRemoveTrack(id))
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ManualPlaylistSheet extends StatefulWidget {
  const _ManualPlaylistSheet();

  @override
  State<_ManualPlaylistSheet> createState() => _ManualPlaylistSheetState();
}

class _ManualPlaylistSheetState extends State<_ManualPlaylistSheet> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Manual Playlist',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            decoration: const InputDecoration(
              labelText: 'Description',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () {
                final name = _nameController.text.trim();
                if (name.isEmpty) {
                  return;
                }
                Navigator.of(context).pop(<String, dynamic>{
                  'name': name,
                  'kind': 'manual',
                  'description': _descriptionController.text.trim(),
                });
              },
              icon: const Icon(Icons.check),
              label: const Text('Create'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SmartPlaylistSheet extends StatefulWidget {
  const _SmartPlaylistSheet({this.detail});

  final Map<String, dynamic>? detail;

  @override
  State<_SmartPlaylistSheet> createState() => _SmartPlaylistSheetState();
}

class _SmartPlaylistSheetState extends State<_SmartPlaylistSheet> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final List<_SmartRuleDraft> _rules = [];
  String _match = 'all';

  bool get _editing => widget.detail != null;

  @override
  void initState() {
    super.initState();
    final detail = widget.detail;
    if (detail == null) {
      _rules.add(_SmartRuleDraft());
      return;
    }
    final playlist = _asMap(detail['playlist']);
    _nameController.text = playlist['name']?.toString() ?? '';
    _descriptionController.text = playlist['description']?.toString() ?? '';
    final rules = detail['rules'];
    if (rules is Map) {
      final rulesMap = rules.cast<String, dynamic>();
      _match = rulesMap['match']?.toString() == 'any' ? 'any' : 'all';
      final ruleList = (rulesMap['rules'] as List?) ?? const [];
      _rules.addAll(
        ruleList.whereType<Map>().map(
          (rule) => _SmartRuleDraft.fromJson(rule.cast<String, dynamic>()),
        ),
      );
    }
    if (_rules.isEmpty) {
      _rules.add(_SmartRuleDraft());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    for (final rule in _rules) {
      rule.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        4,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _editing ? _tr(context, 'Edit Smart Playlist') : 'Smart Playlist',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('All rules')),
                ButtonSegment(value: 'any', label: Text('Any rule')),
              ],
              selected: {_match},
              onSelectionChanged: (value) =>
                  setState(() => _match = value.first),
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < _rules.length; index++)
              _SmartRuleRow(
                key: ValueKey(_rules[index]),
                rule: _rules[index],
                canRemove: _rules.length > 1,
                onChanged: () => setState(() {}),
                onRemove: () =>
                    setState(() => _rules.removeAt(index).dispose()),
              ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(() => _rules.add(_SmartRuleDraft())),
              icon: const Icon(Icons.add),
              label: const Text('Add rule'),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () {
                  final name = _nameController.text.trim();
                  final rules = _rules
                      .map((rule) => rule.toJson())
                      .where(
                        (rule) => rule['value'].toString().trim().isNotEmpty,
                      )
                      .toList(growable: false);
                  if (name.isEmpty || rules.isEmpty) {
                    return;
                  }
                  Navigator.of(context).pop(<String, dynamic>{
                    'name': name,
                    if (!_editing) 'kind': 'smart',
                    'description': _descriptionController.text.trim(),
                    'rules': <String, dynamic>{'match': _match, 'rules': rules},
                  });
                },
                icon: const Icon(Icons.check),
                label: Text(_editing ? _tr(context, 'Save') : 'Create'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmartRuleDraft {
  String field = 'artist';
  String op = 'contains';
  final valueController = TextEditingController();

  _SmartRuleDraft();

  factory _SmartRuleDraft.fromJson(Map<String, dynamic> json) {
    final draft = _SmartRuleDraft();
    final field = json['field']?.toString();
    if (field != null && _smartFields.contains(field)) {
      draft.field = field;
    }
    draft.op =
        json['op']?.toString() ?? json['operator']?.toString() ?? draft.op;
    draft.valueController.text = json['value']?.toString() ?? '';
    return draft;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'field': field,
    'op': op,
    'value': _ruleValue(field, valueController.text),
  };

  void dispose() {
    valueController.dispose();
  }
}

class _SmartRuleRow extends StatelessWidget {
  const _SmartRuleRow({
    super.key,
    required this.rule,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final _SmartRuleDraft rule;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final numeric = _numericSmartFields.contains(rule.field);
    final boolField = rule.field == 'favorite';
    final ops = boolField
        ? const ['is']
        : numeric
        ? const ['gte', 'lte', 'equals', 'gt', 'lt']
        : const ['contains', 'equals', 'starts_with', 'ends_with'];
    if (!ops.contains(rule.op)) {
      rule.op = ops.first;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: rule.field,
              decoration: const InputDecoration(
                labelText: 'Field',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _smartFields
                  .map(
                    (field) =>
                        DropdownMenuItem(value: field, child: Text(field)),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  rule.field = value;
                  onChanged();
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              initialValue: rule.op,
              decoration: const InputDecoration(
                labelText: 'Op',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: ops
                  .map((op) => DropdownMenuItem(value: op, child: Text(op)))
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  rule.op = value;
                  onChanged();
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: rule.valueController,
              decoration: InputDecoration(
                labelText: boolField ? 'true / false' : 'Value',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: numeric ? TextInputType.number : TextInputType.text,
            ),
          ),
          _AppTooltip(
            message: 'Remove rule',
            child: IconButton(
              onPressed: canRemove ? onRemove : null,
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddToPlaylistSheet extends StatelessWidget {
  const _AddToPlaylistSheet({required this.playlists});

  final List<dynamic> playlists;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
            child: Text(
              'Add to Playlist',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: playlists.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final playlist = _asMap(playlists[index]);
                final id = _intValue(playlist['id']);
                final name = playlist['name']?.toString() ?? 'Untitled';
                return _SimpleListRow(
                  leading: _ArtworkTile(
                    title: name,
                    subtitle: 'playlist',
                    size: 42,
                    icon: Icons.queue_music_outlined,
                  ),
                  title: name,
                  subtitle: '${playlist['track_count'] ?? 0} tracks',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: id == null
                      ? null
                      : () => Navigator.of(context).pop(id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
