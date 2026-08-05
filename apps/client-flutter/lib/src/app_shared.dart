part of '../intmusic_client.dart';

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
              : ValueListenableBuilder<int>(
                  valueListenable: artworkCacheCoordinator.retryRevision,
                  builder: (context, retryRevision, child) {
                    final url = imageUrl!;
                    return CachedNetworkImage(
                      key: ValueKey(
                        '${artworkCacheCoordinator.cacheKey(url)}:'
                        '$retryRevision',
                      ),
                      cacheManager: _artworkCacheManager,
                      cacheKey: artworkCacheCoordinator.cacheKey(url),
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: imageCacheExtent,
                      filterQuality: FilterQuality.low,
                      fadeInDuration: const Duration(milliseconds: 80),
                      fadeOutDuration: Duration.zero,
                      useOldImageOnUrlChange: true,
                      placeholder: (context, url) => fallback,
                      errorWidget: (context, url, error) => fallback,
                    );
                  },
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
                        color: IntMusicTheme.of(context).textSecondary,
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

class _CollectionActions extends StatelessWidget {
  const _CollectionActions({required this.tracks, this.onClose});

  final List<dynamic> tracks;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final actions = _TrackActionScope.maybeOf(context);
    final trackIds = tracks
        .map((track) => _intValue((track as Map)['id']))
        .whereType<int>()
        .toList(growable: false);
    final enabled = actions != null && trackIds.isNotEmpty;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: enabled
              ? () => unawaited(actions.onPlayCollection(trackIds, false))
              : null,
          icon: const Icon(Icons.play_arrow),
          label: Text(_tr(context, 'Play')),
        ),
        FilledButton.tonalIcon(
          onPressed: enabled
              ? () => unawaited(actions.onPlayCollection(trackIds, true))
              : null,
          icon: const Icon(Icons.shuffle),
          label: Text(_tr(context, 'Shuffle')),
        ),
        PopupMenuButton<_CollectionMoreAction>(
          enabled: enabled,
          tooltip: _tr(context, 'More'),
          icon: const Icon(Icons.more_horiz),
          onSelected: (action) {
            switch (action) {
              case _CollectionMoreAction.playNext:
                unawaited(actions!.onQueueCollection(trackIds, true));
              case _CollectionMoreAction.addToQueue:
                unawaited(actions!.onQueueCollection(trackIds, false));
              case _CollectionMoreAction.distribute:
                unawaited(actions!.onDistributeCollection(trackIds));
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: _CollectionMoreAction.playNext,
              child: ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(_tr(context, 'Play next')),
              ),
            ),
            PopupMenuItem(
              value: _CollectionMoreAction.addToQueue,
              child: ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(_tr(context, 'Add to queue')),
              ),
            ),
            PopupMenuItem(
              value: _CollectionMoreAction.distribute,
              child: ListTile(
                leading: const Icon(Icons.send_to_mobile_outlined),
                title: Text(_tr(context, 'Distribute to device')),
              ),
            ),
          ],
        ),
        if (onClose != null)
          _AppTooltip(
            message: _tr(context, 'Close'),
            child: IconButton.filledTonal(
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ),
      ],
    );
  }
}

enum _CollectionMoreAction { playNext, addToQueue, distribute }

class _ResponsiveDetailHeading extends StatelessWidget {
  const _ResponsiveDetailHeading({required this.header, required this.actions});

  final Widget header;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [header, const SizedBox(height: 12), actions],
          );
        }
        return Row(
          children: [
            Expanded(child: header),
            const SizedBox(width: 12),
            actions,
          ],
        );
      },
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

class _LibraryToolbar extends StatefulWidget {
  const _LibraryToolbar({
    required this.countLabel,
    required this.searchHint,
    required this.onQueryChanged,
    required this.sortValue,
    required this.sortOptions,
    required this.onSortChanged,
    required this.viewMode,
    required this.onViewModeChanged,
    this.action,
  });

  final String countLabel;
  final String searchHint;
  final ValueChanged<String> onQueryChanged;
  final String sortValue;
  final Map<String, String> sortOptions;
  final ValueChanged<String> onSortChanged;
  final _LibraryViewMode viewMode;
  final ValueChanged<_LibraryViewMode> onViewModeChanged;
  final Widget? action;

  @override
  State<_LibraryToolbar> createState() => _LibraryToolbarState();
}

class _LibraryToolbarState extends State<_LibraryToolbar> {
  final _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final search = TextField(
      controller: _queryController,
      onChanged: widget.onQueryChanged,
      decoration: InputDecoration(
        hintText: widget.searchHint,
        prefixIcon: const Icon(Icons.search, size: 19),
        suffixIcon: _queryController.text.isEmpty
            ? null
            : IconButton(
                tooltip: _tr(context, 'Clear'),
                onPressed: () {
                  _queryController.clear();
                  widget.onQueryChanged('');
                  setState(() {});
                },
                icon: const Icon(Icons.close, size: 18),
              ),
        isDense: true,
      ),
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.action != null) ...[
          widget.action!,
          const SizedBox(width: 8),
        ],
        PopupMenuButton<String>(
          initialValue: widget.sortValue,
          tooltip: _tr(context, 'Sort'),
          onSelected: widget.onSortChanged,
          itemBuilder: (context) => widget.sortOptions.entries
              .map(
                (entry) => PopupMenuItem<String>(
                  value: entry.key,
                  child: Row(
                    children: [
                      if (entry.key == widget.sortValue) ...[
                        const Icon(Icons.check, size: 18),
                        const SizedBox(width: 8),
                      ] else
                        const SizedBox(width: 26),
                      Text(entry.value),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surface,
              border: Border.all(color: tokens.stroke),
              borderRadius: BorderRadius.circular(tokens.radiusSmall),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.swap_vert, size: 18),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 118),
                    child: Text(
                      widget.sortOptions[widget.sortValue] ??
                          _tr(context, 'Sort'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _ViewModeToggle(
          value: widget.viewMode,
          onChanged: widget.onViewModeChanged,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        if (compact) {
          final veryCompact = constraints.maxWidth < 520;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (veryCompact) ...[
                Text(
                  widget.countLabel,
                  key: const Key('library-count-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: 7),
                Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: controls,
                  ),
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.countLabel,
                        key: const Key('library-count-label'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ),
                    controls,
                  ],
                ),
              const SizedBox(height: 8),
              search,
            ],
          );
        }
        return Row(
          children: [
            Text(
              widget.countLabel,
              key: const Key('library-count-label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
            const Spacer(),
            SizedBox(width: 260, child: search),
            const SizedBox(width: 8),
            controls,
          ],
        );
      },
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.value, required this.onChanged});

  final _LibraryViewMode value;
  final ValueChanged<_LibraryViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_LibraryViewMode>(
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: _LibraryViewMode.grid,
          icon: const Icon(Icons.grid_view_rounded),
          tooltip: _tr(context, 'Grid view'),
        ),
        ButtonSegment(
          value: _LibraryViewMode.list,
          icon: const Icon(Icons.view_list_rounded),
          tooltip: _tr(context, 'List view'),
        ),
      ],
      selected: <_LibraryViewMode>{value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
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
