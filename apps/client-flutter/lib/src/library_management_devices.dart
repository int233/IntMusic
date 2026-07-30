part of '../intmusic_client.dart';

class _LibraryDevicesView extends StatelessWidget {
  const _LibraryDevicesView({
    super.key,
    required this.devices,
    required this.loading,
    required this.onDeviceAction,
    required this.onSourceAction,
    required this.onShowFiles,
  });

  final List<dynamic> devices;
  final bool loading;
  final Future<void> Function(String, String) onDeviceAction;
  final Future<void> Function(int, String) onSourceAction;
  final ValueChanged<String> onShowFiles;

  @override
  Widget build(BuildContext context) {
    if (loading && devices.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.devices_other_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                _tr(context, 'No library devices'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                _tr(
                  context,
                  'A device appears here after it registers a local music source.',
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1120 ? 2 : 1;
        final width = columns == 2
            ? (constraints.maxWidth - 56) / 2
            : constraints.maxWidth - 44;
        return ListView(
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 28),
          children: [
            Text(
              _tr(
                context,
                'Devices stay in the inventory after they go offline or the client is uninstalled. Retire a device only when its sources should no longer be active.',
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final value in devices)
                  SizedBox(
                    width: width,
                    child: _LibraryDeviceCard(
                      device: _asMap(value),
                      onDeviceAction: onDeviceAction,
                      onSourceAction: onSourceAction,
                      onShowFiles: onShowFiles,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LibraryDeviceCard extends StatelessWidget {
  const _LibraryDeviceCard({
    required this.device,
    required this.onDeviceAction,
    required this.onSourceAction,
    required this.onShowFiles,
  });

  final Map<String, dynamic> device;
  final Future<void> Function(String, String) onDeviceAction;
  final Future<void> Function(int, String) onSourceAction;
  final ValueChanged<String> onShowFiles;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final deviceId = device['device_id']?.toString() ?? '';
    final state = device['state']?.toString() ?? 'offline';
    final isCore = deviceId == 'core';
    final isRetired = state == 'retired';
    final sources = (device['sources'] as List?) ?? const [];
    var files = 0;
    var available = 0;
    var attention = 0;
    var bytes = 0;
    for (final value in sources) {
      final source = _asMap(value);
      files += _intValue(source['file_count']) ?? 0;
      available += _intValue(source['available_file_count']) ?? 0;
      attention += _intValue(source['attention_file_count']) ?? 0;
      bytes += _intValue(source['total_bytes']) ?? 0;
    }
    final stateColor = _libraryPresenceColor(context, state);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    isCore ? Icons.dns_outlined : Icons.devices_outlined,
                    color: stateColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['display_name']?.toString() ??
                            _tr(context, 'Unknown device'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (isCore)
                            _tr(context, 'Core library')
                          else
                            _libraryPlatformLabel(
                              context,
                              device['platform']?.toString(),
                            ),
                          _libraryStateLabel(context, state),
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                _LibraryDeviceStateChip(state: state),
                PopupMenuButton<String>(
                  tooltip: _tr(context, 'More'),
                  onSelected: (action) async {
                    if (action == 'show_files') {
                      onShowFiles(deviceId);
                      return;
                    }
                    if (await _confirmLibraryLifecycleAction(
                      context,
                      target: device['display_name']?.toString() ?? deviceId,
                      action: action,
                      targetKind: 'device',
                    )) {
                      await onDeviceAction(deviceId, action);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'show_files',
                      child: _LibraryMenuLabel(
                        icon: Icons.audio_file_outlined,
                        label: _tr(context, 'Show files'),
                      ),
                    ),
                    if (!isCore)
                      PopupMenuItem(
                        value: isRetired ? 'restore' : 'retire',
                        child: _LibraryMenuLabel(
                          icon: isRetired
                              ? Icons.settings_backup_restore
                              : Icons.archive_outlined,
                          label: _tr(
                            context,
                            isRetired ? 'Restore device' : 'Retire device',
                          ),
                        ),
                      ),
                    if (!isCore) ...[
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'remove',
                        child: _LibraryMenuLabel(
                          icon: Icons.delete_outline,
                          label: _tr(context, 'Remove device and inventory'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _LibrarySummaryPill(
                  icon: Icons.audio_file_outlined,
                  label: '$files ${_tr(context, 'files')}',
                ),
                _LibrarySummaryPill(
                  icon: Icons.cloud_done_outlined,
                  label: '$available ${_tr(context, 'available')}',
                ),
                if (attention > 0)
                  _LibrarySummaryPill(
                    icon: Icons.warning_amber_rounded,
                    label: '$attention ${_tr(context, 'issues')}',
                    color: Theme.of(context).colorScheme.error,
                  ),
                _LibrarySummaryPill(
                  icon: Icons.storage_outlined,
                  label: _formatLibraryBytes(bytes),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Divider(color: tokens.stroke, height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  _tr(context, 'Music sources'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${sources.length}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (sources.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  _tr(
                    context,
                    'No sources are registered for this device. Its identity is retained for management history.',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: tokens.textSecondary),
                ),
              )
            else
              for (final value in sources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _LibrarySourceTile(
                    source: _asMap(value),
                    onAction: onSourceAction,
                  ),
                ),
            const SizedBox(height: 2),
            Text(
              _libraryLastSeenLabel(context, device['last_seen_at']),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibrarySourceTile extends StatelessWidget {
  const _LibrarySourceTile({required this.source, required this.onAction});

  final Map<String, dynamic> source;
  final Future<void> Function(int, String) onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final rootId = _intValue(source['root_id']);
    final state = source['state']?.toString() ?? 'offline';
    final retired = state == 'retired';
    final isCore = source['root_kind'] == 'core';
    final hint = source['path_hint']?.toString();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: tokens.stroke.withValues(alpha: 0.78)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(
          children: [
            Icon(
              source['root_kind'] == 'core'
                  ? Icons.folder_special_outlined
                  : Icons.folder_shared_outlined,
              color: _libraryPresenceColor(context, state),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source['display_name']?.toString() ??
                        _tr(context, 'Music source'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (hint != null && hint.isNotEmpty)
                    Text(
                      hint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${source['file_count'] ?? 0} ${_tr(context, 'files')}',
                      ),
                      Text(_formatLibraryBytes(source['total_bytes'])),
                      if ((_intValue(source['attention_file_count']) ?? 0) > 0)
                        Text(
                          '${source['attention_file_count']} '
                          '${_tr(context, 'issues')}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            _LibraryDeviceStateChip(state: state, compact: true),
            PopupMenuButton<String>(
              tooltip: _tr(context, 'More'),
              enabled: rootId != null,
              onSelected: (action) async {
                if (rootId == null) return;
                if (await _confirmLibraryLifecycleAction(
                  context,
                  target: source['display_name']?.toString() ?? '$rootId',
                  action: action,
                  targetKind: 'source',
                )) {
                  await onAction(rootId, action);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: retired ? 'restore' : 'retire',
                  child: _LibraryMenuLabel(
                    icon: retired
                        ? Icons.settings_backup_restore
                        : Icons.archive_outlined,
                    label: _tr(
                      context,
                      retired ? 'Restore source' : 'Retire source',
                    ),
                  ),
                ),
                if (!isCore) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'remove',
                    child: _LibraryMenuLabel(
                      icon: Icons.delete_outline,
                      label: _tr(context, 'Remove source and inventory'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryDeviceStateChip extends StatelessWidget {
  const _LibraryDeviceStateChip({required this.state, this.compact = false});

  final String state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = _libraryPresenceColor(context, state);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _libraryStateLabel(context, state),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LibrarySummaryPill extends StatelessWidget {
  const _LibrarySummaryPill({
    required this.icon,
    required this.label,
    this.color,
  });

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? IntMusicTheme.of(context).textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryMenuLabel extends StatelessWidget {
  const _LibraryMenuLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 19), const SizedBox(width: 10), Text(label)],
    );
  }
}

Future<bool> _confirmLibraryLifecycleAction(
  BuildContext context, {
  required String target,
  required String action,
  required String targetKind,
}) async {
  final restore = action == 'restore';
  final remove = action == 'remove';
  final device = targetKind == 'device';
  final subject = device ? 'device' : 'source';
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            _tr(
              context,
              restore
                  ? 'Restore $subject'
                  : remove
                  ? 'Remove $subject'
                  : 'Retire $subject',
            ),
          ),
          content: Text(
            restore
                ? '${_tr(context, 'Restore')} “$target”?'
                : remove
                ? _tr(
                    context,
                    device
                        ? 'This removes the device, its sources, and all related copy records from active management. Physical music files on that device are not deleted. If the same Client reconnects later, it can register the files again.'
                        : 'This removes the source and all of its copy records from active management. Physical music files are not deleted. Adding the same folder again will register it as a source.',
                  )
                : _tr(
                    context,
                    'The files remain in management history, but this source will no longer be considered active.',
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_tr(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                _tr(
                  context,
                  restore
                      ? 'Restore'
                      : remove
                      ? 'Remove'
                      : 'Retire',
                ),
              ),
            ),
          ],
        ),
      ) ??
      false;
}

String _libraryPlatformLabel(BuildContext context, String? platform) {
  return switch (platform?.toLowerCase()) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'android' => 'Android',
    'linux' => 'Linux',
    _ => _tr(context, 'Client device'),
  };
}

Color _libraryPresenceColor(BuildContext context, String state) {
  final tokens = IntMusicTheme.of(context);
  return switch (state) {
    'online' || 'available' => const Color(0xff2ea978),
    'missing' => const Color(0xffd18b28),
    'removed' || 'retired' => tokens.textSecondary,
    _ => const Color(0xff6f7d91),
  };
}

String _libraryLastSeenLabel(BuildContext context, Object? value) {
  if (value == null) return _tr(context, 'No recent connection');
  final parsed = DateTime.tryParse(value.toString())?.toLocal();
  if (parsed == null) return _tr(context, 'No recent connection');
  final date =
      '${parsed.year.toString().padLeft(4, '0')}-'
      '${parsed.month.toString().padLeft(2, '0')}-'
      '${parsed.day.toString().padLeft(2, '0')} '
      '${parsed.hour.toString().padLeft(2, '0')}:'
      '${parsed.minute.toString().padLeft(2, '0')}';
  return '${_tr(context, 'Last seen')} $date';
}
