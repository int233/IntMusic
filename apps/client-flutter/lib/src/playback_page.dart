part of '../main.dart';

class _PlaybackPage extends StatelessWidget {
  const _PlaybackPage({
    required this.coreBaseUrl,
    required this.playback,
    required this.trackDetail,
    required this.activeZoneId,
    required this.playbackMode,
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
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
    required this.onVolumeModeChanged,
    required this.onToggleFavorite,
    required this.onOpenTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? playback;
  final Map<String, dynamic>? trackDetail;
  final String activeZoneId;
  final _PlaybackMode playbackMode;
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function(int) onSeek;
  final VoidCallback onCycleMode;
  final void Function(BuildContext) onShowModeMenu;
  final void Function(BuildContext) onShowQueue;
  final void Function(BuildContext) onShowDevices;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onOpenTrack;

  @override
  Widget build(BuildContext context) {
    final track = trackDetail == null ? null : _asMap(trackDetail!['track']);
    final trackId = _intValue(playback?['track_id']);
    final state = playback?['state']?.toString() ?? 'stopped';
    final durationMs = _intValue(track?['duration_ms']) ?? 0;
    final lyrics = trackDetail?['lyrics'] == null
        ? null
        : _asMap(trackDetail!['lyrics']);
    final title =
        track?['title']?.toString() ??
        playback?['track_title']?.toString() ??
        _tr(context, 'No active track');
    final artist =
        track?['artist_display']?.toString() ?? _tr(context, 'Unknown Artist');
    final album = track?['album_title']?.toString() ?? '';
    final isPaused = state == 'paused';

    return _PageFrame(
      title: 'Playback',
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _compactWidth ||
              constraints.maxHeight < _compactHeight) {
            return _PlaybackLayoutTransition(
              layoutKey: 'compact',
              child: _CompactPlaybackPager(
                coreBaseUrl: coreBaseUrl,
                playback: playback,
                track: track,
                trackDetail: trackDetail,
                trackId: trackId,
                title: title,
                artist: artist,
                album: album,
                state: state,
                isPaused: isPaused,
                activeZoneId: activeZoneId,
                durationMs: durationMs,
                lyricsText: lyrics?['text']?.toString() ?? '',
                lyricsTranslation: lyrics?['translation']?.toString() ?? '',
                lyricsPronunciation: lyrics?['pronunciation']?.toString() ?? '',
                lyricsOffsetMs: _intValue(lyrics?['offset_ms']) ?? 0,
                playbackMode: playbackMode,
                volume: volume,
                muted: muted,
                volumeMode: volumeMode,
                systemVolumeSupported: systemVolumeSupported,
                onResume: onResume,
                onPause: onPause,
                onPrevious: onPrevious,
                onNext: onNext,
                onSeek: onSeek,
                onCycleMode: onCycleMode,
                onShowModeMenu: onShowModeMenu,
                onShowQueue: onShowQueue,
                onShowDevices: onShowDevices,
                onVolumeChanged: onVolumeChanged,
                onToggleMute: onToggleMute,
                onVolumeModeChanged: onVolumeModeChanged,
                onToggleFavorite: onToggleFavorite,
                onOpenTrack: onOpenTrack,
              ),
            );
          }

          final artworkLimit = constraints.maxWidth >= 1100 ? 420.0 : 340.0;
          final artworkSize = min(
            artworkLimit,
            constraints.maxHeight * 0.46,
          ).clamp(260.0, artworkLimit);
          final left = Padding(
            padding: const EdgeInsets.fromLTRB(28, 16, 24, 28),
            child: Column(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ArtworkTile(
                        title: title,
                        subtitle: artist,
                        size: artworkSize,
                        icon: Icons.album_outlined,
                        imageUrl: _trackArtworkUrl(coreBaseUrl, trackId),
                      ),
                      const SizedBox(height: 20),
                      _PlaybackTrackHeader(
                        coreBaseUrl: coreBaseUrl,
                        track: track,
                        trackId: trackId,
                        title: title,
                        artist: artist,
                        album: album,
                        compact: true,
                        onToggleFavorite: onToggleFavorite,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _PlaybackProgressControl(
                  playback: playback,
                  durationMs: durationMs,
                  onSeek: onSeek,
                ),
                const SizedBox(height: 16),
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
                const SizedBox(height: 8),
                _PlaybackInlineActions(
                  trackId: trackId,
                  volume: volume,
                  muted: muted,
                  volumeMode: volumeMode,
                  systemVolumeSupported: systemVolumeSupported,
                  onShowDevices: onShowDevices,
                  onOpenTrack: onOpenTrack,
                  onVolumeChanged: onVolumeChanged,
                  onToggleMute: onToggleMute,
                  onVolumeModeChanged: onVolumeModeChanged,
                ),
              ],
            ),
          );

          final right = Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 28, 28),
            child: _LyricsPanel(
              lyricsText: lyrics?['text']?.toString() ?? '',
              translationText: lyrics?['translation']?.toString() ?? '',
              pronunciationText: lyrics?['pronunciation']?.toString() ?? '',
              offsetMs: _intValue(lyrics?['offset_ms']) ?? 0,
              playback: playback,
              durationMs: durationMs,
              onSeek: onSeek,
              showHeader: false,
              glassFade: true,
            ),
          );

          return _PlaybackLayoutTransition(
            layoutKey: 'split',
            child: Row(
              children: [
                SizedBox(width: constraints.maxWidth * 0.46, child: left),
                const SizedBox(width: 1),
                Expanded(child: right),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PlaybackLayoutTransition extends StatelessWidget {
  const _PlaybackLayoutTransition({
    required this.layoutKey,
    required this.child,
  });

  final String layoutKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    final reduceMotion =
        (mediaQuery?.disableAnimations ?? false) ||
        (mediaQuery?.accessibleNavigation ?? false);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: duration,
        reverseDuration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, ?currentChild],
        ),
        transitionBuilder: (child, animation) {
          final scale = Tween<double>(
            begin: 0.985,
            end: 1,
          ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut));
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: scale, child: child),
          );
        },
        child: KeyedSubtree(key: ValueKey(layoutKey), child: child),
      ),
    );
  }
}

