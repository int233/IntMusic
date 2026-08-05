part of '../intmusic_client.dart';

class _AnimatedSidebarShell extends StatefulWidget {
  const _AnimatedSidebarShell({
    required this.expanded,
    required this.sidebar,
    required this.content,
  });

  final bool expanded;
  final Widget sidebar;
  final Widget content;

  @override
  State<_AnimatedSidebarShell> createState() => _AnimatedSidebarShellState();
}

class _AnimatedSidebarShellState extends State<_AnimatedSidebarShell>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 240);
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
    reverseDuration: _duration,
    value: widget.expanded ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.value = widget.expanded ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedSidebarShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) {
      return;
    }
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = Curves.easeInOutCubic.transform(_controller.value);
        return Row(
          children: [
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: Transform.translate(
                  offset: Offset(-20 * (1 - progress), 0),
                  child: Opacity(
                    opacity: progress,
                    child: ExcludeSemantics(
                      excluding: !widget.expanded,
                      child: IgnorePointer(
                        ignoring: !widget.expanded,
                        child: widget.sidebar,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: Opacity(
                  opacity: progress,
                  child: const VerticalDivider(width: 1),
                ),
              ),
            ),
            Expanded(child: widget.content),
          ],
        );
      },
    );
  }
}

class _PlaybackBar extends StatelessWidget {
  const _PlaybackBar({
    required this.coreBaseUrl,
    required this.state,
    required this.trackDetail,
    required this.targetLabel,
    required this.playbackMode,
    required this.volumeState,
    required this.onResume,
    required this.onPause,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onCycleMode,
    required this.onShowModeMenu,
    required this.onShowQueue,
    required this.onShowDevices,
    required this.onOpenPlayback,
    this.enableRevealGesture = false,
    this.onRevealStart,
    this.onRevealUpdate,
    this.onRevealEnd,
  });

  final String coreBaseUrl;
  final Map<String, dynamic>? state;
  final Map<String, dynamic>? trackDetail;
  final String targetLabel;
  final _PlaybackMode playbackMode;
  final _DualVolumeState volumeState;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(int) onSeek;
  final void Function(String mode, double volume) onVolumeChanged;
  final ValueChanged<String> onToggleMute;
  final VoidCallback onCycleMode;
  final void Function(BuildContext) onShowModeMenu;
  final void Function(BuildContext) onShowQueue;
  final void Function(BuildContext) onShowDevices;
  final VoidCallback onOpenPlayback;
  final bool enableRevealGesture;
  final VoidCallback? onRevealStart;
  final ValueChanged<double>? onRevealUpdate;
  final ValueChanged<double>? onRevealEnd;

