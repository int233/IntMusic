part of '../intmusic_client.dart';

class _LyricTimelineEditor extends StatefulWidget {
  const _LyricTimelineEditor({
    required this.api,
    required this.trackId,
    required this.controller,
    required this.durationMs,
    required this.offsetMs,
    required this.wordMode,
    required this.onChanged,
  });

  final CoreApiClient api;
  final int trackId;
  final TextEditingController controller;
  final int durationMs;
  final int offsetMs;
  final bool wordMode;
  final VoidCallback onChanged;

  @override
  State<_LyricTimelineEditor> createState() => _LyricTimelineEditorState();
}

class _LyricTimelineEditorState extends State<_LyricTimelineEditor> {
  late final ap.AudioPlayer _player;
  final ScrollController _lineScrollController = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<ap.PlayerState>? _stateSubscription;
  List<double> _waveform = const [];
  String? _waveformError;
  bool _loadingWaveform = true;
  bool _sourceLoaded = false;
  bool _updatingController = false;
  bool _playing = false;
  int _positionMs = 0;
  int _audioDurationMs = 0;
  int _selectedLine = 0;
  int _selectedWord = 0;
  double _playbackRate = 1;

  int get _durationMs =>
      _audioDurationMs > 0 ? _audioDurationMs : widget.durationMs;

