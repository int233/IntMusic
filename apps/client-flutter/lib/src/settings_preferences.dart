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
