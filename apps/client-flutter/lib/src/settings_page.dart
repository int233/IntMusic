part of '../main.dart';

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.coreUrlController,
    required this.serverAliasController,
    required this.clientAliasController,
    required this.loading,
    required this.status,
    required this.rendererStatus,
    required this.settings,
    required this.metadataSettings,
    required this.libraryRoots,
    required this.diagnostics,
    required this.language,
    required this.libraryRootController,
    required this.onConnect,
    required this.onDiscover,
    required this.onScan,
    required this.onAddLibraryRoot,
    required this.onRemoveLibraryRoot,
    required this.onSaveServerAlias,
    required this.onSaveClientAlias,
    required this.onLanguageChanged,
    required this.onUpdateFavoriteSettings,
    required this.onUpdateMetadataSettings,
  });

  final TextEditingController coreUrlController;
  final TextEditingController serverAliasController;
  final TextEditingController clientAliasController;
  final bool loading;
  final Map<String, dynamic>? status;
  final String? rendererStatus;
  final Map<String, dynamic>? settings;
  final Map<String, dynamic>? metadataSettings;
  final List<dynamic> libraryRoots;
  final Map<String, dynamic>? diagnostics;
  final _AppLanguage language;
  final TextEditingController libraryRootController;
  final VoidCallback onConnect;
  final VoidCallback onDiscover;
  final VoidCallback onScan;
  final VoidCallback onAddLibraryRoot;
  final ValueChanged<int> onRemoveLibraryRoot;
  final VoidCallback onSaveServerAlias;
  final VoidCallback onSaveClientAlias;
  final ValueChanged<_AppLanguage> onLanguageChanged;
  final Future<void> Function(Map<String, dynamic>) onUpdateFavoriteSettings;
  final Future<void> Function(Map<String, dynamic>) onUpdateMetadataSettings;

  @override
  Widget build(BuildContext context) {
    final treatMax = settings?['treat_max_rating_as_favorite'] != false;
    final writeRating = settings?['write_rating_on_favorite'] == true;
    final counts =
        (status?['counts'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    return _PageFrame(
      title: 'Settings',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
        children: [
          _HomePanel(
            title: _tr(context, 'Core Server'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 640;
                    final input = TextField(
                      controller: coreUrlController,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Core URL'),
                        prefixIcon: const Icon(Icons.hub_outlined),
                      ),
                      onSubmitted: (_) => onConnect(),
                    );
                    final actionButtons = [
                      FilledButton.icon(
                        onPressed: loading ? null : onConnect,
                        icon: loading
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.link),
                        label: Text(_tr(context, 'Connect')),
                      ),
                      OutlinedButton.icon(
                        onPressed: loading ? null : onDiscover,
                        icon: const Icon(Icons.travel_explore_outlined),
                        label: Text(_tr(context, 'Discover')),
                      ),
                    ];
                    final actions = Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.start,
                      children: [
                        for (final button in actionButtons)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: narrow
                                  ? constraints.maxWidth
                                  : double.infinity,
                            ),
                            child: button,
                          ),
                      ],
                    );
                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [input, const SizedBox(height: 10), actions],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: input),
                        const SizedBox(width: 10),
                        actions,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                _InfoRow(
                  label: _tr(context, 'Renderer'),
                  value: rendererStatus ?? 'pending',
                ),
                _InfoRow(
                  label: _tr(context, 'Version'),
                  value: status?['version']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: _tr(context, 'API'),
                  value: status?['api_version']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: _tr(context, 'Database'),
                  value: status?['database_path']?.toString() ?? '-',
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _LibraryRootsPanel(
            roots: libraryRoots,
            controller: libraryRootController,
            loading: loading,
            onAddFolder: onAddLibraryRoot,
            onRemoveFolder: onRemoveLibraryRoot,
            onScan: onScan,
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Aliases'),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 640;
                final serverField = _AliasEditor(
                  controller: serverAliasController,
                  label: _tr(context, 'Server alias'),
                  icon: Icons.dns_outlined,
                  loading: loading,
                  onSave: onSaveServerAlias,
                );
                final clientField = _AliasEditor(
                  controller: clientAliasController,
                  label: _tr(context, 'Client alias'),
                  icon: Icons.devices_outlined,
                  loading: loading,
                  onSave: onSaveClientAlias,
                );
                if (narrow) {
                  return Column(
                    children: [
                      serverField,
                      const SizedBox(height: 12),
                      clientField,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: serverField),
                    const SizedBox(width: 12),
                    Expanded(child: clientField),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Favorites'),
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsSwitchRow(
                  value: treatMax,
                  title: 'Max rating counts as favorite',
                  subtitle:
                      'RATING 5/5, 100/100, or POPM 255 is shown as favorite',
                  onChanged: (value) => onUpdateFavoriteSettings(
                    <String, dynamic>{'treat_max_rating_as_favorite': value},
                  ),
                ),
                const Divider(height: 1),
                _SettingsSwitchRow(
                  value: writeRating,
                  title: 'Favorite writes max rating',
                  subtitle: 'Writes the maximum rating tag when enabled',
                  onChanged: (value) => onUpdateFavoriteSettings(
                    <String, dynamic>{'write_rating_on_favorite': value},
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Language'),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _tr(context, 'Interface language'),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                SegmentedButton<_AppLanguage>(
                  segments: [
                    ButtonSegment(
                      value: _AppLanguage.en,
                      label: Text(_tr(context, 'English')),
                    ),
                    ButtonSegment(
                      value: _AppLanguage.zh,
                      label: Text(_tr(context, 'Chinese')),
                    ),
                  ],
                  selected: {language},
                  onSelectionChanged: (values) =>
                      onLanguageChanged(values.first),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _MetadataSeparatorsPanel(
            settings: metadataSettings,
            onUpdate: onUpdateMetadataSettings,
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Diagnostics'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoRow(
                  label: _tr(context, 'Library'),
                  value: _joinParts([
                    '${counts['tracks'] ?? 0} ${_tr(context, 'Tracks')}',
                    '${counts['albums'] ?? 0} ${_tr(context, 'Albums')}',
                    '${counts['scan_problems'] ?? 0} scan problems',
                  ]),
                ),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: appSurfaceHigh,
                    border: Border.all(color: appBorder),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 260,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        const JsonEncoder.withIndent(
                          '  ',
                        ).convert(diagnostics ?? const <String, dynamic>{}),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
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

class _LibraryRootsPanel extends StatelessWidget {
  const _LibraryRootsPanel({
    required this.roots,
    required this.controller,
    required this.loading,
    required this.onAddFolder,
    required this.onRemoveFolder,
    required this.onScan,
  });

  final List<dynamic> roots;
  final TextEditingController controller;
  final bool loading;
  final VoidCallback onAddFolder;
  final ValueChanged<int> onRemoveFolder;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: _tr(context, 'Music folders'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 700;
              final input = TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: _tr(context, 'Core-side folder path'),
                  helperText: _tr(
                    context,
                    'Use a path that the Core server can access',
                  ),
                  prefixIcon: const Icon(Icons.folder_outlined),
                ),
                onSubmitted: (_) => onAddFolder(),
              );
              final buttons = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: loading ? null : onAddFolder,
                    icon: const Icon(Icons.add),
                    label: Text(_tr(context, 'Add folder')),
                  ),
                  OutlinedButton.icon(
                    onPressed: loading ? null : onScan,
                    icon: const Icon(Icons.radar_outlined),
                    label: Text(_tr(context, 'Rescan library')),
                  ),
                ],
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [input, const SizedBox(height: 10), buttons],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: input),
                  const SizedBox(width: 10),
                  Flexible(child: buttons),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          if (roots.isEmpty)
            Text(
              _tr(context, 'No music folders configured'),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xff9aa1ab)),
            )
          else
            Column(
              children: [
                for (final root in roots)
                  _LibraryRootRow(
                    root: (root as Map).cast<String, dynamic>(),
                    loading: loading,
                    onRemove: onRemoveFolder,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LibraryRootRow extends StatelessWidget {
  const _LibraryRootRow({
    required this.root,
    required this.loading,
    required this.onRemove,
  });

  final Map<String, dynamic> root;
  final bool loading;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final id = _intValue(root['id']);
    final enabled = root['enabled'] != false;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: appSurfaceHigh,
        border: Border.all(color: appBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.folder_outlined : Icons.folder_off_outlined,
            color: enabled ? appPrimary : const Color(0xff9aa1ab),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              root['path']?.toString() ?? '-',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: _tr(context, 'Remove'),
            onPressed: loading || id == null ? null : () => onRemove(id),
            icon: const Icon(Icons.delete_outline),
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

class _MetadataSeparatorsPanel extends StatefulWidget {
  const _MetadataSeparatorsPanel({
    required this.settings,
    required this.onUpdate,
  });

  final Map<String, dynamic>? settings;
  final Future<void> Function(Map<String, dynamic>) onUpdate;

  @override
  State<_MetadataSeparatorsPanel> createState() =>
      _MetadataSeparatorsPanelState();
}

class _MetadataSeparatorsPanelState extends State<_MetadataSeparatorsPanel> {
  late final TextEditingController _artistController;
  late final TextEditingController _genreController;

  @override
  void initState() {
    super.initState();
    _artistController = TextEditingController(
      text: _separatorText(widget.settings?['artist_separators']),
    );
    _genreController = TextEditingController(
      text: _separatorText(widget.settings?['genre_separators']),
    );
  }

  @override
  void didUpdateWidget(covariant _MetadataSeparatorsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings != widget.settings) {
      _artistController.text = _separatorText(
        widget.settings?['artist_separators'],
      );
      _genreController.text = _separatorText(
        widget.settings?['genre_separators'],
      );
    }
  }

  @override
  void dispose() {
    _artistController.dispose();
    _genreController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: _tr(context, 'Metadata separators'),
      child: Column(
        children: [
          TextField(
            controller: _artistController,
            decoration: InputDecoration(
              labelText: _tr(context, 'Artist / composer / lyricist'),
              helperText: _tr(context, 'Separate delimiter tokens with spaces'),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _genreController,
            decoration: InputDecoration(
              labelText: _tr(context, 'Genre'),
              helperText: _tr(context, 'Default: comma and semicolon'),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_tr(context, 'Save')),
            ),
          ),
        ],
      ),
    );
  }

  void _save() {
    unawaited(
      widget.onUpdate(<String, dynamic>{
        'artist_separators': _parseSeparators(_artistController.text),
        'genre_separators': _parseSeparators(_genreController.text),
      }),
    );
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
                        color: const Color(0xff9aa1ab),
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