  @override
  void initState() {
    super.initState();
    _player = ap.AudioPlayer();
    _positionSubscription = _player.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() => _positionMs = position.inMilliseconds);
      }
    });
    _durationSubscription = _player.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() => _audioDurationMs = duration.inMilliseconds);
      }
    });
    _stateSubscription = _player.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _playing = state == ap.PlayerState.playing);
      }
    });
    widget.controller.addListener(_handleControllerChange);
    unawaited(_loadWaveform());
  }

  @override
  void didUpdateWidget(covariant _LyricTimelineEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
    }
    if (oldWidget.trackId != widget.trackId) {
      _sourceLoaded = false;
      unawaited(_loadWaveform());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChange);
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _stateSubscription?.cancel();
    _lineScrollController.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  void _handleControllerChange() {
    if (!_updatingController && mounted) {
      setState(() {});
    }
  }

  Future<void> _loadWaveform() async {
    setState(() {
      _loadingWaveform = true;
      _waveformError = null;
      _waveform = const [];
    });
    try {
      final response = _asMap(
        await widget.api.getJson('/tracks/${widget.trackId}/waveform?bins=960'),
      );
      final peaks = ((response['peaks'] as List?) ?? const [])
          .map((value) => (value as num).toDouble().clamp(0.0, 1.0))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _waveform = peaks;
        _audioDurationMs =
            _intValue(response['duration_ms']) ?? _audioDurationMs;
        _loadingWaveform = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingWaveform = false;
        _waveformError = error.toString();
      });
    }
  }

  Future<void> _ensureSource() async {
    if (_sourceLoaded) return;
    await _player.setSource(
      ap.UrlSource(widget.api.apiUrl('/tracks/${widget.trackId}/stream')),
    );
    await _player.setPlaybackRate(_playbackRate);
    _sourceLoaded = true;
  }

  Future<void> _togglePlayback() async {
    try {
      await _ensureSource();
      if (_playing) {
        await _player.pause();
      } else {
        await _player.resume();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _waveformError = error.toString());
      }
    }
  }

  Future<void> _seek(int positionMs) async {
    final bounded = positionMs.clamp(0, max(1, _durationMs)).toInt();
    try {
      await _ensureSource();
      await _player.seek(Duration(milliseconds: bounded));
      if (mounted) {
        setState(() => _positionMs = bounded);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _waveformError = error.toString());
      }
    }
  }

  Future<void> _setPlaybackRate(double rate) async {
    setState(() => _playbackRate = rate);
    if (_sourceLoaded) {
      await _player.setPlaybackRate(rate);
    }
  }

  _EditableLyricsDocument _document() =>
      _EditableLyricsDocument.parse(widget.controller.text);

  void _writeDocument(_EditableLyricsDocument document) {
    _updatingController = true;
    widget.controller.value = TextEditingValue(
      text: document.encode(),
      selection: TextSelection.collapsed(offset: document.encode().length),
    );
    _updatingController = false;
    widget.onChanged();
  }

  void _stampSelected({bool advance = true}) {
    final document = _document();
    if (document.lines.isEmpty) return;
    final index = _selectedLine.clamp(0, document.lines.length - 1);
    document.lines[index].timeMs = max(0, _positionMs - widget.offsetMs);
    _writeDocument(document);
    if (advance && index + 1 < document.lines.length) {
      setState(() {
        _selectedLine = index + 1;
        _selectedWord = 0;
      });
      _scrollToSelected();
    }
  }

  void _adjustSelected(int deltaMs) {
    final document = _document();
    if (document.lines.isEmpty) return;
    final index = _selectedLine.clamp(0, document.lines.length - 1);
    final line = document.lines[index];
    line.timeMs = max(0, (line.timeMs ?? 0) + deltaMs);
    _writeDocument(document);
  }

  void _clearSelectedTimestamp() {
    final document = _document();
    if (document.lines.isEmpty) return;
    document.lines[_selectedLine.clamp(0, document.lines.length - 1)].timeMs =
        null;
    _writeDocument(document);
  }

  void _selectLine(int index, _EditableLyricLine line) {
    setState(() {
      _selectedLine = index;
      _selectedWord = 0;
    });
    if (line.timeMs != null) {
      unawaited(_seek(line.timeMs! + widget.offsetMs));
    }
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lineContext = _lineKeys[_selectedLine]?.currentContext;
      if (lineContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            lineContext,
            alignment: 0.42,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  void _distributeWords() {
    final document = _document();
    if (document.lines.isEmpty) return;
    final lineIndex = _selectedLine.clamp(0, document.lines.length - 1);
    final line = document.lines[lineIndex];
    line.timeMs ??= max(0, _positionMs - widget.offsetMs);
    final tokens = _lyricWordTokens(line.plainContent);
    if (tokens.isEmpty) return;
    final nextTime = lineIndex + 1 < document.lines.length
        ? document.lines[lineIndex + 1].timeMs
        : null;
    final endMs = nextTime ?? min(_durationMs, line.timeMs! + 5000);
    final span = max(tokens.length, endMs - line.timeMs!);
    line.words = [
      for (var index = 0; index < tokens.length; index++)
        _EditableLyricWord(
          timeMs: line.timeMs! + span * index ~/ tokens.length,
          text: tokens[index],
        ),
    ];
    _writeDocument(document);
    setState(() => _selectedWord = 0);
  }

  void _stampWord(int wordIndex) {
    final document = _document();
    if (document.lines.isEmpty) return;
    final lineIndex = _selectedLine.clamp(0, document.lines.length - 1);
    final line = document.lines[lineIndex];
    if (line.words.isEmpty) {
      _distributeWords();
      return;
    }
    final index = wordIndex.clamp(0, line.words.length - 1);
    line.words[index].timeMs = max(0, _positionMs - widget.offsetMs);
    for (var cursor = index + 1; cursor < line.words.length; cursor++) {
      if (line.words[cursor].timeMs < line.words[cursor - 1].timeMs) {
        line.words[cursor].timeMs = line.words[cursor - 1].timeMs;
      }
    }
    _writeDocument(document);
    setState(() {
      _selectedWord = min(index + 1, line.words.length - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final document = _document();
    if (document.lines.isNotEmpty) {
      _selectedLine = _selectedLine.clamp(0, document.lines.length - 1);
    } else {
      _selectedLine = 0;
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
        const SingleActivator(LogicalKeyboardKey.enter): _stampSelected,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
            _adjustSelected(-100),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
            _adjustSelected(100),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          children: [
            _transport(document),
            const SizedBox(height: 12),
            _waveformView(document),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final lineList = _lineList(document);
                  if (!widget.wordMode || constraints.maxWidth < 760) {
                    return widget.wordMode
                        ? Column(
                            children: [
                              Expanded(child: lineList),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 190,
                                child: _wordEditor(document),
                              ),
                            ],
                          )
                        : lineList;
                  }
                  return Row(
                    children: [
                      Expanded(flex: 3, child: lineList),
                      const SizedBox(width: 12),
                      Expanded(flex: 2, child: _wordEditor(document)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transport(_EditableLyricsDocument document) {
    return Row(
      children: [
        IconButton.filled(
          tooltip: _tr(context, _playing ? 'Pause preview' : 'Play preview'),
          onPressed: _togglePlayback,
          icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        const SizedBox(width: 10),
        Text(
          '${_formatEditorTime(_positionMs)} / '
          '${_formatEditorTime(_durationMs)}',
          style: const TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 14),
        DropdownButton<double>(
          value: _playbackRate,
          items: const [
            DropdownMenuItem(value: 0.5, child: Text('0.5×')),
            DropdownMenuItem(value: 0.75, child: Text('0.75×')),
            DropdownMenuItem(value: 1, child: Text('1×')),
          ],
          onChanged: (value) {
            if (value != null) unawaited(_setPlaybackRate(value));
          },
        ),
        const Spacer(),
        Text(
          '${document.timedCount}/${document.lines.length} '
          '${_tr(context, 'timed')}',
          style: TextStyle(color: IntMusicTheme.of(context).textSecondary),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          onPressed: document.lines.isEmpty ? null : _stampSelected,
          icon: const Icon(Icons.add_alarm_rounded),
          label: Text(_tr(context, 'Stamp and next')),
        ),
      ],
    );
  }

  Widget _waveformView(_EditableLyricsDocument document) {
    return Container(
      height: 126,
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => unawaited(
              _seek(
                (_durationMs *
                        details.localPosition.dx /
                        max(1.0, constraints.maxWidth))
                    .round(),
              ),
            ),
            onHorizontalDragUpdate: (details) => unawaited(
              _seek(
                (_durationMs *
                        details.localPosition.dx /
                        max(1.0, constraints.maxWidth))
                    .round(),
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _LyricWaveformPainter(
                    peaks: _waveform,
                    durationMs: _durationMs,
                    positionMs: _positionMs,
                    markers: document.lines
                        .map((line) => line.timeMs)
                        .whereType<int>()
                        .map((time) => time + widget.offsetMs)
                        .toList(growable: false),
                    selectedMarker: document.lines.isEmpty
                        ? null
                        : document.lines[_selectedLine].timeMs == null
                        ? null
                        : document.lines[_selectedLine].timeMs! +
                              widget.offsetMs,
                    accent: IntMusicTheme.of(context).accent,
                    foreground: IntMusicTheme.of(context).textSecondary,
                    stroke: IntMusicTheme.of(context).stroke,
                  ),
                ),
                if (_loadingWaveform)
                  const Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (_waveformError != null && !_loadingWaveform)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _tr(
                          context,
                          'Waveform unavailable; timing tools still work.',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: IntMusicTheme.of(context).textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _lineList(_EditableLyricsDocument document) {
    if (document.lines.isEmpty) {
      return Center(
        child: Text(_tr(context, 'Add lyric lines in source mode first.')),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        controller: _lineScrollController,
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: document.lines.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: IntMusicTheme.of(context).stroke),
        itemBuilder: (context, index) {
          final line = document.lines[index];
          final selected = index == _selectedLine;
          return Material(
            key: _lineKeys.putIfAbsent(index, () => GlobalKey()),
            color: selected
                ? IntMusicTheme.of(context).accent.withValues(alpha: 0.12)
                : Colors.transparent,
            child: InkWell(
              onTap: () => _selectLine(index, line),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(
                        line.timeMs == null
                            ? '--:--.--'
                            : _formatLrcTimestamp(line.timeMs!),
                        style: TextStyle(
                          color: line.timeMs == null
                              ? IntMusicTheme.of(context).textSecondary
                              : IntMusicTheme.of(context).accent,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        line.displayText.isEmpty ? '…' : line.displayText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (selected) ...[
                      IconButton(
                        tooltip: '-100 ms',
                        onPressed: () => _adjustSelected(-100),
                        icon: const Icon(Icons.remove_rounded, size: 18),
                      ),
                      IconButton(
                        tooltip: '+100 ms',
                        onPressed: () => _adjustSelected(100),
                        icon: const Icon(Icons.add_rounded, size: 18),
                      ),
                      IconButton(
                        tooltip: _tr(context, 'Clear timestamp'),
                        onPressed: _clearSelectedTimestamp,
                        icon: const Icon(Icons.timer_off_outlined, size: 18),
                      ),
                      IconButton.filledTonal(
                        tooltip: _tr(context, 'Stamp here'),
                        onPressed: () => _stampSelected(advance: false),
                        icon: const Icon(Icons.add_alarm_rounded, size: 18),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _wordEditor(_EditableLyricsDocument document) {
    if (document.lines.isEmpty) return const SizedBox.shrink();
    final line = document.lines[_selectedLine];
    final words = line.words;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _tr(context, 'Word timing'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                onPressed: _distributeWords,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: Text(_tr(context, 'Distribute')),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _tr(context, 'Select a word and stamp it at the preview position.'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: words.isEmpty
                ? Center(
                    child: FilledButton.tonalIcon(
                      onPressed: _distributeWords,
                      icon: const Icon(Icons.segment_rounded),
                      label: Text(_tr(context, 'Create word segments')),
                    ),
                  )
                : SingleChildScrollView(
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 8,
                      children: [
                        for (var index = 0; index < words.length; index++)
                          ChoiceChip(
                            selected: index == _selectedWord,
                            onSelected: (_) {
                              setState(() => _selectedWord = index);
                              unawaited(
                                _seek(words[index].timeMs + widget.offsetMs),
                              );
                            },
                            label: Text(
                              '${words[index].text}'
                              '\n${_formatLrcTimestamp(words[index].timeMs)}',
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: words.isEmpty ? null : () => _stampWord(_selectedWord),
              icon: const Icon(Icons.touch_app_outlined),
              label: Text(_tr(context, 'Stamp selected word')),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditableLyricsDocument {
  _EditableLyricsDocument({required this.headers, required this.lines});

  final List<String> headers;
  final List<_EditableLyricLine> lines;

  int get timedCount => lines.where((line) => line.timeMs != null).length;

  factory _EditableLyricsDocument.parse(String source) {
    final timestamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:,](\d{1,3}))?\]');
    final metadata = RegExp(r'^\[[a-zA-Z][^:]*:.*\]$');
    final headers = <String>[];
    final lines = <_EditableLyricLine>[];
    for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
      final value = raw.trimRight();
      if (value.trim().isEmpty) continue;
      if (metadata.hasMatch(value.trim())) {
        headers.add(value.trim());
        continue;
      }
      final matches = timestamp.allMatches(value).toList();
      final content = value.replaceAll(timestamp, '').trim();
      if (matches.isEmpty) {
        lines.add(_EditableLyricLine(timeMs: null, content: content));
        continue;
      }
      for (final match in matches) {
        lines.add(
          _EditableLyricLine(
            timeMs: _timestampMatchMs(match),
            content: content,
          ),
        );
      }
    }
    return _EditableLyricsDocument(headers: headers, lines: lines);
  }

  String encode() {
    final output = <String>[...headers];
    for (final line in lines) {
      final prefix = line.timeMs == null
          ? ''
          : '[${_formatLrcTimestamp(line.timeMs!)}]';
      output.add('$prefix${line.encodedContent}');
    }
    return output.join('\n');
  }
}

class _EditableLyricLine {
  _EditableLyricLine({required this.timeMs, required this.content})
    : words = _parseEditableWords(content);

  int? timeMs;
  String content;
  List<_EditableLyricWord> words;

  String get speakerPrefix {
    final match = RegExp(r'^<v\s+[^>]+>').firstMatch(content);
    return match?.group(0) ?? '';
  }

  String get plainContent => content
      .replaceFirst(RegExp(r'^<v\s+[^>]+>'), '')
      .replaceAll(RegExp(r'<\d{1,3}:\d{2}(?:[.:,]\d{1,3})?>'), '');

  String get displayText => plainContent.trim();

  String get encodedContent {
    if (words.isEmpty) return content;
    return '$speakerPrefix${words.map((word) => '<${_formatLrcTimestamp(word.timeMs)}>${word.text}').join()}';
  }
}

class _EditableLyricWord {
  _EditableLyricWord({required this.timeMs, required this.text});

  int timeMs;
  final String text;
}

List<_EditableLyricWord> _parseEditableWords(String content) {
  final text = content.replaceFirst(RegExp(r'^<v\s+[^>]+>'), '');
  final marker = RegExp(r'<(\d{1,3}):(\d{2})(?:[.:,](\d{1,3}))?>');
  final matches = marker.allMatches(text).toList();
  if (matches.isEmpty) return [];
  return [
    for (var index = 0; index < matches.length; index++)
      _EditableLyricWord(
        timeMs: _timestampMatchMs(matches[index]),
        text: text.substring(
          matches[index].end,
          index + 1 < matches.length ? matches[index + 1].start : text.length,
        ),
      ),
  ];
}

List<String> _lyricWordTokens(String text) {
  if (text.trim().isEmpty) return const [];
  if (text.contains(RegExp(r'\s'))) {
    return RegExp(
      r'\S+\s*',
    ).allMatches(text).map((match) => match.group(0)!).toList(growable: false);
  }
  return text.runes.map(String.fromCharCode).toList(growable: false);
}

int _timestampMatchMs(RegExpMatch match) {
  final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
  final fraction = match.group(3) ?? '0';
  final milliseconds = switch (fraction.length) {
    1 => (int.tryParse(fraction) ?? 0) * 100,
    2 => (int.tryParse(fraction) ?? 0) * 10,
    _ => int.tryParse(fraction.substring(0, min(3, fraction.length))) ?? 0,
  };
  return minutes * 60000 + seconds * 1000 + milliseconds;
}

String _formatLrcTimestamp(int milliseconds) {
  final value = max(0, milliseconds);
  final minutes = value ~/ 60000;
  final seconds = (value ~/ 1000) % 60;
  final centiseconds = (value % 1000) ~/ 10;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${centiseconds.toString().padLeft(2, '0')}';
}

String _formatEditorTime(int milliseconds) {
  final value = max(0, milliseconds);
  final minutes = value ~/ 60000;
  final seconds = (value ~/ 1000) % 60;
  final tenths = (value % 1000) ~/ 100;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.$tenths';
}

class _LyricWaveformPainter extends CustomPainter {
  const _LyricWaveformPainter({
    required this.peaks,
    required this.durationMs,
    required this.positionMs,
    required this.markers,
    required this.selectedMarker,
    required this.accent,
    required this.foreground,
    required this.stroke,
  });

  final List<double> peaks;
  final int durationMs;
  final int positionMs;
  final List<int> markers;
  final int? selectedMarker;
  final Color accent;
  final Color foreground;
  final Color stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    final waveformPaint = Paint()
      ..color = foreground.withValues(alpha: 0.54)
      ..strokeWidth = max(1.0, size.width / max(1, peaks.length) * 0.62)
      ..strokeCap = StrokeCap.round;
    if (peaks.isEmpty) {
      final fallback = Paint()
        ..color = stroke
        ..strokeWidth = 1;
      canvas.drawLine(Offset(0, center), Offset(size.width, center), fallback);
    } else {
      for (var index = 0; index < peaks.length; index++) {
        final x = (index + 0.5) * size.width / peaks.length;
        final amplitude = max(2.0, peaks[index] * (size.height * 0.36));
        canvas.drawLine(
          Offset(x, center - amplitude),
          Offset(x, center + amplitude),
          waveformPaint,
        );
      }
    }
    if (durationMs <= 0) return;
    final markerPaint = Paint()
      ..color = accent.withValues(alpha: 0.38)
      ..strokeWidth = 1;
    for (final marker in markers) {
      final x = marker.clamp(0, durationMs) / durationMs * size.width;
      canvas.drawLine(Offset(x, 8), Offset(x, size.height - 8), markerPaint);
    }
    if (selectedMarker != null) {
      final x = selectedMarker!.clamp(0, durationMs) / durationMs * size.width;
      canvas.drawCircle(
        Offset(x, center),
        5,
        Paint()..color = accent.withValues(alpha: 0.9),
      );
    }
    final playhead = positionMs.clamp(0, durationMs) / durationMs * size.width;
    canvas.drawLine(
      Offset(playhead, 0),
      Offset(playhead, size.height),
      Paint()
        ..color = accent
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _LyricWaveformPainter oldDelegate) =>
      oldDelegate.peaks != peaks ||
      oldDelegate.durationMs != durationMs ||
      oldDelegate.positionMs != positionMs ||
      oldDelegate.markers != markers ||
      oldDelegate.selectedMarker != selectedMarker ||
      oldDelegate.accent != accent;
}
