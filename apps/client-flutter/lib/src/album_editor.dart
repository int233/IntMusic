part of '../intmusic_client.dart';

const _albumProfileFields = <(String, String, String)>[
  ('title', 'Album title', 'string'),
  ('sort_title', 'Sort title', 'string'),
  ('subtitle', 'Subtitle', 'string'),
  ('release_type', 'Release type', 'string'),
  ('edition_title', 'Edition title', 'string'),
  ('release_status', 'Release status', 'string'),
  ('date', 'Release date', 'string'),
  ('original_date', 'Original release date', 'string'),
  ('year', 'Year', 'integer'),
  ('total_discs', 'Total discs', 'integer'),
  ('country', 'Release country', 'string'),
  ('language', 'Language', 'string'),
  ('media_format', 'Media format', 'string'),
  ('packaging', 'Packaging', 'string'),
  ('barcode', 'Barcode / UPC', 'string'),
  ('catalog_numbers', 'Catalog numbers', 'list'),
  ('labels', 'Record labels', 'list'),
  ('publishers', 'Publishers', 'list'),
  ('genres', 'Genres', 'list'),
  ('styles', 'Styles', 'list'),
  ('moods', 'Moods', 'list'),
  ('copyright', 'Copyright', 'string'),
  ('phonographic_copyright', 'Phonographic copyright', 'string'),
  ('notes', 'Editorial notes', 'multiline'),
];

const _albumCreditRoles = <(String, String)>[
  ('album_artist', 'Album artist'),
  ('primary_artist', 'Primary artist'),
  ('featured_artist', 'Featured artist'),
  ('producer', 'Producer'),
  ('executive_producer', 'Executive producer'),
  ('composer', 'Composer'),
  ('lyricist', 'Lyricist'),
  ('arranger', 'Arranger'),
  ('conductor', 'Conductor'),
  ('performer', 'Performer'),
  ('instrumentalist', 'Instrumentalist'),
  ('vocalist', 'Vocalist'),
  ('orchestra', 'Orchestra'),
  ('ensemble', 'Ensemble'),
  ('choir', 'Choir'),
  ('recording_engineer', 'Recording engineer'),
  ('mixing_engineer', 'Mixing engineer'),
  ('mastering_engineer', 'Mastering engineer'),
  ('remixer', 'Remixer'),
  ('dj', 'DJ'),
  ('art_direction', 'Art direction'),
  ('photography', 'Photography'),
  ('liner_notes', 'Liner notes'),
  ('record_label', 'Record label'),
  ('publisher', 'Publisher'),
  ('distributor', 'Distributor'),
];

class _AlbumEditorDialog extends StatefulWidget {
  const _AlbumEditorDialog({
    required this.api,
    required this.albumId,
    required this.snapshot,
  });

  final CoreApiClient api;
  final int albumId;
  final Map<String, dynamic> snapshot;

  @override
  State<_AlbumEditorDialog> createState() => _AlbumEditorDialogState();
}

class _AlbumEditorDialogState extends State<_AlbumEditorDialog> {
  final Map<String, TextEditingController> _controllers = {};
  final List<Map<String, dynamic>> _credits = [];
  final Set<int> _selectedTrackIds = {};
  final Set<String> _propagationFields = {};
  final TextEditingController _migrationSearchController =
      TextEditingController();

  late final List<Map<String, dynamic>> _tracks;
  late final List<Map<String, dynamic>> _artistOptions;
  List<Map<String, dynamic>> _migrationCandidates = const [];
  int? _migrationTargetId;
  int _section = 0;
  bool _saving = false;
  bool _searchingAlbums = false;
  bool _migrating = false;
  String? _error;

  Map<String, dynamic> get _detail => _asMap(widget.snapshot['detail']);
  Map<String, dynamic> get _album => _asMap(_detail['album']);

  void _change(VoidCallback mutation) {
    if (!mounted) return;
    setState(mutation);
  }

  @override
  void initState() {
    super.initState();
    final profile = _asMap(_detail['profile']);
    for (final field in _albumProfileFields) {
      final value =
          profile[field.$1] ??
          switch (field.$1) {
            'title' => _album['title'],
            'year' => _album['year'],
            'date' => _album['date'],
            'total_discs' => _album['total_discs'],
            _ => null,
          };
      _controllers[field.$1] = TextEditingController(
        text: value is List ? value.join('; ') : value?.toString() ?? '',
      );
    }
    for (final value in (_detail['credits'] as List?) ?? const []) {
      if (value is Map) _credits.add(Map<String, dynamic>.from(value));
    }
    _tracks = ((_detail['tracks'] as List?) ?? const [])
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .toList(growable: false);
    _artistOptions = ((widget.snapshot['artist_options'] as List?) ?? const [])
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .toList(growable: false);
    _migrationSearchController.text = _album['title']?.toString() ?? '';
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _migrationSearchController.dispose();
    super.dispose();
  }

