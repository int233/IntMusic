part of '../intmusic_client.dart';

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