class _CompactPlaybackPager extends StatefulWidget {
  const _CompactPlaybackPager({
    required this.coreBaseUrl,
    required this.playback,
    required this.track,
    required this.trackDetail,
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
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
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
    required this.onVolumeModeChanged,
    required this.onToggleFavorite,
    required this.onOpenTrack,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? playback;
  final Map<String, dynamic>? track;
  final Map<String, dynamic>? trackDetail;
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
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function(int) onSeek;
  final VoidCallback onCycleMode;
  final void Function(BuildContext) onShowModeMenu;
  final void Function(BuildContext) onShowQueue;
  final void Function(BuildContext) onShowDevices;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onOpenTrack;

  @override
  State<_CompactPlaybackPager> createState() => _CompactPlaybackPagerState();
}

class _CompactPlaybackPagerState extends State<_CompactPlaybackPager> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    _controller.animateToPage(
      page.clamp(0, 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _controller,
      onPageChanged: (value) => setState(() => _page = value),
      children: [
        _CompactPlayerPane(
          coreBaseUrl: widget.coreBaseUrl,
          playback: widget.playback,
          track: widget.track,
          trackId: widget.trackId,
          title: widget.title,
          artist: widget.artist,
          album: widget.album,
          state: widget.state,
          isPaused: widget.isPaused,
          activeZoneId: widget.activeZoneId,
          durationMs: widget.durationMs,
          playbackMode: widget.playbackMode,
          volume: widget.volume,
          muted: widget.muted,
          volumeMode: widget.volumeMode,
          systemVolumeSupported: widget.systemVolumeSupported,
          page: _page,
          onGoToPage: _goTo,
          onResume: widget.onResume,
          onPause: widget.onPause,
          onPrevious: widget.onPrevious,
          onNext: widget.onNext,
          onSeek: widget.onSeek,
          onCycleMode: widget.onCycleMode,
          onShowModeMenu: widget.onShowModeMenu,
          onShowQueue: widget.onShowQueue,
          onShowDevices: widget.onShowDevices,
          onVolumeChanged: widget.onVolumeChanged,
          onToggleMute: widget.onToggleMute,
          onVolumeModeChanged: widget.onVolumeModeChanged,
          onToggleFavorite: widget.onToggleFavorite,
          onOpenTrack: widget.onOpenTrack,
        ),
        _CompactLyricsPane(
          coreBaseUrl: widget.coreBaseUrl,
          playback: widget.playback,
          track: widget.track,
          trackId: widget.trackId,
          title: widget.title,
          artist: widget.artist,
          album: widget.album,
          state: widget.state,
          isPaused: widget.isPaused,
          activeZoneId: widget.activeZoneId,
          durationMs: widget.durationMs,
          lyricsText: widget.lyricsText,
          lyricsTranslation: widget.lyricsTranslation,
          lyricsPronunciation: widget.lyricsPronunciation,
          lyricsOffsetMs: widget.lyricsOffsetMs,
          playbackMode: widget.playbackMode,
          volume: widget.volume,
          muted: widget.muted,
          volumeMode: widget.volumeMode,
          systemVolumeSupported: widget.systemVolumeSupported,
          page: _page,
          onGoToPage: _goTo,
          onResume: widget.onResume,
          onPause: widget.onPause,
          onPrevious: widget.onPrevious,
          onNext: widget.onNext,
          onSeek: widget.onSeek,
          onCycleMode: widget.onCycleMode,
          onShowModeMenu: widget.onShowModeMenu,
          onShowQueue: widget.onShowQueue,
          onShowDevices: widget.onShowDevices,
          onVolumeChanged: widget.onVolumeChanged,
          onToggleMute: widget.onToggleMute,
          onVolumeModeChanged: widget.onVolumeModeChanged,
          onToggleFavorite: widget.onToggleFavorite,
          onOpenTrack: widget.onOpenTrack,
        ),
      ],
    );
  }
}

class _CompactPlayerPane extends StatelessWidget {
  const _CompactPlayerPane({
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
    required this.playbackMode,
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
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
    required this.onVolumeModeChanged,
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
  final _PlaybackMode playbackMode;
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
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
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;
  final Future<void> Function(Map<String, dynamic>) onToggleFavorite;
  final Future<void> Function(int) onOpenTrack;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final artworkSize = min(
          min(constraints.maxWidth - 72, constraints.maxHeight * 0.48),
          360.0,
        ).clamp(180.0, 360.0);
        final content = Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: _ArtworkTile(
                  title: title,
                  subtitle: artist,
                  size: artworkSize,
                  icon: Icons.album_outlined,
                  imageUrl: _trackArtworkUrl(coreBaseUrl, trackId),
                ),
              ),
              const SizedBox(height: 18),
              _PlaybackTrackHeader(
                coreBaseUrl: coreBaseUrl,
                track: track,
                trackId: trackId,
                title: title,
                artist: artist,
                album: album,
                compact: true,
                onToggleFavorite: onToggleFavorite,
              ),
              const Spacer(),
              _PlaybackProgressControl(
                playback: playback,
                durationMs: durationMs,
                onSeek: onSeek,
              ),
              const SizedBox(height: 8),
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
              const SizedBox(height: 8),
              _CompactPlaybackExtensions(
                page: page,
                volume: volume,
                muted: muted,
                volumeMode: volumeMode,
                systemVolumeSupported: systemVolumeSupported,
                onGoToPage: onGoToPage,
                onShowDevices: onShowDevices,
                onOpenTrack: trackId == null
                    ? null
                    : () => unawaited(onOpenTrack(trackId!)),
                onVolumeChanged: onVolumeChanged,
                onToggleMute: onToggleMute,
                onVolumeModeChanged: onVolumeModeChanged,
              ),
            ],
          ),
        );
        if (constraints.maxHeight < 560) {
          return SingleChildScrollView(
            child: SizedBox(height: 560, child: content),
          );
        }
        return content;
      },
    );
  }
}

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
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
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
    required this.onVolumeModeChanged,
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
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
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
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;
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
            volume: volume,
            muted: muted,
            volumeMode: volumeMode,
            systemVolumeSupported: systemVolumeSupported,
            onGoToPage: onGoToPage,
            onShowDevices: onShowDevices,
            onOpenTrack: trackId == null
                ? null
                : () => unawaited(onOpenTrack(trackId!)),
            onVolumeChanged: onVolumeChanged,
            onToggleMute: onToggleMute,
            onVolumeModeChanged: onVolumeModeChanged,
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
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
    required this.onShowDevices,
    required this.onOpenTrack,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onVolumeModeChanged,
  });

  final int? trackId;
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
  final void Function(BuildContext) onShowDevices;
  final Future<void> Function(int) onOpenTrack;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;

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
          volume: volume,
          muted: muted,
          mode: volumeMode,
          systemVolumeSupported: systemVolumeSupported,
          onChanged: onVolumeChanged,
          onToggleMute: onToggleMute,
          onModeChanged: onVolumeModeChanged,
        ),
      ],
    );
  }
}

