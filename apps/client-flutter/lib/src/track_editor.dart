part of '../main.dart';

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

  Widget _informationSection() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        _summaryCard(),
        const SizedBox(height: 16),
        _sectionCard(
          title: _tr(context, 'Identity'),
          subtitle: _tr(
            context,
            'Manual values stay in IntMusic and are not replaced by rescans.',
          ),
          keys: const ['title', 'sort_title', 'subtitle'],
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: _tr(context, 'Album and numbering'),
          subtitle: _tr(
            context,
            'Album-level changes may regroup this track in the library.',
          ),
          keys: const [
            'album',
            'date',
            'year',
            'disc_number',
            'disc_total',
            'track_number',
            'track_total',
          ],
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: _tr(context, 'Musical properties'),
          keys: const ['bpm', 'comment'],
        ),
      ],
    );
  }

  Widget _creditsSection() {
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        _sectionCard(
          title: _tr(context, 'Artists and credits'),
          subtitle: _tr(
            context,
            'Separate multiple values with semicolons or new lines.',
          ),
          keys: const [
            'track_artists',
            'album_artists',
            'composers',
            'lyricists',
          ],
          multiline: true,
        ),
        const SizedBox(height: 16),
        _sectionCard(
          title: _tr(context, 'Classification'),
          keys: const ['genres'],
          multiline: true,
        ),
      ],
    );
  }

  Widget _summaryCard() {
    final albumId = _track['album_id'];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _ArtworkTile(
            title: _track['title']?.toString() ?? '',
            subtitle: _track['artist_display']?.toString() ?? '',
            size: 68,
            icon: Icons.music_note,
            imageUrl: _trackArtworkUrl(widget.api.baseUrl, widget.trackId),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _track['title']?.toString() ?? _tr(context, 'Untitled'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  _joinParts([
                    _track['artist_display'],
                    _track['album_title'],
                    albumId == null ? null : 'Album #$albumId',
                  ]),
                  style: TextStyle(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _SourcePill(
            label:
                '${_tr(context, 'Revision')} ${widget.snapshot['revision'] ?? 0}',
            manual: false,
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required List<String> keys,
    String? subtitle,
    bool multiline = false,
  }) {
    final available = keys
        .where((key) => _fieldStates.containsKey(key))
        .toList();
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surface,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(color: IntMusicTheme.of(context).textSecondary),
            ),
          ],
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = constraints.maxWidth < 660
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 14) / 2;
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: available
                    .map(
                      (key) => SizedBox(
                        width: itemWidth,
                        child: _metadataField(key, multiline: multiline),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _metadataField(String key, {bool multiline = false}) {
    final state = _fieldStates[key]!;
    final manual = state['source'] == 'manual';
    final fileValue = _editorText(state['file_value'], state['value_kind']);
    final isComment = key == 'comment';
    return TextField(
      controller: _controllers[key],
      onChanged: (value) => setState(() {
        state['source'] = value.trim() == fileValue.trim() ? 'file' : 'manual';
      }),
      minLines: multiline || isComment ? 2 : 1,
      maxLines: multiline || isComment ? 4 : 1,
      keyboardType: state['value_kind'] == 'integer'
          ? TextInputType.number
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: _tr(context, state['label']?.toString() ?? key),
        helperText: manual
            ? '${_tr(context, 'File value')}: ${fileValue.isEmpty ? '—' : fileValue}'
            : _tr(context, 'Using file metadata'),
        helperMaxLines: 2,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SourcePill(
              label: _tr(context, manual ? 'Manual' : 'File'),
              manual: manual,
            ),
            IconButton(
              tooltip: _tr(context, 'Restore file value'),
              onPressed: () => setState(() {
                _controllers[key]!.text = fileValue;
                state['source'] = 'file';
              }),
              icon: const Icon(Icons.restore_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lyricsSection() {
    final preview = _parseLrcPreview(_lyricsController.text);
    return LayoutBuilder(
      builder: (context, constraints) {
        final editor = ListView(
          padding: const EdgeInsets.all(22),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: IntMusicTheme.of(context).surface,
                border: Border.all(color: IntMusicTheme.of(context).stroke),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _tr(context, 'Line-synced lyrics'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      _SourcePill(
                        label: _tr(
                          context,
                          _restoreFileLyrics ? 'File' : _lyricsSourceLabel(),
                        ),
                        manual:
                            !_restoreFileLyrics &&
                            _detail['lyrics'] != null &&
                            _asMap(_detail['lyrics'])['source'] == 'manual',
                      ),
                      if (_detail['lyrics'] != null &&
                          _asMap(_detail['lyrics'])['source'] == 'manual') ...[
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _restoreLyricsFromFile,
                          icon: const Icon(Icons.restore_rounded, size: 18),
                          label: Text(
                            _tr(
                              context,
                              widget.snapshot['file_lyrics'] == null
                                  ? 'Remove manual lyrics'
                                  : 'Restore file lyrics',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _tr(
                      context,
                      'Use [mm:ss.xx] at the start of each line. Multiple timestamps are supported.',
                    ),
                    style: TextStyle(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _tr(
                      context,
                      'Add <v Singer> after a timestamp to identify the performer.',
                    ),
                    style: TextStyle(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _tr(
                      context,
                      'Enhanced LRC word timing such as <00:12.40>word is preserved and previewed during playback.',
                    ),
                    style: TextStyle(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: 0,
                          icon: const Icon(Icons.code_rounded),
                          label: Text(_tr(context, 'Source text')),
                        ),
                        ButtonSegment(
                          value: 1,
                          icon: const Icon(Icons.multiline_chart_rounded),
                          label: Text(_tr(context, 'Line timeline')),
                        ),
                        ButtonSegment(
                          value: 2,
                          icon: const Icon(Icons.text_fields_rounded),
                          label: Text(_tr(context, 'Word timing')),
                        ),
                      ],
                      selected: {_lyricsEditorMode},
                      onSelectionChanged: (value) => setState(() {
                        _lyricsEditorMode = value.first;
                        if (_lyricsEditorMode > 0) {
                          _lyricsKind = 'lrc';
                          _restoreFileLyrics = false;
                        }
                      }),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_lyricsEditorMode == 0) ...[
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final controls = [
                          SizedBox(
                            width: 170,
                            child: DropdownButtonFormField<String>(
                              initialValue: _lyricsKind,
                              decoration: InputDecoration(
                                labelText: _tr(context, 'Format'),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'lrc',
                                  child: Text('LRC'),
                                ),
                                DropdownMenuItem(
                                  value: 'text',
                                  child: Text('Plain text'),
                                ),
                              ],
                              onChanged: (value) => setState(() {
                                _lyricsKind = value ?? 'text';
                                _restoreFileLyrics = false;
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 170,
                            child: TextField(
                              controller: _languageController,
                              onChanged: (_) => _markLyricsEdited(),
                              decoration: InputDecoration(
                                labelText: _tr(context, 'Language'),
                                hintText: 'zh-Hans / en / ja',
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 170,
                            child: TextField(
                              controller: _offsetController,
                              onChanged: (_) => _markLyricsEdited(),
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: _tr(context, 'Offset (ms)'),
                              ),
                            ),
                          ),
                        ];
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: controls,
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _lyricsController,
                      minLines: 12,
                      maxLines: 24,
                      onChanged: (_) => _markLyricsEdited(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        height: 1.45,
                      ),
                      decoration: InputDecoration(
                        alignLabelWithHint: true,
                        labelText: _tr(context, 'Original lyrics'),
                        hintText: '[00:12.40]<v Singer>First line',
                      ),
                    ),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth < 700
                            ? constraints.maxWidth
                            : (constraints.maxWidth - 12) / 2;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            SizedBox(
                              width: width,
                              child: TextField(
                                controller: _translationController,
                                onChanged: (_) => _markLyricsEdited(),
                                minLines: 6,
                                maxLines: 14,
                                style: const TextStyle(fontFamily: 'monospace'),
                                decoration: InputDecoration(
                                  alignLabelWithHint: true,
                                  labelText: _tr(context, 'Translation'),
                                  hintText: '[00:12.40]翻译',
                                ),
                              ),
                            ),
                            SizedBox(
                              width: width,
                              child: TextField(
                                controller: _pronunciationController,
                                onChanged: (_) => _markLyricsEdited(),
                                minLines: 6,
                                maxLines: 14,
                                style: const TextStyle(fontFamily: 'monospace'),
                                decoration: InputDecoration(
                                  alignLabelWithHint: true,
                                  labelText: _tr(context, 'Pronunciation'),
                                  hintText: '[00:12.40]pin yin / romaji',
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ] else ...[
                    SizedBox(
                      height: 610,
                      child: _LyricTimelineEditor(
                        api: widget.api,
                        trackId: widget.trackId,
                        controller: _lyricsController,
                        durationMs: _intValue(_track['duration_ms']) ?? 0,
                        offsetMs:
                            int.tryParse(_offsetController.text.trim()) ?? 0,
                        wordMode: _lyricsEditorMode == 2,
                        onChanged: _markLyricsEdited,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
        if (constraints.maxWidth < 940) {
          return editor;
        }
        return Row(
          children: [
            Expanded(flex: 3, child: editor),
            VerticalDivider(width: 1, color: IntMusicTheme.of(context).stroke),
            Expanded(flex: 2, child: _lyricsPreview(preview)),
          ],
        );
      },
    );
  }

  String _lyricsSourceLabel() {
    if (_detail['lyrics'] == null) return 'None';
    return _asMap(_detail['lyrics'])['source'] == 'manual' ? 'Manual' : 'File';
  }

  Widget _lyricsPreview(List<(String, String)> lines) {
    return Container(
      color: IntMusicTheme.of(context).surfaceRaised.withValues(alpha: 0.42),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _tr(context, 'Timing preview'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '${lines.length} ${_tr(context, 'lines')}',
                  style: TextStyle(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      _tr(context, 'No timed lines yet'),
                      style: TextStyle(
                        color: IntMusicTheme.of(context).textSecondary,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
                    itemCount: lines.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final line = lines[index];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 76,
                            child: Text(
                              line.$1,
                              style: TextStyle(
                                color: IntMusicTheme.of(context).accent,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              line.$2.isEmpty ? '…' : line.$2,
                              style: const TextStyle(height: 1.35),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  List<(String, String)> _parseLrcPreview(String text) {
    final expression = RegExp(r'^\[(\d{1,3}):(\d{2})(?:[.,](\d{1,3}))?\](.*)$');
    final lines = <(String, String)>[];
    for (final rawLine in text.split('\n')) {
      final match = expression.firstMatch(rawLine.trim());
      if (match == null) continue;
      lines.add((
        '${match.group(1)!.padLeft(2, '0')}:${match.group(2)}'
            '${match.group(3) == null ? '' : '.${match.group(3)}'}',
        match.group(4)?.trim() ?? '',
      ));
    }
    return lines.take(200).toList();
  }

  bool _looksLikeLrc(String text) => RegExp(
    r'^\[\d{1,3}:\d{2}(?:[.,]\d{1,3})?\]',
    multiLine: true,
  ).hasMatch(text);

  Widget _fileSection() {
    final rows = <(String, Object?)>[
      (_tr(context, 'Path'), _detail['file_path']),
      (_tr(context, 'Relative path'), _detail['relative_path']),
      (_tr(context, 'Format'), _detail['extension']?.toString().toUpperCase()),
      (_tr(context, 'Size'), _formatBytes(_detail['size_bytes'])),
      (_tr(context, 'Modified'), _detail['modified_at']),
      (_tr(context, 'Scan status'), _detail['scan_status']),
    ];
    return ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: IntMusicTheme.of(context).surface,
            border: Border.all(color: IntMusicTheme.of(context).stroke),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _tr(context, 'File and audio'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                _tr(
                  context,
                  'These values are read-only. Saving currently stores non-destructive IntMusic overrides.',
                ),
                style: TextStyle(
                  color: IntMusicTheme.of(context).textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              for (final row in rows)
                _InfoRow(label: row.$1, value: row.$2?.toString() ?? '—'),
            ],
          ),
        ),
      ],
    );
  }
}

class _SourcePill extends StatelessWidget {
  const _SourcePill({required this.label, required this.manual});

  final String label;
  final bool manual;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: manual
            ? tokens.accent.withValues(alpha: 0.14)
            : tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: manual ? tokens.accent.withValues(alpha: 0.34) : tokens.stroke,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: manual ? tokens.accent : tokens.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
