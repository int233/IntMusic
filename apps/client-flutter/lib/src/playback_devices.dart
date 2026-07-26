part of '../intmusic_client.dart';

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