class _CompactPlaybackExtensions extends StatelessWidget {
  const _CompactPlaybackExtensions({
    required this.page,
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
    required this.onGoToPage,
    required this.onShowDevices,
    required this.onOpenTrack,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onVolumeModeChanged,
  });

  final int page;
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
  final ValueChanged<int> onGoToPage;
  final void Function(BuildContext) onShowDevices;
  final VoidCallback? onOpenTrack;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;

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
          volume: volume,
          muted: muted,
          mode: volumeMode,
          systemVolumeSupported: systemVolumeSupported,
          onChanged: onVolumeChanged,
          onToggleMute: onToggleMute,
          onModeChanged: onVolumeModeChanged,
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

class _ZonesPanel extends StatelessWidget {
  const _ZonesPanel({
    required this.zones,
    required this.selectedZoneId,
    required this.activeZoneId,
    required this.hasActiveTrack,
    required this.currentClientZonePrefix,
    required this.pinCurrentClientRegion,
    required this.regionSort,
    required this.onSelect,
    required this.onResume,
    required this.onPause,
    required this.onStop,
    required this.onMoveHere,
    required this.onRename,
  });

  final List<dynamic> zones;
  final String selectedZoneId;
  final String activeZoneId;
  final bool hasActiveTrack;
  final String currentClientZonePrefix;
  final bool pinCurrentClientRegion;
  final _ZoneRegionSort regionSort;
  final Future<void> Function(Map<String, dynamic>) onSelect;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function(String) onStop;
  final Future<void> Function(String) onMoveHere;
  final Future<void> Function(String, String?) onRename;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final item in zones) {
      final zone = (item as Map).cast<String, dynamic>();
      final group = _zoneGroupName(zone);
      groups.putIfAbsent(group, () => []).add(zone);
    }
    bool isPlaying(Map<String, dynamic> zone) =>
        zone['state']?.toString() == 'playing';
    for (final groupZones in groups.values) {
      groupZones.sort((left, right) {
        if (regionSort == _ZoneRegionSort.playingFirst) {
          final playingOrder =
              (isPlaying(right) ? 1 : 0) - (isPlaying(left) ? 1 : 0);
          if (playingOrder != 0) {
            return playingOrder;
          }
        }
        return _zoneDisplayName(
          left,
        ).toLowerCase().compareTo(_zoneDisplayName(right).toLowerCase());
      });
    }
    final groupEntries = groups.entries.toList()
      ..sort((left, right) {
        if (pinCurrentClientRegion) {
          final leftCurrent = left.value.any(
            (zone) =>
                zone['id']?.toString().startsWith(currentClientZonePrefix) ==
                true,
          );
          final rightCurrent = right.value.any(
            (zone) =>
                zone['id']?.toString().startsWith(currentClientZonePrefix) ==
                true,
          );
          if (leftCurrent != rightCurrent) {
            return leftCurrent ? -1 : 1;
          }
        }
        if (regionSort == _ZoneRegionSort.playingFirst) {
          final leftPlaying = left.value.any(isPlaying);
          final rightPlaying = right.value.any(isPlaying);
          if (leftPlaying != rightPlaying) {
            return leftPlaying ? -1 : 1;
          }
        }
        return left.key.toLowerCase().compareTo(right.key.toLowerCase());
      });

