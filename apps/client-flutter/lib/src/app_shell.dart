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
    required this.volume,
    required this.muted,
    required this.volumeMode,
    required this.systemVolumeSupported,
    required this.onResume,
    required this.onPause,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onVolumeChanged,
    required this.onToggleMute,
    required this.onVolumeModeChanged,
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
  final double volume;
  final bool muted;
  final String volumeMode;
  final bool systemVolumeSupported;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(int) onSeek;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final ValueChanged<String> onVolumeModeChanged;
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

    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: IntMusicGlass(
        blur: 26,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
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
                        volume: volume,
                        muted: muted,
                        mode: volumeMode,
                        systemVolumeSupported: systemVolumeSupported,
                        targetLabel: targetLabel,
                        onChanged: onVolumeChanged,
                        onToggleMute: onToggleMute,
                        onModeChanged: onVolumeModeChanged,
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
                  height: 112,
                  child: Column(
                    children: [
                      topRow,
                      const SizedBox(height: 4),
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

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.volume,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
    this.mode = 'player',
    this.systemVolumeSupported = false,
    this.targetLabel,
    this.onModeChanged,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;
  final String mode;
  final bool systemVolumeSupported;
  final String? targetLabel;
  final ValueChanged<String>? onModeChanged;

  @override
  Widget build(BuildContext context) {
    final value = volume.clamp(0.0, 1.0);
    final icon = muted || value <= 0.001
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
              width: 248,
              maxHeight: 360,
              child: _VerticalVolumePanel(
                volume: value,
                muted: muted,
                mode: mode,
                systemVolumeSupported: systemVolumeSupported,
                targetLabel: targetLabel,
                onChanged: onChanged,
                onToggleMute: onToggleMute,
                onModeChanged: onModeChanged,
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
    required this.volume,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
    required this.mode,
    required this.systemVolumeSupported,
    this.targetLabel,
    this.onModeChanged,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;
  final String mode;
  final bool systemVolumeSupported;
  final String? targetLabel;
  final ValueChanged<String>? onModeChanged;

  @override
  State<_VerticalVolumePanel> createState() => _VerticalVolumePanelState();
}

class _VerticalVolumePanelState extends State<_VerticalVolumePanel> {
  late double _value = widget.volume.clamp(0.0, 1.0);
  late bool _muted = widget.muted;

  IconData get _icon => _muted || _value <= 0.001
      ? Icons.volume_off_rounded
      : _value < 0.5
      ? Icons.volume_down_rounded
      : Icons.volume_up_rounded;

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
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'player',
                  icon: const Icon(Icons.graphic_eq_rounded, size: 17),
                  label: Text(_tr(context, 'Player')),
                ),
                ButtonSegment<String>(
                  value: 'system',
                  enabled: widget.systemVolumeSupported,
                  icon: const Icon(Icons.computer_rounded, size: 17),
                  label: Text(_tr(context, 'System')),
                ),
              ],
              selected: <String>{widget.mode == 'system' ? 'system' : 'player'},
              onSelectionChanged: widget.onModeChanged == null
                  ? null
                  : (selection) {
                      final mode = selection.first;
                      if (mode == widget.mode) return;
                      widget.onModeChanged!(mode);
                      Navigator.of(context).maybePop();
                    },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${(_value * 100).round()}%',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            _tr(context, widget.mode == 'system' ? 'System' : 'Player'),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: IntMusicTheme.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 125,
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: _value,
                onChanged: (next) => setState(() {
                  _value = next;
                  if (next > 0.001) {
                    _muted = false;
                  }
                }),
                onChangeEnd: widget.onChanged,
              ),
            ),
          ),
          const SizedBox(height: 2),
          _AppTooltip(
            message: _tr(context, _muted ? 'Unmute' : 'Mute'),
            child: IconButton(
              onPressed: () {
                setState(() => _muted = !_muted);
                widget.onToggleMute();
              },
              icon: Icon(_icon),
            ),
          ),
        ],
      ),
    );
  }
}