  @override
  Widget build(BuildContext context) {
    final track = trackDetail == null ? null : _asMap(trackDetail!['track']);
    final title =
        track?['title']?.toString() ??
        state?['track_title']?.toString() ??
        _tr(context, 'Not playing');
    final artist = track?['artist_display']?.toString() ?? targetLabel;
    final status = state?['state']?.toString() ?? 'stopped';
    final isPaused = status == 'paused';
    final hasTrack = _intValue(state?['track_id']) != null;
    final durationMs = _intValue(track?['duration_ms']) ?? 0;
    // Queue navigation must not depend on a metadata request completing.
    // On a weak link the track can already be playing from a local copy while
    // its detail payload is still loading.
    final canNavigate = hasTrack;
    final compactScreen = MediaQuery.sizeOf(context).width < 560;

    final bar = Padding(
      padding: EdgeInsets.fromLTRB(
        compactScreen ? 8 : 10,
        0,
        compactScreen ? 8 : 10,
        compactScreen ? 6 : 10,
      ),
      child: IntMusicGlass(
        blur: 26,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compactScreen ? 10 : 14,
              compactScreen ? 4 : 8,
              compactScreen ? 10 : 14,
              compactScreen ? 4 : 8,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final compact = width < 760;
                final tight = width < 520;
                final showCover = width >= 430;
                final showPrevious = width >= 470;
                final showDeviceInline = width >= 620;
                final showModeInline = width >= 560;
                final showVolumeInline = !Platform.isAndroid && width >= 520;
                Widget cover(double size) {
                  final artwork = _ArtworkTile(
                    title: title,
                    subtitle: artist,
                    size: size,
                    icon: hasTrack
                        ? Icons.album_outlined
                        : Icons.music_note_outlined,
                    imageUrl: _trackArtworkUrl(coreBaseUrl, state?['track_id']),
                  );
                  if (!hasTrack) {
                    return artwork;
                  }
                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onOpenPlayback,
                      child: artwork,
                    ),
                  );
                }

                final info = Expanded(
                  flex: compact ? 1 : 0,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: tight ? 112 : 160,
                      maxWidth: compact ? double.infinity : 280,
                    ),
                    child: InkWell(
                      onTap: hasTrack ? onOpenPlayback : null,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: IntMusicTheme.of(
                                      context,
                                    ).textSecondary,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );

                final controls = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showPrevious)
                      _AppTooltip(
                        message: _tr(context, 'Previous'),
                        child: IconButton(
                          onPressed: canNavigate ? onPrevious : null,
                          icon: const Icon(Icons.skip_previous),
                        ),
                      ),
                    _AppTooltip(
                      message: isPaused
                          ? _tr(context, 'Resume')
                          : _tr(context, 'Pause'),
                      child: IconButton.filled(
                        onPressed: hasTrack
                            ? (isPaused ? onResume : onPause)
                            : null,
                        icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
                      ),
                    ),
                    _AppTooltip(
                      message: _tr(context, 'Next'),
                      child: IconButton(
                        onPressed: canNavigate ? onNext : null,
                        icon: const Icon(Icons.skip_next),
                      ),
                    ),
                  ],
                );

                final actions = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showModeInline)
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
                    Builder(
                      builder: (buttonContext) => _AppTooltip(
                        message: _tr(context, 'Queue'),
                        child: IconButton(
                          onPressed: () => onShowQueue(buttonContext),
                          icon: const Icon(Icons.queue_music_outlined),
                        ),
                      ),
                    ),
                    if (showDeviceInline)
                      Builder(
                        builder: (buttonContext) => _AppTooltip(
                          message: targetLabel,
                          child: IconButton(
                            onPressed: () => onShowDevices(buttonContext),
                            icon: const Icon(Icons.speaker_group_outlined),
                          ),
                        ),
                      ),
                    if (showVolumeInline) ...[
                      const SizedBox(width: 4),
                      _VolumeControl(
                        state: volumeState,
                        targetLabel: targetLabel,
                        onChanged: onVolumeChanged,
                        onToggleMute: onToggleMute,
                      ),
                    ],
                    if (!showModeInline || !showDeviceInline)
                      Builder(
                        builder: (buttonContext) => _AppTooltip(
                          message: _tr(context, 'Devices'),
                          child: IconButton(
                            onPressed: () => onShowDevices(buttonContext),
                            icon: const Icon(Icons.more_horiz),
                          ),
                        ),
                      ),
                  ],
                );

                final topRow = Row(
                  children: [
                    if (showCover) ...[
                      cover(compact ? 46 : 56),
                      const SizedBox(width: 10),
                    ],
                    info,
                    const SizedBox(width: 8),
                    controls,
                    const SizedBox(width: 6),
                    actions,
                  ],
                );

                final progress = _PlaybackProgressControl(
                  playback: state,
                  durationMs: durationMs,
                  onSeek: onSeek,
                  dense: true,
                );

                if (!compact) {
                  return SizedBox(
                    height: 74,
                    child: Row(
                      children: [
                        if (showCover) ...[
                          cover(56),
                          const SizedBox(width: 10),
                        ],
                        info,
                        const SizedBox(width: 14),
                        controls,
                        const SizedBox(width: 18),
                        Expanded(child: progress),
                        const SizedBox(width: 10),
                        actions,
                      ],
                    ),
                  );
                }

                return SizedBox(
                  height: tight ? 92 : 104,
                  child: Column(
                    children: [
                      topRow,
                      SizedBox(height: tight ? 0 : 2),
                      Expanded(child: progress),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    if (!enableRevealGesture || !hasTrack) {
      return bar;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => onRevealStart?.call(),
      onVerticalDragUpdate: (details) {
        final delta = details.primaryDelta ?? details.delta.dy;
        onRevealUpdate?.call((-delta / 420).clamp(-1.0, 1.0));
      },
      onVerticalDragEnd: (details) {
        onRevealEnd?.call(-(details.primaryVelocity ?? 0));
      },
      onVerticalDragCancel: () => onRevealEnd?.call(0),
      child: bar,
    );
  }
}

class _DualVolumeState {
  const _DualVolumeState({
    required this.playerVolume,
    required this.playerMuted,
    required this.systemVolume,
    required this.systemMuted,
    required this.systemVolumeSupported,
  });

  final double playerVolume;
  final bool playerMuted;
  final double systemVolume;
  final bool systemMuted;
  final bool systemVolumeSupported;
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.state,
    required this.onChanged,
    required this.onToggleMute,
    this.targetLabel,
  });

  final _DualVolumeState state;
  final void Function(String mode, double volume) onChanged;
  final ValueChanged<String> onToggleMute;
  final String? targetLabel;

  @override
  Widget build(BuildContext context) {
    final value = state.playerVolume.clamp(0.0, 1.0);
    final icon = state.playerMuted || value <= 0.001
        ? Icons.volume_off_rounded
        : value < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;
    return Builder(
      builder: (buttonContext) => _AppTooltip(
        message: _tr(context, 'Volume'),
        child: IconButton(
          onPressed: () => unawaited(
            _showAnchoredPopup<void>(
              context: buttonContext,
              anchorContext: buttonContext,
              width: 286,
              maxHeight: 360,
              child: _VerticalVolumePanel(
                state: state,
                targetLabel: targetLabel,
                onChanged: onChanged,
                onToggleMute: onToggleMute,
              ),
            ),
          ),
          icon: Icon(icon, size: 20),
        ),
      ),
    );
  }
}