    return Material(
      color: IntMusicTheme.of(context).surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: IntMusicTheme.of(context).stroke),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Text(
                  _tr(context, 'Zones'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text('${zones.length} ${_tr(context, 'outputs')}'),
              ],
            ),
          ),
          const Divider(height: 1),
          if (zones.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(_tr(context, 'No playback zones'))),
            )
          else
            for (final group in groupEntries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    group.key,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: IntMusicTheme.of(context).textSecondary,
                    ),
                  ),
                ),
              ),
              for (var index = 0; index < group.value.length; index++) ...[
                _ZoneTile(
                  zone: group.value[index],
                  selectedZoneId: selectedZoneId,
                  activeZoneId: activeZoneId,
                  hasActiveTrack: hasActiveTrack,
                  onSelect: onSelect,
                  onResume: onResume,
                  onPause: onPause,
                  onStop: onStop,
                  onMoveHere: onMoveHere,
                  onRename: onRename,
                ),
                if (index != group.value.length - 1) const Divider(height: 1),
              ],
            ],
        ],
      ),
    );
  }
}

class _ZoneTile extends StatelessWidget {
  const _ZoneTile({
    required this.zone,
    required this.selectedZoneId,
    required this.activeZoneId,
    required this.hasActiveTrack,
    required this.onSelect,
    required this.onResume,
    required this.onPause,
    required this.onStop,
    required this.onMoveHere,
    required this.onRename,
  });

