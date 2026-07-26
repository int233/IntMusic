part of '../intmusic_client.dart';

String _playbackModeLabel(BuildContext context, _PlaybackMode mode) {
  return switch (mode) {
    _PlaybackMode.single => _tr(context, 'Single play'),
    _PlaybackMode.repeatOne => _tr(context, 'Repeat one'),
    _PlaybackMode.shuffle => _tr(context, 'Shuffle'),
    _PlaybackMode.repeatAll => _tr(context, 'Repeat all'),
    _PlaybackMode.sequential => _tr(context, 'Sequential'),
  };
}

String _searchScopeLabel(BuildContext context, _SearchScope scope) {
  return switch (scope) {
    _SearchScope.all => _tr(context, 'All'),
    _SearchScope.tracks => _tr(context, 'Tracks'),
    _SearchScope.albums => _tr(context, 'Albums'),
    _SearchScope.artists => _tr(context, 'Artists'),
    _SearchScope.playlists => _tr(context, 'Playlists'),
  };
}

String _searchSortLabel(BuildContext context, _SearchSort sort) {
  return switch (sort) {
    _SearchSort.relevance => _tr(context, 'Relevance'),
    _SearchSort.titleAz => _tr(context, 'Title A-Z'),
    _SearchSort.albumAz => _tr(context, 'Album A-Z'),
    _SearchSort.artistAz => _tr(context, 'Artist A-Z'),
    _SearchSort.fileSize => _tr(context, 'File size'),
    _SearchSort.addedAt => _tr(context, 'Added time'),
    _SearchSort.playCount => _tr(context, 'Play count'),
    _SearchSort.favorite => _tr(context, 'Favorite'),
  };
}

IconData _playbackModeIcon(_PlaybackMode mode) {
  return switch (mode) {
    _PlaybackMode.single => Icons.looks_one_outlined,
    _PlaybackMode.repeatOne => Icons.repeat_one,
    _PlaybackMode.shuffle => Icons.shuffle,
    _PlaybackMode.repeatAll => Icons.repeat,
    _PlaybackMode.sequential => Icons.format_list_numbered,
  };
}

Color _connectionDotColor({
  required bool loading,
  required String? error,
  required Map<String, dynamic>? playback,
}) {
  if (loading) {
    return const Color(0xffd7b44c);
  }
  if (error != null) {
    return const Color(0xffe05c6b);
  }
  if (playback?['state']?.toString() == 'playing') {
    return const Color(0xff5aa9ff);
  }
  return appPlaying;
}

Color _seededColor(String seed, int offset) {
  const palette = [
    Color(0xffc85062),
    Color(0xffd48443),
    Color(0xffb49b42),
    Color(0xff4a9f7a),
    Color(0xff408c96),
    Color(0xff5774b8),
    Color(0xff9a65b8),
    Color(0xffbc5c89),
  ];
  final hash = seed.codeUnits.fold<int>(
    0,
    (value, unit) => (value * 31 + unit) & 0x7fffffff,
  );
  return palette[(hash + offset).abs() % palette.length];
}

Future<T?> _showAnchoredPopup<T>({
  required BuildContext context,
  required BuildContext anchorContext,
  required Widget child,
  double width = 360,
  double maxHeight = 520,
}) {
  final language = _LocaleScope.languageOf(context);

  return showDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (dialogContext) => LayoutBuilder(
      builder: (context, constraints) {
        final overlay = _safeRenderBox(Overlay.of(context).context);
        final anchor = _safeRenderBox(anchorContext);
        if (overlay == null || anchor == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted && Navigator.of(dialogContext).canPop()) {
              Navigator.of(dialogContext).pop();
            }
          });
          return const SizedBox.shrink();
        }
        final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
        final anchorSize = anchor.size;
        final screen = overlay.size;
        final popupWidth = min(width, screen.width - 24);
        final popupHeight = min(maxHeight, screen.height - 24);
        final left = (topLeft.dx + popupWidth > screen.width - 12)
            ? (screen.width - popupWidth - 12).clamp(12.0, screen.width)
            : topLeft.dx.clamp(12.0, screen.width);
        final top =
            (topLeft.dy + anchorSize.height + popupHeight > screen.height - 12)
            ? (topLeft.dy - popupHeight - 8).clamp(12.0, screen.height)
            : (topLeft.dy + anchorSize.height + 8).clamp(12.0, screen.height);

        return _LocaleScope(
          language: language,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(dialogContext).pop(),
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                left: left,
                top: top,
                child: Material(
                  color: IntMusicTheme.of(dialogContext).surface,
                  elevation: 18,
                  shadowColor: Colors.black.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: popupWidth,
                      minWidth: popupWidth,
                      maxHeight: popupHeight,
                    ),
                    child: child,
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

RenderBox? _safeRenderBox(BuildContext context) {
  try {
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.attached) {
      return renderObject;
    }
  } catch (_) {
    return null;
  }
  return null;
}

