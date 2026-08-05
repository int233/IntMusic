part of '../intmusic_client.dart';

class _CompactLyricsPane extends StatelessWidget {
  const _CompactLyricsPane({
    required this.coreBaseUrl,
    required this.playback,
    required this.track,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.state,
    required this.isPaused,
    required this.activeZoneId,
    required this.durationMs,
    required this.lyricsText,
    required this.lyricsTranslation,
    required this.lyricsPronunciation,
    required this.lyricsOffsetMs,
    required this.playbackMode,
    required this.volumeState,
    required this.page,
    required this.onGoToPage,
    required this.onResume,
    required this.onPause,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onCycleMode,
    required this.onShowModeMenu,
    required this.onShowQueue,
    required this.onShowDevices,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onToggleFavorite,
    required this.onOpenTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? playback;
  final Map<String, dynamic>? track;
  final int? trackId;
  final String title;
  final String artist;
  final String album;
  final String state;
  final bool isPaused;
  final String activeZoneId;
  final int durationMs;
  final String lyricsText;
  final String lyricsTranslation;
  final String lyricsPronunciation;
  final int lyricsOffsetMs;
  final _PlaybackMode playbackMode;
  final _DualVolumeState volumeState;
  final int page;
  final ValueChanged<int> onGoToPage;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function(int) onSeek;
  final VoidCallback onCycleMode;
  final void Function(BuildContext) onShowModeMenu;
  final void Function(BuildContext) onShowQueue;
  final void Function(BuildContext) onShowDevices;
  final void Function(String mode, double volume) onVolumeChanged;
  final ValueChanged<String> onToggleMute;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onOpenTrack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
      child: Column(
        children: [
          _PlaybackTrackHeader(
            coreBaseUrl: coreBaseUrl,
            track: track,
            trackId: trackId,
            title: title,
            artist: artist,
            album: album,
            compact: true,
            leadingSize: 54,
            onToggleFavorite: onToggleFavorite,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _LyricsPanel(
              lyricsText: lyricsText,
              translationText: lyricsTranslation,
              pronunciationText: lyricsPronunciation,
              offsetMs: lyricsOffsetMs,
              playback: playback,
              durationMs: durationMs,
              onSeek: onSeek,
              showHeader: false,
              glassFade: true,
            ),
          ),
          const SizedBox(height: 10),
          _PlaybackProgressControl(
            playback: playback,
            durationMs: durationMs,
            onSeek: onSeek,
            dense: true,
          ),
          _PlaybackButtonRow(
            hasTrack: trackId != null,
            isPaused: isPaused,
            state: state,
            activeZoneId: activeZoneId,
            playbackMode: playbackMode,
            onResume: onResume,
            onPause: onPause,
            onPrevious: onPrevious,
            onNext: onNext,
            onCycleMode: onCycleMode,
            onShowModeMenu: onShowModeMenu,
            onShowQueue: onShowQueue,
          ),
          _CompactPlaybackExtensions(
            page: page,
            volumeState: volumeState,
            onGoToPage: onGoToPage,
            onShowDevices: onShowDevices,
            onOpenTrack: trackId == null
                ? null
                : () => unawaited(onOpenTrack(trackId!)),
            onVolumeChanged: onVolumeChanged,
            onToggleMute: onToggleMute,
          ),
        ],
      ),
    );
  }
}

class _PlaybackTrackHeader extends StatelessWidget {
  const _PlaybackTrackHeader({
    required this.coreBaseUrl,
    required this.track,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.compact,
    required this.onToggleFavorite,
    this.leadingSize,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? track;
  final int? trackId;
  final String title;
  final String artist;
  final String album;
  final bool compact;
  final double? leadingSize;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final favorite = track?['is_favorite'] == true;
    final text = Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style:
                  (compact
                          ? Theme.of(context).textTheme.titleLarge
                          : Theme.of(context).textTheme.displaySmall)
                      ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              _joinParts([artist, album]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
          ],
        ),
      ),
    );

    return Row(
      children: [
        if (leadingSize != null) ...[
          _ArtworkTile(
            title: title,
            subtitle: artist,
            size: leadingSize!,
            icon: Icons.album_outlined,
            imageUrl: _trackArtworkUrl(coreBaseUrl, trackId),
          ),
          const SizedBox(width: 12),
        ],
        text,
        _AppTooltip(
          message: _tr(context, 'Favorite'),
          child: IconButton(
            onPressed: track == null
                ? null
                : () => unawaited(onToggleFavorite(track!)),
            icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
            color: favorite ? appPrimary : null,
          ),
        ),
      ],
    );
  }
}