  final Map<String, dynamic> zone;
  final String selectedZoneId;
  final String activeZoneId;
  final bool hasActiveTrack;
  final Future<void> Function(Map<String, dynamic>) onSelect;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function(String) onStop;
  final Future<void> Function(String) onMoveHere;
  final Future<void> Function(String, String?) onRename;

  @override
  Widget build(BuildContext context) {
    final zoneId = zone['id']?.toString() ?? 'local';
    final state = zone['state']?.toString() ?? 'stopped';
    final isSelected = zoneId == selectedZoneId;
    final isActive = zoneId == activeZoneId;
    final isOnline = zone['is_online'] != false;
    final hasTrack = _intValue(zone['track_id']) != null;
    final canMoveHere = isOnline && hasActiveTrack && activeZoneId != zoneId;

    return Material(
      color: isActive
          ? IntMusicTheme.of(context).playing.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(onSelect(zone)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 520;
              final info = Expanded(child: _ZoneTileText(zone: zone));
              final actions = _ZoneTileActions(
                zone: zone,
                zoneId: zoneId,
                state: state,
                isSelected: isSelected,
                isOnline: isOnline,
                hasTrack: hasTrack,
                canMoveHere: canMoveHere,
                onSelect: onSelect,
                onResume: onResume,
                onPause: onPause,
                onStop: onStop,
                onMoveHere: onMoveHere,
                onRename: onRename,
              );
              final leading = Icon(
                _zoneStateIcon(state),
                color: isActive
                    ? IntMusicTheme.of(context).playing
                    : IntMusicTheme.of(context).textSecondary,
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [leading, const SizedBox(width: 12), info]),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                );
              }
              return Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  info,
                  const SizedBox(width: 8),
                  actions,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ZoneTileText extends StatelessWidget {
  const _ZoneTileText({required this.zone});

  final Map<String, dynamic> zone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _zoneDisplayName(zone),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          _zoneSubtitle(zone),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: IntMusicTheme.of(context).textSecondary,
          ),
        ),
      ],
    );
  }
}

class _ZoneTileActions extends StatelessWidget {
  const _ZoneTileActions({
    required this.zone,
    required this.zoneId,
    required this.state,
    required this.isSelected,
    required this.isOnline,
    required this.hasTrack,
    required this.canMoveHere,
    required this.onSelect,
    required this.onResume,
    required this.onPause,
    required this.onStop,
    required this.onMoveHere,
    required this.onRename,
  });

