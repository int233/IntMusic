part of '../intmusic_client.dart';

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
