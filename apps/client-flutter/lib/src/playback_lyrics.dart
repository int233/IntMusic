part of '../intmusic_client.dart';

class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel({
    required this.lyricsText,
    this.translationText = '',
    this.pronunciationText = '',
    this.offsetMs = 0,
    required this.playback,
    required this.durationMs,
    this.onSeek,
    this.showHeader = true,
    this.glassFade = false,
  });

  final String lyricsText;
  final String translationText;
  final String pronunciationText;
  final int offsetMs;
  final Map<String, dynamic>? playback;
  final int durationMs;
  final Future<void> Function(int)? onSeek;
  final bool showHeader;
  final bool glassFade;

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _LyricsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    final hasTimedLyrics = _parseLyricLines(
      widget.lyricsText,
      translationText: widget.translationText,
      pronunciationText: widget.pronunciationText,
      offsetMs: widget.offsetMs,
    ).any((line) => line.timeMs != null);
    final shouldTick =
        hasTimedLyrics &&
        widget.playback?['state']?.toString() == 'playing' &&
        _intValue(widget.playback?['track_id']) != null;
    if (!shouldTick) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final positionMs = _estimatedPlaybackPositionMs(
      widget.playback,
      widget.durationMs,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(8),
        color: IntMusicTheme.of(context).surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showHeader) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                'Lyrics',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: ExcludeSemantics(
              child: ShaderMask(
                shaderCallback: (rect) {
                  if (!widget.glassFade) {
                    return const LinearGradient(
                      colors: [Colors.white, Colors.white],
                    ).createShader(rect);
                  }
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.08, 0.92, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: _LyricsView(
                  lyricsText: widget.lyricsText,
                  translationText: widget.translationText,
                  pronunciationText: widget.pronunciationText,
                  offsetMs: widget.offsetMs,
                  positionMs: positionMs,
                  onSeek: widget.onSeek,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsView extends StatefulWidget {
  const _LyricsView({
    required this.lyricsText,
    required this.translationText,
    required this.pronunciationText,
    required this.offsetMs,
    required this.positionMs,
    this.onSeek,
  });

  final String lyricsText;
  final String translationText;
  final String pronunciationText;
  final int offsetMs;
  final int positionMs;
  final Future<void> Function(int)? onSeek;

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  final _controller = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};

  @override
  void initState() {
    super.initState();
    _scheduleScrollToCurrentLine();
  }

  @override
  void didUpdateWidget(covariant _LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final lyricsChanged =
        oldWidget.lyricsText != widget.lyricsText ||
        oldWidget.translationText != widget.translationText ||
        oldWidget.pronunciationText != widget.pronunciationText ||
        oldWidget.offsetMs != widget.offsetMs;
    final oldIndex = _currentLyricIndex(
      _parseLyricLines(
        oldWidget.lyricsText,
        translationText: oldWidget.translationText,
        pronunciationText: oldWidget.pronunciationText,
        offsetMs: oldWidget.offsetMs,
      ),
      oldWidget.positionMs,
    );
    final newIndex = _currentLyricIndex(
      _parseLyricLines(
        widget.lyricsText,
        translationText: widget.translationText,
        pronunciationText: widget.pronunciationText,
        offsetMs: widget.offsetMs,
      ),
      widget.positionMs,
    );
    if (lyricsChanged || oldIndex != newIndex) {
      _scheduleScrollToCurrentLine();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleScrollToCurrentLine() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) {
        return;
      }
      final lines = _parseLyricLines(
        widget.lyricsText,
        translationText: widget.translationText,
        pronunciationText: widget.pronunciationText,
        offsetMs: widget.offsetMs,
      );
      final index = _currentLyricIndex(lines, widget.positionMs);
      if (index < 0) {
        return;
      }
      final lineContext = _lineKeys[index]?.currentContext;
      if (lineContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            lineContext,
            alignment: 0.36,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lines = _parseLyricLines(
      widget.lyricsText,
      translationText: widget.translationText,
      pronunciationText: widget.pronunciationText,
      offsetMs: widget.offsetMs,
    );
    if (lines.isEmpty) {
      return const Center(child: Text('No embedded lyrics'));
    }

    final currentIndex = _currentLyricIndex(lines, widget.positionMs);
    return LayoutBuilder(
      builder: (context, constraints) {
        final topSafeSpace = max(84.0, constraints.maxHeight * 0.34);
        final bottomSafeSpace = max(112.0, constraints.maxHeight * 0.44);
        return ListView.builder(
          controller: _controller,
          padding: EdgeInsets.fromLTRB(16, topSafeSpace, 16, bottomSafeSpace),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            final isCurrent = index == currentIndex;
            final distance = currentIndex < 0
                ? 4
                : (index - currentIndex).abs();
            final opacity = isCurrent
                ? 1.0
                : (1 - distance * 0.11).clamp(0.42, 0.8);
            return InkWell(
              key: _lineKeys.putIfAbsent(index, () => GlobalKey()),
              onTap: line.timeMs == null || widget.onSeek == null
                  ? null
                  : () => unawaited(widget.onSeek!(line.timeMs!)),
              borderRadius: BorderRadius.circular(10),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: opacity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 6,
                  ),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                      height: 1.18,
                      fontSize: isCurrent ? 27 : 21,
                      color: isCurrent
                          ? Theme.of(context).colorScheme.secondary
                          : IntMusicTheme.of(context).textPrimary,
                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                      letterSpacing: -0.35,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (line.speaker != null) ...[
                          Text(
                            line.speaker!,
                            style: TextStyle(
                              color: IntMusicTheme.of(context).accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0,
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        _timedLineText(line, isCurrent),
                        if (line.pronunciation != null) ...[
                          const SizedBox(height: 5),
                          Text(
                            line.pronunciation!,
                            style: TextStyle(
                              color: IntMusicTheme.of(context).textSecondary,
                              fontSize: isCurrent ? 15 : 13,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                        if (line.translation != null) ...[
                          const SizedBox(height: 5),
                          Text(
                            line.translation!,
                            style: TextStyle(
                              color: IntMusicTheme.of(context).textSecondary,
                              fontSize: isCurrent ? 16 : 14,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _timedLineText(_LyricLine line, bool isCurrent) {
    if (!isCurrent || line.segments.isEmpty) {
      return Text(line.text);
    }
    final tokens = IntMusicTheme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          for (final segment in line.segments)
            TextSpan(
              text: segment.text,
              style: TextStyle(
                color: widget.positionMs >= segment.startMs
                    ? Theme.of(context).colorScheme.secondary
                    : tokens.textPrimary.withValues(alpha: 0.48),
              ),
            ),
        ],
      ),
    );
  }
}

class _LyricLine {
  const _LyricLine(
    this.timeMs,
    this.text, {
    this.translation,
    this.pronunciation,
    this.speaker,
    this.segments = const [],
  });

  final int? timeMs;
  final String text;
  final String? translation;
  final String? pronunciation;
  final String? speaker;
  final List<_LyricSegment> segments;

  _LyricLine copyWith({String? translation, String? pronunciation}) =>
      _LyricLine(
        timeMs,
        text,
        translation: translation ?? this.translation,
        pronunciation: pronunciation ?? this.pronunciation,
        speaker: speaker,
        segments: segments,
      );
}

class _LyricSegment {
  const _LyricSegment({required this.startMs, required this.text});

  final int startMs;
  final String text;
}

List<_LyricLine> _parseLyricLines(
  String text, {
  String translationText = '',
  String pronunciationText = '',
  int offsetMs = 0,
}) {
  final primary = _parseSingleLyricTrack(text, offsetMs: offsetMs);
  if (primary.isEmpty) return primary;
  final translations = _parseSingleLyricTrack(
    translationText,
    offsetMs: offsetMs,
  );
  final pronunciations = _parseSingleLyricTrack(
    pronunciationText,
    offsetMs: offsetMs,
  );
  final translationByTime = {
    for (final line in translations)
      if (line.timeMs != null) line.timeMs!: line.text,
  };
  final pronunciationByTime = {
    for (final line in pronunciations)
      if (line.timeMs != null) line.timeMs!: line.text,
  };
  final translationsArePlain = translations.every(
    (line) => line.timeMs == null,
  );
  final pronunciationsArePlain = pronunciations.every(
    (line) => line.timeMs == null,
  );
  return [
    for (var index = 0; index < primary.length; index++)
      primary[index].copyWith(
        translation: primary[index].timeMs == null || translationsArePlain
            ? index < translations.length
                  ? translations[index].text
                  : null
            : translationByTime[primary[index].timeMs],
        pronunciation: primary[index].timeMs == null || pronunciationsArePlain
            ? index < pronunciations.length
                  ? pronunciations[index].text
                  : null
            : pronunciationByTime[primary[index].timeMs],
      ),
  ];
}

List<_LyricLine> _parseSingleLyricTrack(String text, {required int offsetMs}) {
  final normalized = text.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) {
    return const [];
  }

  final timestampPattern = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
  final timed = <_LyricLine>[];
  final plain = <_LyricLine>[];

  for (final rawLine in normalized.split('\n')) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) {
      continue;
    }
    final matches = timestampPattern.allMatches(line).toList();
    if (matches.isEmpty) {
      plain.add(_LyricLine(null, line.trim()));
      continue;
    }

    var lyricText = line.replaceAll(timestampPattern, '').trim();
    String? speaker;
    final speakerMatch = RegExp(r'^<v\s+([^>]+)>').firstMatch(lyricText);
    if (speakerMatch != null) {
      speaker = speakerMatch.group(1)?.trim();
      lyricText = lyricText.substring(speakerMatch.end).trimLeft();
    }
    final enhanced = _parseEnhancedLyricText(lyricText, offsetMs);
    lyricText = enhanced.$1;
    for (final match in matches) {
      final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
      final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
      final fraction = match.group(3) ?? '0';
      final millis = switch (fraction.length) {
        1 => (int.tryParse(fraction) ?? 0) * 100,
        2 => (int.tryParse(fraction) ?? 0) * 10,
        _ => int.tryParse(fraction.substring(0, 3)) ?? 0,
      };
      timed.add(
        _LyricLine(
          max(0, minutes * 60000 + seconds * 1000 + millis + offsetMs),
          lyricText.isEmpty ? '...' : lyricText,
          speaker: speaker,
          segments: enhanced.$2,
        ),
      );
    }
  }

  if (timed.isEmpty) {
    return plain;
  }
  timed.sort((left, right) => left.timeMs!.compareTo(right.timeMs!));
  return timed;
}

(String, List<_LyricSegment>) _parseEnhancedLyricText(
  String text,
  int offsetMs,
) {
  final pattern = RegExp(r'<(\d{1,3}):(\d{2})(?:[.:,](\d{1,3}))?>');
  final matches = pattern.allMatches(text).toList();
  if (matches.isEmpty) return (text, const []);
  final plain = text.replaceAll(pattern, '');
  final segments = <_LyricSegment>[];
  for (var index = 0; index < matches.length; index++) {
    final match = matches[index];
    final nextStart = index + 1 < matches.length
        ? matches[index + 1].start
        : text.length;
    final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
    final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
    final fraction = match.group(3) ?? '0';
    final millis = switch (fraction.length) {
      1 => (int.tryParse(fraction) ?? 0) * 100,
      2 => (int.tryParse(fraction) ?? 0) * 10,
      _ => int.tryParse(fraction.substring(0, 3)) ?? 0,
    };
    segments.add(
      _LyricSegment(
        startMs: max(0, minutes * 60000 + seconds * 1000 + millis + offsetMs),
        text: text.substring(match.end, nextStart),
      ),
    );
  }
  return (plain, segments);
}

int _currentLyricIndex(List<_LyricLine> lines, int positionMs) {
  var current = -1;
  for (var index = 0; index < lines.length; index++) {
    final timeMs = lines[index].timeMs;
    if (timeMs == null) {
      continue;
    }
    if (positionMs + 250 >= timeMs) {
      current = index;
    } else {
      break;
    }
  }
  return current;
}