  final Map<String, dynamic> zone;
  final String zoneId;
  final String state;
  final bool isSelected;
  final bool isOnline;
  final bool hasTrack;
  final bool canMoveHere;
  final Future<void> Function(Map<String, dynamic>) onSelect;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function(String) onStop;
  final Future<void> Function(String) onMoveHere;
  final Future<void> Function(String, String?) onRename;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      alignment: WrapAlignment.end,
      children: [
        _AppTooltip(
          message: _tr(context, 'Rename'),
          child: IconButton(
            onPressed: () => _showZoneAliasDialog(context, zone, onRename),
            icon: const Icon(Icons.edit_outlined),
          ),
        ),
        _AppTooltip(
          message: 'Select',
          child: IconButton(
            onPressed: () => unawaited(onSelect(zone)),
            icon: Icon(
              isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
            ),
          ),
        ),
        _AppTooltip(
          message: state == 'paused' ? 'Resume' : 'Pause',
          child: IconButton(
            onPressed: isOnline && hasTrack
                ? () {
                    if (state == 'playing') {
                      unawaited(onPause(zoneId));
                    } else {
                      unawaited(onResume(zoneId));
                    }
                  }
                : null,
            icon: Icon(state == 'paused' ? Icons.play_arrow : Icons.pause),
          ),
        ),
        _AppTooltip(
          message: 'Move here',
          child: IconButton(
            onPressed: canMoveHere ? () => unawaited(onMoveHere(zoneId)) : null,
            icon: const Icon(Icons.move_up_outlined),
          ),
        ),
        _AppTooltip(
          message: 'Stop',
          child: IconButton(
            onPressed: isOnline && hasTrack
                ? () => unawaited(onStop(zoneId))
                : null,
            icon: const Icon(Icons.stop),
          ),
        ),
      ],
    );
  }
}

class _DeviceSheetSnapshot {
  const _DeviceSheetSnapshot({
    required this.zones,
    required this.selectedZoneId,
    required this.activeZoneId,
    required this.hasActiveTrack,
  });

  final List<dynamic> zones;
  final String selectedZoneId;
  final String activeZoneId;
  final bool hasActiveTrack;
}

class _DeviceSheet extends StatefulWidget {
  const _DeviceSheet({
    required this.snapshot,
    required this.currentClientZonePrefix,
    required this.pinCurrentClientRegion,
    required this.regionSort,
    required this.onRefresh,
    required this.onSelect,
    required this.onResume,
    required this.onPause,
    required this.onStop,
    required this.onMoveHere,
    required this.onPlayEverywhere,
    required this.onStopEverywhere,
    required this.onRename,
  });