class _VerticalVolumePanel extends StatefulWidget {
  const _VerticalVolumePanel({
    required this.state,
    required this.onChanged,
    required this.onToggleMute,
    this.targetLabel,
  });

  final _DualVolumeState state;
  final void Function(String mode, double volume) onChanged;
  final ValueChanged<String> onToggleMute;
  final String? targetLabel;

  @override
  State<_VerticalVolumePanel> createState() => _VerticalVolumePanelState();
}

class _VerticalVolumePanelState extends State<_VerticalVolumePanel> {
  late double _playerValue = widget.state.playerVolume.clamp(0.0, 1.0);
  late bool _playerMuted = widget.state.playerMuted;
  late double _systemValue = widget.state.systemVolume.clamp(0.0, 1.0);
  late bool _systemMuted = widget.state.systemMuted;

  IconData _volumeIcon(double value, bool muted) => muted || value <= 0.001
      ? Icons.volume_off_rounded
      : value < 0.5
      ? Icons.volume_down_rounded
      : Icons.volume_up_rounded;

  Widget _channel(
    BuildContext context, {
    required String mode,
    required String label,
    required IconData channelIcon,
    required double value,
    required bool muted,
    required bool enabled,
  }) {
    final theme = IntMusicTheme.of(context);
    return Expanded(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: enabled ? 1 : 0.48,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(channelIcon, size: 18, color: theme.accent),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '${(value * 100).round()}%',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: theme.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 132,
              child: RotatedBox(
                quarterTurns: 3,
                child: Slider(
                  value: value,
                  onChanged: enabled
                      ? (next) => setState(() {
                          if (mode == 'system') {
                            _systemValue = next;
                            if (next > 0.001) _systemMuted = false;
                          } else {
                            _playerValue = next;
                            if (next > 0.001) _playerMuted = false;
                          }
                        })
                      : null,
                  onChangeEnd: enabled
                      ? (next) => widget.onChanged(mode, next)
                      : null,
                ),
              ),
            ),
            _AppTooltip(
              message: _tr(context, muted ? 'Unmute' : 'Mute'),
              child: IconButton(
                onPressed: enabled
                    ? () {
                        setState(() {
                          if (mode == 'system') {
                            _systemMuted = !_systemMuted;
                          } else {
                            _playerMuted = !_playerMuted;
                          }
                        });
                        widget.onToggleMute(mode);
                      }
                    : null,
                icon: Icon(_volumeIcon(value, muted)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('vertical-volume-panel'),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.targetLabel?.isNotEmpty == true) ...[
            Text(
              widget.targetLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _channel(
                context,
                mode: 'player',
                label: _tr(context, 'Player'),
                channelIcon: Icons.graphic_eq_rounded,
                value: _playerValue,
                muted: _playerMuted,
                enabled: true,
              ),
              Container(
                width: 1,
                height: 206,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: IntMusicTheme.of(context).stroke,
              ),
              _channel(
                context,
                mode: 'system',
                label: _tr(context, 'System'),
                channelIcon: Icons.speaker_outlined,
                value: _systemValue,
                muted: _systemMuted,
                enabled: widget.state.systemVolumeSupported,
              ),
            ],
          ),
          if (!widget.state.systemVolumeSupported) ...[
            const SizedBox(height: 4),
            Text(
              _tr(context, 'System volume is unavailable for this output'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
