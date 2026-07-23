part of '../main.dart';

class _ArtworkTile extends StatelessWidget {
  const _ArtworkTile({
    required this.title,
    required this.subtitle,
    required this.size,
    required this.icon,
    this.imageUrl,
    this.deferImage = false,
  });

  final String title;
  final String subtitle;
  final double size;
  final IconData icon;
  final String? imageUrl;
  final bool deferImage;

  @override
  Widget build(BuildContext context) {
    final first = title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase();
    final base = _seededColor('$title$subtitle', 0);
    final accent = _seededColor('$subtitle$title', 1);
    final showLetter = size >= 80;
    final radius = size >= 100 ? 16.0 : 11.0;
    final imageCacheExtent =
        ((size * MediaQuery.devicePixelRatioOf(context)) / 64).ceil() * 64;
    final fallback = Stack(
      children: [
        Positioned(
          right: -size * 0.18,
          bottom: -size * 0.2,
          child: Icon(
            icon,
            size: size * 0.78,
            color: Colors.white.withValues(alpha: 0.15),
          ),
        ),
        Center(
          child: showLetter
              ? Text(
                  first,
                  style: TextStyle(
                    fontSize: size * 0.32,
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.86),
                  ),
                )
              : Icon(
                  icon,
                  size: size * 0.48,
                  color: Colors.white.withValues(alpha: 0.86),
                ),
        ),
      ],
    );

    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [base, accent],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: size >= 120 ? 22 : 10,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: imageUrl == null || deferImage
              ? fallback
              : CachedNetworkImage(
                  cacheManager: _artworkCacheManager,
                  imageUrl: imageUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: imageCacheExtent,
                  memCacheHeight: imageCacheExtent,
                  filterQuality: FilterQuality.low,
                  fadeInDuration: const Duration(milliseconds: 80),
                  fadeOutDuration: Duration.zero,
                  useOldImageOnUrlChange: true,
                  placeholder: (context, url) => fallback,
                  errorWidget: (context, url, error) => fallback,
                ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final Object value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return SizedBox(
      width: 180,
      height: 120,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceRaised.withValues(alpha: 0.72),
          border: Border.all(color: tokens.stroke),
          borderRadius: BorderRadius.circular(tokens.radiusMedium),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.secondary),
              const Spacer(),
              Text('$value', style: Theme.of(context).textTheme.headlineSmall),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _SimpleListRow extends StatelessWidget {
  const _SimpleListRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.height = 64,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xff9aa1ab),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

class _WindowsA11yQuiet extends StatelessWidget {
  const _WindowsA11yQuiet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) {
      return child;
    }
    return ExcludeSemantics(child: child);
  }
}

class _AppTooltip extends StatelessWidget {
  const _AppTooltip({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return ExcludeSemantics(child: child);
    }
    return Tooltip(message: message, excludeFromSemantics: true, child: child);
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.imageUrl,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ArtworkTile(
          title: title,
          subtitle: subtitle,
          size: 74,
          icon: icon,
          imageUrl: imageUrl,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class _AnimatedPageHost extends StatelessWidget {
  const _AnimatedPageHost({
    required this.pageKey,
    required this.direction,
    required this.child,
  });

  final String pageKey;
  final int direction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final reduceMotion =
        (mediaQuery?.disableAnimations ?? false) ||
        (mediaQuery?.accessibleNavigation ?? false);
    return AnimatedSwitcher(
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 260),
      reverseDuration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) {
        final offset = Tween<Offset>(
          begin: Offset(0.04 * direction, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: KeyedSubtree(key: ValueKey(pageKey), child: child),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xff5b2b2b),
      child: Row(
        children: [
          const Icon(Icons.error_outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

enum _PlaybackMode {
  single,
  repeatOne,
  shuffle,
  repeatAll,
  sequential;

  String get nameForApi => switch (this) {
    _PlaybackMode.single => 'single',
    _PlaybackMode.repeatOne => 'repeat_one',
    _PlaybackMode.shuffle => 'shuffle',
    _PlaybackMode.repeatAll => 'repeat_all',
    _PlaybackMode.sequential => 'sequential',
  };

  static _PlaybackMode fromApi(String? value) => switch (value) {
    'single' => _PlaybackMode.single,
    'repeat_one' => _PlaybackMode.repeatOne,
    'shuffle' => _PlaybackMode.shuffle,
    'repeat_all' => _PlaybackMode.repeatAll,
    _ => _PlaybackMode.sequential,
  };
}

enum _SearchScope { all, tracks, albums, artists }

enum _SearchSort {
  relevance,
  titleAz,
  albumAz,
  artistAz,
  fileSize,
  addedAt,
  playCount,
  favorite,
}

const _searchPageIndex = -1;
const _trackInfoPageIndex = -2;
const _albumInfoPageIndex = -3;
const _artistInfoPageIndex = -4;
const _appMinWidth = 520.0;
const _appMinHeight = 720.0;
const _appMinAspectRatio = 0.62;
const _appMaxAspectRatio = 2.2;
const _compactWidth = 900.0;
const _compactHeight = 760.0;
const _sidebarWidth = 236.0;
const _desktopShellWidth = _compactWidth + _sidebarWidth + 1.0;

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
                  color: appSurface,
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