  final _DeviceSheetSnapshot snapshot;
  final String currentClientZonePrefix;
  final bool pinCurrentClientRegion;
  final _ZoneRegionSort regionSort;
  final Future<_DeviceSheetSnapshot> Function() onRefresh;
  final Future<void> Function(Map<String, dynamic>) onSelect;
  final Future<void> Function(String) onResume;
  final Future<void> Function(String) onPause;
  final Future<void> Function(String) onStop;
  final Future<void> Function(String) onMoveHere;
  final Future<void> Function(String, String?) onRename;
  final Future<void> Function() onPlayEverywhere;
  final Future<void> Function() onStopEverywhere;

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  late _DeviceSheetSnapshot _snapshot = widget.snapshot;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refresh());
    });
  }

  @override
  void didUpdateWidget(covariant _DeviceSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) {
      _snapshot = widget.snapshot;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final snapshot = await widget.onRefresh();
    if (mounted) {
      setState(() => _snapshot = snapshot);
    }
  }

  Future<void> _runAndRefresh(Future<void> Function() action) async {
    await action();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final zones = _snapshot.zones;
    final hasActiveTrack = _snapshot.hasActiveTrack;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 440;
              final title = Text(
                _tr(context, 'Playback devices'),
                style: Theme.of(context).textTheme.titleLarge,
              );
              final actions = [
                FilledButton.tonalIcon(
                  onPressed: hasActiveTrack
                      ? () => unawaited(_runAndRefresh(widget.onPlayEverywhere))
                      : null,
                  icon: const Icon(Icons.speaker_group_outlined),
                  label: Text(_tr(context, 'Play everywhere')),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      unawaited(_runAndRefresh(widget.onStopEverywhere)),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(_tr(context, 'Stop everywhere')),
                ),
              ];
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                );
              }
              return Row(
                children: [
                  title,
                  const Spacer(),
                  actions[0],
                  const SizedBox(width: 8),
                  actions[1],
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: _ZonesPanel(
                zones: zones,
                selectedZoneId: _snapshot.selectedZoneId,
                activeZoneId: _snapshot.activeZoneId,
                hasActiveTrack: hasActiveTrack,
                currentClientZonePrefix: widget.currentClientZonePrefix,
                pinCurrentClientRegion: widget.pinCurrentClientRegion,
                regionSort: widget.regionSort,
                onSelect: (zone) async {
                  await widget.onSelect(zone);
                  await _refresh();
                },
                onResume: (zoneId) =>
                    _runAndRefresh(() => widget.onResume(zoneId)),
                onPause: (zoneId) =>
                    _runAndRefresh(() => widget.onPause(zoneId)),
                onStop: (zoneId) => _runAndRefresh(() => widget.onStop(zoneId)),
                onMoveHere: (zoneId) =>
                    _runAndRefresh(() => widget.onMoveHere(zoneId)),
                onRename: (zoneId, alias) =>
                    _runAndRefresh(() => widget.onRename(zoneId, alias)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void _showZoneAliasDialog(
  BuildContext context,
  Map<String, dynamic> zone,
  Future<void> Function(String, String?) onRename,
) {
  final zoneId = zone['id']?.toString();
  if (zoneId == null || zoneId.isEmpty) {
    return;
  }
  final controller = TextEditingController(
    text: zone['alias']?.toString() ?? '',
  );
  unawaited(
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_tr(context, 'Device alias')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: _tr(context, 'Alias'),
            hintText: _zoneDisplayName(zone).trim().isNotEmpty
                ? _zoneDisplayName(zone)
                : zone['system_name']?.toString() ??
                      zone['name']?.toString() ??
                      zoneId,
          ),
          onSubmitted: (_) {
            final alias = controller.text.trim();
            Navigator.of(context).pop();
            unawaited(onRename(zoneId, alias.isEmpty ? null : alias));
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(onRename(zoneId, null));
            },
            child: Text(_tr(context, 'Clear')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_tr(context, 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final alias = controller.text.trim();
              Navigator.of(context).pop();
              unawaited(onRename(zoneId, alias.isEmpty ? null : alias));
            },
            child: Text(_tr(context, 'Save')),
          ),
        ],
      ),
    ).whenComplete(controller.dispose),
  );
}

class _ModeSheet extends StatelessWidget {
  const _ModeSheet({required this.playbackMode, required this.onSelected});

  final _PlaybackMode playbackMode;
  final ValueChanged<_PlaybackMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _tr(context, 'Mode'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 10),
          for (final mode in _PlaybackMode.values)
            _SimpleListRow(
              leading: Icon(_playbackModeIcon(mode)),
              title: _playbackModeLabel(context, mode),
              subtitle: '',
              trailing: playbackMode == mode
                  ? const Icon(Icons.check_circle)
                  : null,
              onTap: () => onSelected(mode),
            ),
        ],
      ),
    );
  }
}

class _QueueSheet extends StatefulWidget {
  const _QueueSheet({
    required this.coreBaseUrl,
    required this.items,
    required this.currentIndex,
    required this.onPlayTrack,
    required this.onMove,
    required this.onRemove,
    required this.onClearUpcoming,
    required this.onClearAll,
  });

