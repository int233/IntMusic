part of '../intmusic_client.dart';

extension _TrackEditorSections on _TrackEditorDialogState {
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
      onChanged: (value) => _mutate(() {
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
              onPressed: () => _mutate(() {
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
                      onSelectionChanged: (value) => _mutate(() {
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
                              onChanged: (value) => _mutate(() {
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