  dynamic _profileValue(String key, String kind) {
    final text = _controllers[key]!.text.trim();
    return switch (kind) {
      'integer' => text.isEmpty ? null : int.tryParse(text),
      'list' =>
        text
            .split(RegExp(r'[;\n]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList(growable: false),
      _ => text.isEmpty ? null : text,
    };
  }

  void _selectSection(int section) {
    _change(() => _section = section);
    if (section == 3 &&
        _migrationCandidates.isEmpty &&
        !_searchingAlbums &&
        _migrationSearchController.text.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchMigrationAlbums();
      });
    }
  }

  Future<void> _save() async {
    final title = _controllers['title']!.text.trim();
    if (title.isEmpty) {
      setState(() {
        _section = 0;
        _error = _tr(context, 'Album title cannot be empty');
      });
      return;
    }
    for (final field in _albumProfileFields.where(
      (field) => field.$3 == 'integer',
    )) {
      final text = _controllers[field.$1]!.text.trim();
      if (text.isNotEmpty && int.tryParse(text) == null) {
        setState(() {
          _section = 0;
          _error =
              '${_tr(context, field.$2)} ${_tr(context, 'must be a number')}';
        });
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final profile = <String, dynamic>{
        for (final field in _albumProfileFields)
          field.$1: _profileValue(field.$1, field.$3),
      };
      final payload = <String, dynamic>{
        'expected_revision': _intValue(widget.snapshot['revision']),
        'profile': profile,
        'credits': _credits
            .where(
              (credit) =>
                  (credit['display_name']?.toString().trim() ?? '').isNotEmpty,
            )
            .map(
              (credit) => <String, dynamic>{
                'artist_id': _intValue(credit['artist_id']),
                'artist_name': credit['artist_name']?.toString(),
                'display_name': credit['display_name']?.toString().trim(),
                'role': credit['role']?.toString() ?? 'performer',
                'position': _credits.indexOf(credit),
              },
            )
            .toList(growable: false),
        if (_selectedTrackIds.isNotEmpty && _propagationFields.isNotEmpty)
          'propagate': <String, dynamic>{
            'track_ids': _selectedTrackIds.toList(growable: false),
            'fields': _propagationFields.toList(growable: false),
          },
      };
      final result = _asMap(
        await widget.api.postJson('/albums/${widget.albumId}/edit', payload),
      );
      if (!mounted) return;
      Navigator.pop(context, <String, dynamic>{
        'action': 'saved',
        'snapshot': result,
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: EdgeInsets.all(size.width < 760 ? 8 : 24),
      clipBehavior: Clip.antiAlias,
      backgroundColor: tokens.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size.width < 760 ? 18 : 22),
        side: BorderSide(color: tokens.stroke),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1280,
          maxHeight: min(920, size.height - (size.width < 760 ? 16 : 48)),
        ),
        child: Column(
          children: [
            _toolbar(),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!, maxLines: 4),
                leading: const Icon(Icons.error_outline),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: Text(_tr(context, 'Dismiss')),
                  ),
                ],
              ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: KeyedSubtree(
                  key: ValueKey(_section),
                  child: switch (_section) {
                    0 => _albumInformationSection(),
                    1 => _albumCreditsSection(),
                    2 => _albumBatchSection(),
                    _ => _albumMigrationSection(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    final sections = SegmentedButton<int>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: 0,
          icon: const Icon(Icons.album_outlined),
          label: Text(_tr(context, 'Information')),
        ),
        ButtonSegment(
          value: 1,
          icon: const Icon(Icons.groups_outlined),
          label: Text(_tr(context, 'Credits')),
        ),
        ButtonSegment(
          value: 2,
          icon: const Icon(Icons.library_add_check_outlined),
          label: Text(_tr(context, 'Batch tracks')),
        ),
        ButtonSegment(
          value: 3,
          icon: const Icon(Icons.drive_file_move_outline),
          label: Text(_tr(context, 'Organize')),
        ),
      ],
      selected: {_section},
      onSelectionChanged: (value) => _selectSection(value.first),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: _saving || _migrating
              ? null
              : () => Navigator.pop(context),
          child: Text(_tr(context, 'Cancel')),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _saving || _migrating ? null : _save,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check),
          label: Text(_tr(context, 'Save')),
        ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised.withValues(alpha: 0.92),
        border: Border(
          bottom: BorderSide(color: IntMusicTheme.of(context).stroke),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Row(
            children: [
              const Icon(Icons.edit_note_rounded),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _tr(context, 'Edit album'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 980) {
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(child: title),
                    actions,
                  ],
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: sections,
                ),
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 220, child: title),
              Expanded(child: Center(child: sections)),
              SizedBox(
                width: 220,
                child: Align(alignment: Alignment.centerRight, child: actions),
              ),
            ],
          );
        },
      ),
    );
  }
}