  final String coreBaseUrl;
  final List<Map<String, dynamic>> items;
  final int? currentIndex;
  final Future<void> Function(int) onPlayTrack;
  final Future<Map<String, dynamic>?> Function(int, int) onMove;
  final Future<Map<String, dynamic>?> Function(int) onRemove;
  final Future<Map<String, dynamic>?> Function() onClearUpcoming;
  final Future<Map<String, dynamic>?> Function() onClearAll;

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  late List<Map<String, dynamic>> _items = widget.items;
  late int? _currentIndex = widget.currentIndex;
  bool _mutating = false;

  void _applyQueue(Map<String, dynamic> queue) {
    _items = ((queue['items'] as List?) ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
    _currentIndex = _intValue(queue['current_index']);
  }

  Future<void> _move(int oldIndex, int newIndex) async {
    if (_mutating || oldIndex == newIndex) {
      return;
    }
    setState(() => _mutating = true);
    final queue = await widget.onMove(oldIndex, newIndex);
    if (!mounted) {
      return;
    }
    setState(() {
      if (queue != null) {
        _applyQueue(queue);
      }
      _mutating = false;
    });
  }

  Future<void> _remove(int itemId) async {
    if (_mutating) {
      return;
    }
    setState(() => _mutating = true);
    final queue = await widget.onRemove(itemId);
    if (!mounted) {
      return;
    }
    setState(() {
      if (queue != null) {
        _applyQueue(queue);
      }
      _mutating = false;
    });
  }

  Future<void> _clear({required bool all}) async {
    if (_mutating) {
      return;
    }
    setState(() => _mutating = true);
    final queue = await (all ? widget.onClearAll() : widget.onClearUpcoming());
    if (!mounted) {
      return;
    }
    setState(() {
      if (queue != null) {
        _applyQueue(queue);
      }
      _mutating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 520,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tr(context, 'Queue'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: _mutating || _items.isEmpty
                      ? null
                      : () => unawaited(_clear(all: false)),
                  child: Text(_tr(context, 'Clear upcoming')),
                ),
                PopupMenuButton<bool>(
                  enabled: !_mutating && _items.isNotEmpty,
                  tooltip: _tr(context, 'More'),
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (all) => unawaited(_clear(all: all)),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: true,
                      child: ListTile(
                        leading: const Icon(Icons.delete_sweep_outlined),
                        title: Text(_tr(context, 'Clear all')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _tr(context, 'Drag to reorder. Queue is synced across devices.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _items.isEmpty
                  ? Center(child: Text(_tr(context, 'No upcoming tracks')))
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      onReorderItem: (oldIndex, newIndex) =>
                          unawaited(_move(oldIndex, newIndex)),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final itemId = _intValue(item['id']);
                        final track = (item['track'] as Map)
                            .cast<String, dynamic>();
                        final id = _intValue(track['id']);
                        final title = track['title']?.toString() ?? 'Untitled';
                        final artist =
                            track['artist_display']?.toString() ?? '';
                        final isCurrent = _currentIndex == index;
                        return Container(
                          key: ValueKey(itemId ?? 'queue-$index-$id'),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? IntMusicTheme.of(
                                    context,
                                  ).accent.withValues(alpha: 0.1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: _SimpleListRow(
                            leading: isCurrent
                                ? Icon(
                                    Icons.graphic_eq_rounded,
                                    color: IntMusicTheme.of(context).playing,
                                  )
                                : _ArtworkTile(
                                    title: title,
                                    subtitle: artist,
                                    size: 42,
                                    icon: Icons.music_note_outlined,
                                    imageUrl: _trackArtworkUrl(
                                      widget.coreBaseUrl,
                                      id,
                                    ),
                                  ),
                            title: title,
                            subtitle: _joinParts([
                              isCurrent ? _tr(context, 'Now playing') : artist,
                              track['album_title'],
                              _formatDuration(track['duration_ms']),
                            ]),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: itemId == null || _mutating
                                      ? null
                                      : () => unawaited(_remove(itemId)),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  tooltip: _tr(context, 'Remove from queue'),
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Padding(
                                    padding: EdgeInsets.all(10),
                                    child: Icon(Icons.drag_handle_rounded),
                                  ),
                                ),
                              ],
                            ),
                            onTap: id == null
                                ? null
                                : () => unawaited(widget.onPlayTrack(id)),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
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