class _PlaybackButtonRow extends StatelessWidget {
  const _PlaybackButtonRow({
    required this.hasTrack,
    required this.isPaused,
    required this.state,
    required this.activeZoneId,
    required this.playbackMode,
    required this.onResume,
    required this.onPause,
    required this.onPrevious,
    required this.onNext,
    required this.onCycleMode,
    required this.onShowModeMenu,
    required this.onShowQueue,
  });

  final bool hasTrack;
  final bool isPaused;
  final String state;
  final String activeZoneId;
  final _PlaybackMode playbackMode;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final VoidCallback onCycleMode;
  final void Function(BuildContext) onShowModeMenu;
  final void Function(BuildContext) onShowQueue;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Builder(
          builder: (buttonContext) => GestureDetector(
            onLongPress: () => onShowModeMenu(buttonContext),
            child: _AppTooltip(
              message: _playbackModeLabel(context, playbackMode),
              child: IconButton(
                onPressed: onCycleMode,
                icon: Icon(_playbackModeIcon(playbackMode)),
              ),
            ),
          ),
        ),
        _AppTooltip(
          message: _tr(context, 'Previous'),
          child: IconButton(
            onPressed: hasTrack ? () => unawaited(onPrevious()) : null,
            iconSize: 32,
            icon: const Icon(Icons.skip_previous),
          ),
        ),
        const SizedBox(width: 10),
        _AppTooltip(
          message: isPaused ? _tr(context, 'Resume') : _tr(context, 'Pause'),
          child: IconButton.filled(
            onPressed: hasTrack
                ? () {
                    if (isPaused || state == 'stopped') {
                      unawaited(onResume(activeZoneId));
                    } else {
                      unawaited(onPause(activeZoneId));
                    }
                  }
                : null,
            iconSize: 32,
            icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
          ),
        ),
        const SizedBox(width: 10),
        _AppTooltip(
          message: _tr(context, 'Next'),
          child: IconButton(
            onPressed: hasTrack ? () => unawaited(onNext()) : null,
            iconSize: 32,
            icon: const Icon(Icons.skip_next),
          ),
        ),
        Builder(
          builder: (buttonContext) => _AppTooltip(
            message: _tr(context, 'Open queue'),
            child: IconButton(
              onPressed: () => onShowQueue(buttonContext),
              icon: const Icon(Icons.queue_music_outlined),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaybackInlineActions extends StatelessWidget {
  const _PlaybackInlineActions({
    required this.trackId,
    required this.volumeState,
    required this.onShowDevices,
    required this.onOpenTrack,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  final int? trackId;
  final _DualVolumeState volumeState;
  final void Function(BuildContext) onShowDevices;
  final Future<void> Function(int) onOpenTrack;
  final void Function(String mode, double volume) onVolumeChanged;
  final ValueChanged<String> onToggleMute;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Builder(
          builder: (buttonContext) => TextButton.icon(
            onPressed: () => onShowDevices(buttonContext),
            icon: const Icon(Icons.cast_connected_outlined),
            label: Text(_tr(context, 'Devices')),
          ),
        ),
        TextButton.icon(
          onPressed: trackId == null
              ? null
              : () => unawaited(onOpenTrack(trackId!)),
          icon: const Icon(Icons.info_outline),
          label: Text(_tr(context, 'Details')),
        ),
        _VolumeControl(
          state: volumeState,
          onChanged: onVolumeChanged,
          onToggleMute: onToggleMute,
        ),
      ],
    );
  }
}

class _CompactPlaybackExtensions extends StatelessWidget {
  const _CompactPlaybackExtensions({
    required this.page,
    required this.volumeState,
    required this.onGoToPage,
    required this.onShowDevices,
    required this.onOpenTrack,
    required this.onVolumeChanged,
    required this.onToggleMute,
  });

  final int page;
  final _DualVolumeState volumeState;
  final ValueChanged<int> onGoToPage;
  final void Function(BuildContext) onShowDevices;
  final VoidCallback? onOpenTrack;
  final void Function(String mode, double volume) onVolumeChanged;
  final ValueChanged<String> onToggleMute;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _AppTooltip(
          message: _tr(context, 'Player page'),
          child: IconButton(
            onPressed: page == 0 ? null : () => onGoToPage(0),
            icon: const Icon(Icons.chevron_left),
          ),
        ),
        Builder(
          builder: (buttonContext) => TextButton.icon(
            onPressed: () => onShowDevices(buttonContext),
            icon: const Icon(Icons.cast_connected_outlined),
            label: Text(_tr(context, 'Devices')),
          ),
        ),
        TextButton.icon(
          onPressed: onOpenTrack,
          icon: const Icon(Icons.info_outline),
          label: Text(_tr(context, 'Details')),
        ),
        _VolumeControl(
          state: volumeState,
          onChanged: onVolumeChanged,
          onToggleMute: onToggleMute,
        ),
        _AppTooltip(
          message: _tr(context, 'Lyrics page'),
          child: IconButton(
            onPressed: page == 1 ? null : () => onGoToPage(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ),
      ],
    );
  }
}

class _PlaybackProgressControl extends StatefulWidget {
  const _PlaybackProgressControl({
    required this.playback,
    required this.durationMs,
    required this.onSeek,
    this.dense = false,
  });

  final Map<String, dynamic>? playback;
  final int durationMs;
  final Future<void> Function(int) onSeek;
  final bool dense;

  @override
  State<_PlaybackProgressControl> createState() =>
      _PlaybackProgressControlState();
}

class _PlaybackProgressControlState extends State<_PlaybackProgressControl> {
  Timer? _timer;
  int? _dragPositionMs;
  int? _optimisticPositionMs;
  int? _optimisticTrackId;
  int? _optimisticSinceMs;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _PlaybackProgressControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_intValue(oldWidget.playback?['track_id']) !=
        _intValue(widget.playback?['track_id'])) {
      _dragPositionMs = null;
      _clearOptimisticPosition();
    } else {
      _clearSyncedOptimisticPosition();
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    final shouldTick =
        widget.playback != null &&
        ((widget.playback?['state']?.toString() == 'playing' &&
                _intValue(widget.playback?['track_id']) != null) ||
            _optimisticPositionMs != null);
    if (!shouldTick) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _dragPositionMs == null) {
        setState(_clearSyncedOptimisticPosition);
      }
    });
  }

  void _clearOptimisticPosition() {
    _optimisticPositionMs = null;
    _optimisticTrackId = null;
    _optimisticSinceMs = null;
  }

  void _clearSyncedOptimisticPosition() {
    final optimistic = _optimisticPositionMs;
    if (optimistic == null) {
      return;
    }
    final trackId = _intValue(widget.playback?['track_id']);
    if (trackId == null || trackId != _optimisticTrackId) {
      _clearOptimisticPosition();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final optimisticAge = now - (_optimisticSinceMs ?? now);
    final actual = _estimatedPlaybackPositionMs(
      widget.playback,
      widget.durationMs,
    );
    if ((actual - _estimatedOptimisticPositionMs()).abs() < 1400 ||
        optimisticAge > 5000) {
      _clearOptimisticPosition();
    }
  }

  int _estimatedOptimisticPositionMs() {
    final base = _optimisticPositionMs;
    if (base == null) {
      return _estimatedPlaybackPositionMs(widget.playback, widget.durationMs);
    }
    final since = _optimisticSinceMs;
    final elapsed = widget.playback?['state']?.toString() == 'playing'
        ? DateTime.now().millisecondsSinceEpoch -
              (since ?? DateTime.now().millisecondsSinceEpoch)
        : 0;
    final estimate = base + max(0, elapsed);
    if (widget.durationMs > 0) {
      return estimate.clamp(0, widget.durationMs).toInt();
    }
    return estimate.clamp(0, 1 << 31).toInt();
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = _intValue(widget.playback?['track_id']) != null;
    final canSeek = hasTrack && widget.durationMs > 0;
    final positionMs = _dragPositionMs ?? _estimatedOptimisticPositionMs();
    final sliderMax = widget.durationMs > 0
        ? widget.durationMs.toDouble()
        : 1.0;
    final sliderValue = positionMs.clamp(
      0,
      widget.durationMs > 0 ? widget.durationMs : 1,
    );

    final slider = Slider(
      value: sliderValue.toDouble(),
      max: sliderMax,
      onChanged: canSeek
          ? (value) => setState(() => _dragPositionMs = value.round())
          : null,
      onChangeEnd: canSeek
          ? (value) {
              final positionMs = value.round();
              setState(() {
                _dragPositionMs = null;
                _optimisticPositionMs = positionMs;
                _optimisticTrackId = _intValue(widget.playback?['track_id']);
                _optimisticSinceMs = DateTime.now().millisecondsSinceEpoch;
              });
              _syncTimer();
              unawaited(widget.onSeek(positionMs));
            }
          : null,
    );

    return ExcludeSemantics(
      child: widget.dense
          ? Row(
              children: [
                Text(_formatDuration(positionMs)),
                Expanded(child: slider),
                Text(
                  widget.durationMs > 0
                      ? _formatDuration(widget.durationMs)
                      : '--:--',
                ),
              ],
            )
          : Column(
              children: [
                slider,
                Row(
                  children: [
                    Text(_formatDuration(positionMs)),
                    const Spacer(),
                    Text(
                      widget.durationMs > 0
                          ? _formatDuration(widget.durationMs)
                          : '--:--',
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