Map<String, dynamic> _asMap(Object? value) =>
    (value as Map).cast<String, dynamic>();

String? _albumArtworkUrl(String coreBaseUrl, Object? albumId) =>
    _artworkUrl(coreBaseUrl, 'albums', albumId);

String? _trackArtworkUrl(String coreBaseUrl, Object? trackId) =>
    _artworkUrl(coreBaseUrl, 'tracks', trackId);

String? _artistArtworkUrl(
  String coreBaseUrl,
  Object? artistId,
  String slot, {
  Object? revision,
  int? width,
  int? height,
}) {
  final value = artistId?.toString();
  final baseUrl = coreBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (value == null || value.isEmpty || baseUrl.isEmpty) {
    return null;
  }
  final query = <String>[
    if (width != null) 'w=$width',
    if (height != null) 'h=$height',
    if (revision != null) 'revision=$revision',
  ];
  return '$baseUrl/api/v1/artwork/artists/$value/$slot'
      '${query.isEmpty ? '' : '?${query.join('&')}'}';
}

String? _artworkUrl(String coreBaseUrl, String kind, Object? id) {
  final value = id?.toString();
  if (value == null || value.isEmpty) {
    return null;
  }
  final baseUrl = coreBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (baseUrl.isEmpty) {
    return null;
  }
  return '$baseUrl/api/v1/artwork/$kind/$value';
}

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '');
}

int _estimatedPlaybackPositionMs(
  Map<String, dynamic>? playback, [
  int? durationMs,
]) {
  final basePosition = _intValue(playback?['position_ms']) ?? 0;
  final state = playback?['state']?.toString();
  final receivedAtMs = _intValue(playback?['_received_at_ms']);
  final elapsedMs = state == 'playing' && receivedAtMs != null
      ? DateTime.now().millisecondsSinceEpoch - receivedAtMs
      : 0;
  final estimate = basePosition + elapsedMs.clamp(0, 60 * 60 * 1000).toInt();
  final max = durationMs ?? 0;
  if (max > 0) {
    return estimate.clamp(0, max).toInt();
  }
  return estimate.clamp(0, 1 << 31).toInt();
}

String _joinParts(Iterable<Object?> values) {
  return values
      .map((value) => value?.toString().trim() ?? '')
      .where((value) => value.isNotEmpty && value != '-')
      .join(' - ');
}

String _zoneIdForOutput(Map<String, dynamic> output) {
  return output['id']?.toString() ?? 'local';
}

String _zoneGroupName(Map<String, dynamic> zone) {
  final nodeName = zone['node_name']?.toString().trim();
  if (nodeName != null && nodeName.isNotEmpty) {
    return zone['is_remote'] == true ? nodeName : 'Core local';
  }
  return 'Core local';
}

String _zoneDisplayName(Map<String, dynamic> zone) {
  final alias = zone['alias']?.toString().trim();
  if (alias != null && alias.isNotEmpty) {
    return alias;
  }
  final systemName = zone['system_name']?.toString().trim();
  final group = _zoneGroupName(zone);
  if (systemName != null && systemName.startsWith('$group - ')) {
    return systemName.substring(group.length + 3);
  }
  final name = zone['name']?.toString().trim();
  if (name != null && name.startsWith('$group - ')) {
    return name.substring(group.length + 3);
  }
  return name?.isNotEmpty == true ? name! : zone['id']?.toString() ?? 'Output';
}

String _zoneSubtitle(Map<String, dynamic> zone) {
  return _joinParts([
    _zoneTrackLabel(zone),
    _formatDuration(zone['position_ms']),
    zone['is_online'] == false ? 'offline' : 'online',
    zone['is_remote'] == true ? 'remote' : 'core',
  ]);
}

