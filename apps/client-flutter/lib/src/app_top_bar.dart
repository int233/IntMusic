part of '../intmusic_client.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).canvas.withValues(alpha: 0.42),
        border: Platform.isMacOS
            ? null
            : Border(
                bottom: BorderSide(color: IntMusicTheme.of(context).stroke),
              ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Row(
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
                const SizedBox(width: 2),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: motionDuration,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: Text(
                      _tr(context, title),
                      key: ValueKey(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                Builder(
                  builder: (buttonContext) => _AppTooltip(
                    message: _tr(context, 'Menu'),
                    child: IconButton(
                      onPressed: () => onOpenMenu(buttonContext),
                      icon: const Icon(Icons.menu),
                    ),
                  ),
                ),
                _AppTooltip(
                  message: _tr(context, 'Search library'),
                  child: IconButton(
                    key: const Key('mobile-search-button'),
                    onPressed: () => _showMobileSearch(context),
                    icon: const Icon(Icons.search),
                  ),
                ),
              ],
            );
          }
          return Row(
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
          );
        },
      ),
    );
  }

  void _showMobileSearch(BuildContext context) {
    final language = _LocaleScope.languageOf(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: IntMusicTheme.of(context).surface,
        builder: (sheetContext) => _LocaleScope(
          language: language,
          child: _MobileSearchSheet(
            controller: searchController,
            recentSearches: recentSearches,
            onChanged: onSearchChanged,
            onSubmitted: (query) {
              Navigator.of(sheetContext).pop();
              onSubmitSearch(query);
            },
            onRecentSelected: (query) {
              Navigator.of(sheetContext).pop();
              onSelectRecentSearch(query);
            },
            onClear: onClearSearch,
          ),
        ),
      ),
    );
  }
}

class _MobileSearchSheet extends StatelessWidget {
  const _MobileSearchSheet({
    required this.controller,
    required this.recentSearches,
    required this.onChanged,
    required this.onSubmitted,
    required this.onRecentSelected,
    required this.onClear,
  });

  final TextEditingController controller;
  final List<String> recentSearches;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<String> onRecentSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        14,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            decoration: InputDecoration(
              hintText: _tr(context, 'Search library'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: onClear,
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          if (recentSearches.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              _tr(context, 'Recent searches'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: min(6, recentSearches.length),
                itemBuilder: (context, index) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.history),
                  title: Text(
                    recentSearches[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => onRecentSelected(recentSearches[index]),
                ),
              ),
            ),
          ],
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
