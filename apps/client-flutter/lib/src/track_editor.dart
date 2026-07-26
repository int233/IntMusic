part of '../intmusic_client.dart';

class _TrackEditorDialog extends StatefulWidget {
  const _TrackEditorDialog({
    required this.api,
    required this.trackId,
    required this.snapshot,
  });

  final CoreApiClient api;
  final int trackId;
  final Map<String, dynamic> snapshot;

  @override
  State<_TrackEditorDialog> createState() => _TrackEditorDialogState();
}

class _TrackEditorDialogState extends State<_TrackEditorDialog> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, Map<String, dynamic>> _fieldStates = {};
  late final TextEditingController _lyricsController;
  late final TextEditingController _translationController;
  late final TextEditingController _pronunciationController;
  late final TextEditingController _languageController;
  late final TextEditingController _offsetController;
  late final String _initialLyricsSignature;

  int _section = 0;
  int _lyricsEditorMode = 0;
  bool _saving = false;
  bool _restoreFileLyrics = false;
  String? _error;
  String _lyricsKind = 'text';

  Map<String, dynamic> get _detail => _asMap(widget.snapshot['detail']);
  Map<String, dynamic> get _track => _asMap(_detail['track']);

  @override
  void initState() {
    super.initState();
    for (final raw in (widget.snapshot['fields'] as List?) ?? const []) {
      final field = Map<String, dynamic>.from(raw as Map);
      final key = field['key']?.toString() ?? '';
      if (key.isEmpty) continue;
      _fieldStates[key] = field;
      _controllers[key] = TextEditingController(
        text: _editorText(field['effective_value'], field['value_kind']),
      );
    }
    final lyrics = _detail['lyrics'] == null
        ? <String, dynamic>{}
        : _asMap(_detail['lyrics']);
    _lyricsKind = switch (lyrics['kind']?.toString().toLowerCase()) {
      'lrc' => 'lrc',
      'text' => 'text',
      final kind? when kind.isNotEmpty => kind,
      _ => _looksLikeLrc(lyrics['text']?.toString() ?? '') ? 'lrc' : 'text',
    };
    _lyricsController = TextEditingController(
      text: lyrics['text']?.toString() ?? '',
    );
    _translationController = TextEditingController(
      text: lyrics['translation']?.toString() ?? '',
    );
    _pronunciationController = TextEditingController(
      text: lyrics['pronunciation']?.toString() ?? '',
    );
    _languageController = TextEditingController(
      text: lyrics['language']?.toString() ?? '',
    );
    _offsetController = TextEditingController(
      text: (lyrics['offset_ms'] as num?)?.toInt().toString() ?? '0',
    );
    _initialLyricsSignature = _lyricsSignature();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _lyricsController.dispose();
    _translationController.dispose();
    _pronunciationController.dispose();
    _languageController.dispose();
    _offsetController.dispose();
    super.dispose();
  }

  String _editorText(Object? value, Object? valueKind) {
    if (value == null) return '';
    if (valueKind == 'string_list' && value is List) {
      return value.map((item) => item.toString()).join('; ');
    }
    return value.toString();
  }

  dynamic _fieldValue(String key) {
    final field = _fieldStates[key]!;
    final text = _controllers[key]!.text.trim();
    return switch (field['value_kind']?.toString()) {
      'integer' => text.isEmpty ? null : int.tryParse(text),
      'string_list' =>
        text
            .split(RegExp(r'[;\n]'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList(),
      _ => text.isEmpty ? null : text,
    };
  }

  String _lyricsSignature() => jsonEncode({
    'kind': _lyricsKind,
    'text': _lyricsController.text,
    'language': _languageController.text.trim(),
    'translation': _translationController.text,
    'pronunciation': _pronunciationController.text,
    'offset_ms': int.tryParse(_offsetController.text.trim()) ?? 0,
  });

  Future<void> _save() async {
    final title = _controllers['title']?.text.trim() ?? '';
    if (title.isEmpty) {
      setState(() {
        _section = 0;
        _error = _tr(context, 'Title cannot be empty');
      });
      return;
    }
    for (final entry in _fieldStates.entries) {
      if (entry.value['value_kind'] == 'integer') {
        final text = _controllers[entry.key]!.text.trim();
        if (text.isNotEmpty && int.tryParse(text) == null) {
          setState(() {
            _section = 0;
            _error =
                '${entry.value['label']} ${_tr(context, 'must be a number')}';
          });
          return;
        }
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final payload = <String, dynamic>{
        'expected_revision': _intValue(widget.snapshot['revision']),
        'fields': _fieldStates.keys
            .map(
              (key) => <String, dynamic>{'key': key, 'value': _fieldValue(key)},
            )
            .toList(),
        'clear_fields': <String>[],
        'clear_lyrics_override': _restoreFileLyrics,
      };
      if (!_restoreFileLyrics &&
          _lyricsSignature() != _initialLyricsSignature) {
        payload['lyrics'] = <String, dynamic>{
          'kind': _lyricsKind,
          'text': _lyricsController.text.trim(),
          'language': _nullIfEmpty(_languageController.text),
          'translation': _nullIfEmpty(_translationController.text),
          'pronunciation': _nullIfEmpty(_pronunciationController.text),
          'offset_ms': int.tryParse(_offsetController.text.trim()) ?? 0,
        };
      }
      final result = _asMap(
        await widget.api.postJson('/tracks/${widget.trackId}/edit', payload),
      );
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  String? _nullIfEmpty(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _markLyricsEdited() {
    setState(() => _restoreFileLyrics = false);
  }

  void _restoreLyricsFromFile() {
    final fileLyrics = widget.snapshot['file_lyrics'] == null
        ? <String, dynamic>{}
        : _asMap(widget.snapshot['file_lyrics']);
    setState(() {
      _restoreFileLyrics = true;
      _lyricsKind = fileLyrics['kind']?.toString() ?? 'text';
      _lyricsController.text = fileLyrics['text']?.toString() ?? '';
      _translationController.clear();
      _pronunciationController.clear();
      _languageController.clear();
      _offsetController.text = '0';
    });
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
          maxWidth: 1240,
          maxHeight: min(920, size.height - (size.width < 760 ? 16 : 48)),
        ),
        child: Column(
          children: [
            _toolbar(),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!, maxLines: 3),
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
                    0 => _informationSection(),
                    1 => _creditsSection(),
                    2 => _lyricsSection(),
                    _ => _fileSection(),
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
          icon: const Icon(Icons.badge_outlined),
          label: Text(_tr(context, 'Information')),
        ),
        ButtonSegment(
          value: 1,
          icon: const Icon(Icons.groups_outlined),
          label: Text(_tr(context, 'Credits')),
        ),
        ButtonSegment(
          value: 2,
          icon: const Icon(Icons.lyrics_outlined),
          label: Text(_tr(context, 'Lyrics')),
        ),
        ButtonSegment(
          value: 3,
          icon: const Icon(Icons.audio_file_outlined),
          label: Text(_tr(context, 'File')),
        ),
      ],
      selected: {_section},
      onSelectionChanged: (value) => setState(() => _section = value.first),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(_tr(context, 'Cancel')),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
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
              const Icon(Icons.tune_rounded),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _tr(context, 'Edit track'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 920) {
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
              SizedBox(width: 210, child: title),
              Expanded(child: Center(child: sections)),
              SizedBox(
                width: 210,
                child: Align(alignment: Alignment.centerRight, child: actions),
              ),
            ],
          );
        },
      ),
    );
  }

  void _mutate(VoidCallback mutation) => setState(mutation);
}
