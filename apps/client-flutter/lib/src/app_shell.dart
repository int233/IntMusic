part of '../main.dart';

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
  final double volume;
  final bool muted;
  final VoidCallback onResume;
  final VoidCallback onPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final Future<void> Function(int) onSeek;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
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
    final canNavigate = hasTrack && trackDetail != null;

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
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

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
              width: 112,
              maxHeight: 280,
              child: _VerticalVolumePanel(
                volume: value,
                muted: muted,
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
    required this.volume,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

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
          Text(
            '${(_value * 100).round()}%',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 170,
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

class _AppTopBar extends StatelessWidget {
  const _AppTopBar({
    required this.title,
    required this.desktop,
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    required this.searchController,
    required this.searchSuggestions,
    required this.onOpenMenu,
    required this.onSearchChanged,
    required this.onSubmitSearch,
    required this.onSelectSuggestion,
    required this.recentSearches,
    required this.onSelectRecentSearch,
    required this.onClearSearch,
  });

  final String title;
  final bool desktop;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final TextEditingController searchController;
  final List<_SearchSuggestion> searchSuggestions;
  final void Function(BuildContext) onOpenMenu;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSubmitSearch;
  final ValueChanged<_SearchSuggestion> onSelectSuggestion;
  final List<String> recentSearches;
  final ValueChanged<String> onSelectRecentSearch;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    final motionDuration =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false
        ? Duration.zero
        : const Duration(milliseconds: 240);
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).canvas.withValues(alpha: 0.42),
        border: Platform.isMacOS
            ? null
            : Border(
                bottom: BorderSide(color: IntMusicTheme.of(context).stroke),
              ),
      ),
      child: Row(
        children: [
          _AppTooltip(
            message: _tr(context, 'Back'),
            child: IconButton(
              key: const Key('navigation-back'),
              onPressed: canGoBack ? onBack : null,
              icon: const Icon(Icons.chevron_left),
            ),
          ),
          _AppTooltip(
            message: _tr(context, 'Forward'),
            child: IconButton(
              key: const Key('navigation-forward'),
              onPressed: canGoForward ? onForward : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ),
          const SizedBox(width: 6),
          AnimatedContainer(
            duration: motionDuration,
            curve: Curves.easeInOutCubic,
            constraints: BoxConstraints(
              minWidth: desktop ? 140 : 72,
              maxWidth: desktop ? 240 : 116,
            ),
            child: AnimatedSwitcher(
              duration: motionDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: Text(
                _tr(context, title),
                key: ValueKey(title),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: motionDuration,
            sizeCurve: Curves.easeInOutCubic,
            alignment: Alignment.centerLeft,
            crossFadeState: desktop
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: const SizedBox.shrink(),
            secondChild: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 8),
                Builder(
                  builder: (buttonContext) => _AppTooltip(
                    message: _tr(context, 'Menu'),
                    child: IconButton(
                      onPressed: () => onOpenMenu(buttonContext),
                      icon: const Icon(Icons.menu),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: _SearchBox(
                controller: searchController,
                suggestions: searchSuggestions,
                recentSearches: recentSearches,
                onChanged: onSearchChanged,
                onSubmitted: onSubmitSearch,
                onSelected: onSelectSuggestion,
                onRecentSelected: onSelectRecentSearch,
                onClear: onClearSearch,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBox extends StatefulWidget {
  const _SearchBox({
    required this.controller,
    required this.suggestions,
    required this.recentSearches,
    required this.onChanged,
    required this.onSubmitted,
    required this.onSelected,
    required this.onRecentSelected,
    required this.onClear,
  });

  final TextEditingController controller;
  final List<_SearchSuggestion> suggestions;
  final List<String> recentSearches;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<_SearchSuggestion> onSelected;
  final ValueChanged<String> onRecentSelected;
  final VoidCallback onClear;

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  final _layerLink = LayerLink();
  final _focusNode = FocusNode();
  OverlayEntry? _overlay;
  bool _overlaySyncScheduled = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_scheduleOverlaySync);
  }

  @override
  void didUpdateWidget(covariant _SearchBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.suggestions != widget.suggestions ||
        oldWidget.recentSearches != widget.recentSearches) {
      _scheduleOverlaySync();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_scheduleOverlaySync);
    _hideOverlay();
    _focusNode.dispose();
    super.dispose();
  }

  void _scheduleOverlaySync() {
    if (_overlaySyncScheduled) {
      return;
    }
    _overlaySyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlaySyncScheduled = false;
      if (mounted) {
        _syncOverlay();
      }
    });
  }

  void _syncOverlay() {
    final hasQuery = widget.controller.text.trim().isNotEmpty;
    final shouldShow =
        _focusNode.hasFocus &&
        (hasQuery
            ? widget.suggestions.isNotEmpty
            : widget.recentSearches.isNotEmpty);
    if (!shouldShow) {
      _hideOverlay();
      return;
    }
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: _buildOverlay);
      Overlay.of(context).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _buildOverlay(BuildContext context) {
    final box = this.context.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 360;
    final language = _LocaleScope.languageOf(this.context);
    final hasQuery = widget.controller.text.trim().isNotEmpty;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, 8),
          child: Align(
            alignment: Alignment.topLeft,
            child: _LocaleScope(
              language: language,
              child: Builder(
                builder: (context) => Material(
                  color: IntMusicTheme.of(context).surface,
                  elevation: 18,
                  shadowColor: Colors.black.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: width,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        shrinkWrap: true,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                            child: Text(
                              _tr(
                                context,
                                hasQuery ? 'Suggestions' : 'Recent searches',
                              ),
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                          if (hasQuery)
                            for (final suggestion in widget.suggestions.take(8))
                              _SimpleListRow(
                                leading: Icon(suggestion.icon),
                                title: suggestion.title,
                                subtitle: suggestion.subtitle,
                                height: 54,
                                onTap: () {
                                  _hideOverlay();
                                  widget.onSelected(suggestion);
                                },
                              )
                          else
                            for (final query in widget.recentSearches)
                              _SimpleListRow(
                                leading: const Icon(Icons.history),
                                title: query,
                                subtitle: '',
                                height: 48,
                                onTap: () {
                                  _hideOverlay();
                                  widget.onRecentSelected(query);
                                },
                              ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        focusNode: _focusNode,
        controller: widget.controller,
        textInputAction: TextInputAction.search,
        onChanged: (value) {
          widget.onChanged(value);
          _scheduleOverlaySync();
        },
        onSubmitted: (value) {
          _hideOverlay();
          widget.onSubmitted(value);
        },
        decoration: InputDecoration(
          isDense: true,
          hintText: _tr(context, 'Search library'),
          prefixIcon: const Icon(Icons.search),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (context, value, child) {
              if (value.text.isEmpty) {
                return IconButton(
                  onPressed: () => widget.onSubmitted(value.text),
                  icon: const Icon(Icons.arrow_forward),
                );
              }
              return IconButton(
                onPressed: () {
                  _hideOverlay();
                  widget.onClear();
                },
                icon: const Icon(Icons.close),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavigationSheet extends StatelessWidget {
  const _NavigationSheet({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _tr(context, 'Menu'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < _destinations.length; index++)
              _SimpleListRow(
                leading: Icon(
                  selectedIndex == index
                      ? _destinations[index].selectedIcon
                      : _destinations[index].icon,
                ),
                title: _tr(context, _destinations[index].label),
                subtitle: '',
                trailing: selectedIndex == index
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () => onSelected(index),
              ),
          ],
        ),
      ),
    );
  }
}

class _AppSidebar extends StatelessWidget {
  const _AppSidebar({
    required this.selectedIndex,
    required this.status,
    required this.zones,
    required this.loading,
    required this.error,
    required this.playback,
    required this.titlebarSafeInset,
    required this.onSelected,
  });

  final int selectedIndex;
  final Map<String, dynamic>? status;
  final List<dynamic> zones;
  final bool loading;
  final String? error;
  final Map<String, dynamic>? playback;
  final double titlebarSafeInset;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final counts =
        (status?['counts'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final onlineZones = zones.where((item) {
      final zone = (item as Map).cast<String, dynamic>();
      return zone['is_online'] != false;
    }).length;
    final dotColor = _connectionDotColor(
      loading: loading,
      error: error,
      playback: playback,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 10 + titlebarSafeInset, 4, 10),
      child: IntMusicGlass(
        key: const Key('app-sidebar-glass'),
        blur: 32,
        tint: Platform.isMacOS
            ? IntMusicTheme.of(context).surfaceGlass.withValues(alpha: 0.58)
            : null,
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          width: _sidebarWidth - 14,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: appPrimary.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: appPrimary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Icon(Icons.graphic_eq, color: appPrimary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'IntMusic',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Container(
                                width: 9,
                                height: 9,
                                decoration: BoxDecoration(
                                  color: dotColor,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: dotColor.withValues(alpha: 0.35),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${counts['tracks'] ?? 0} ${_tr(context, 'Tracks').toLowerCase()}',
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
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                  itemCount: _destinations.length,
                  itemBuilder: (context, index) {
                    final destination = _destinations[index];
                    final selected = selectedIndex == index;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: _SidebarItem(
                        label: _tr(context, destination.label),
                        icon: selected
                            ? destination.selectedIcon
                            : destination.icon,
                        selected: selected,
                        onTap: () => onSelected(index),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: IntMusicTheme.of(context).surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: IntMusicTheme.of(context).stroke),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Library'),
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 10),
                        _MiniStat(
                          label: _tr(context, 'Albums'),
                          value: '${counts['albums'] ?? 0}',
                        ),
                        _MiniStat(
                          label: _tr(context, 'Artists'),
                          value: '${counts['artists'] ?? 0}',
                        ),
                        _MiniStat(
                          label: _tr(context, 'Online'),
                          value: '$onlineZones outputs',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Material(
      color: selected
          ? tokens.accent.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 42,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: selected ? tokens.accent : tokens.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? tokens.accent : tokens.textSecondary,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            ),
          ),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