String _zoneTrackLabel(Map<String, dynamic> zone) {
  final title = zone['track_title']?.toString().trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  final trackId = _intValue(zone['track_id']);
  return trackId == null ? 'Idle' : 'Track $trackId';
}

IconData _zoneStateIcon(String state) {
  return switch (state) {
    'playing' => Icons.graphic_eq,
    'paused' => Icons.pause_circle_outline,
    _ => Icons.speaker_outlined,
  };
}

IconData _historyEventIcon(Object? eventType) {
  return switch (eventType?.toString()) {
    'play_start' => Icons.play_arrow,
    'pause' => Icons.pause,
    'resume' => Icons.play_circle_outline,
    'seek' => Icons.linear_scale,
    'cut_out' => Icons.call_split_outlined,
    'completed' => Icons.done,
    'stop' => Icons.stop,
    _ => Icons.timeline_outlined,
  };
}

String _sanitizeRendererId(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
}

String _searchSubtitle(Map<String, dynamic> item, _ResultKind kind) {
  return switch (kind) {
    _ResultKind.track => _joinParts([
      item['artist_display'],
      item['album_title'],
      _formatDuration(item['duration_ms']),
      _ratingLabel(item),
    ]),
    _ResultKind.album => _joinParts([
      item['album_artist_display'],
      item['year'],
      '${item['track_count'] ?? 0} tracks',
    ]),
    _ResultKind.artist =>
      '${item['album_count'] ?? 0} albums - ${item['track_count'] ?? 0} tracks',
    _ResultKind.playlist => _joinParts([
      item['kind'],
      '${item['track_count'] ?? 0} tracks',
      item['description'],
    ]),
  };
}

String _trackNumber(Map<String, dynamic> track) {
  final disc = _intValue(track['disc_number']);
  final number = _intValue(track['track_number']);
  if (disc != null && number != null) {
    return '$disc-$number';
  }
  return number?.toString() ?? '-';
}

String _formatDuration(Object? value) {
  final totalMs = _intValue(value);
  if (totalMs == null || totalMs <= 0) {
    return '';
  }
  final totalSeconds = (totalMs / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _formatBytes(Object? value) {
  final bytes = _intValue(value);
  if (bytes == null || bytes < 0) {
    return '';
  }
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

Object _ruleValue(String field, String rawValue) {
  final value = rawValue.trim();
  if (_numericSmartFields.contains(field)) {
    return int.tryParse(value) ?? value;
  }
  if (field == 'favorite') {
    return ['true', 'yes', '1'].contains(value.toLowerCase());
  }
  return value;
}

String _smartRulesLabel(Object? rules) {
  if (rules is! Map) {
    return 'All tracks';
  }
  final map = rules.cast<String, dynamic>();
  final match = map['match']?.toString() == 'any' ? 'any' : 'all';
  final ruleList = (map['rules'] as List?) ?? const [];
  if (ruleList.isEmpty) {
    return 'All tracks';
  }
  final parts = ruleList
      .take(4)
      .map((item) {
        final rule = (item as Map).cast<String, dynamic>();
        return '${rule['field']} ${rule['op']} ${rule['value']}';
      })
      .join(' / ');
  return '$match: $parts';
}

String _ratingLabel(Map<String, dynamic> track) {
  final rating = _intValue(track['effective_rating']);
  if (rating == null) {
    return '';
  }
  return 'rating $rating';
}

const _smartFields = [
  'title',
  'artist',
  'composer',
  'lyricist',
  'album',
  'album_artist',
  'genre',
  'year',
  'rating',
  'favorite',
  'extension',
  'path',
];

const _numericSmartFields = {'year', 'rating', 'duration_ms', 'tag_rating'};

const _destinations = [
  _Destination('Home', Icons.home_outlined, Icons.home),
  _Destination('Albums', Icons.album_outlined, Icons.album),
  _Destination('Artists', Icons.person_outline, Icons.person),
  _Destination('Tracks', Icons.music_note_outlined, Icons.music_note),
  _Destination('Playlists', Icons.queue_music_outlined, Icons.queue_music),
  _Destination('Playback', Icons.graphic_eq, Icons.graphic_eq),
  _Destination('History', Icons.timeline_outlined, Icons.timeline),
  _Destination('Settings', Icons.tune_outlined, Icons.tune),
];
