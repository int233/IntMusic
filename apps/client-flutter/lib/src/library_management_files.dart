part of '../intmusic_client.dart';

class _LibraryFilesView extends StatelessWidget {
  const _LibraryFilesView({
    super.key,
    required this.files,
    required this.total,
    required this.offset,
    required this.pageSize,
    required this.loading,
    required this.attentionOnly,
    required this.status,
    required this.deviceFilter,
    required this.extensionFilter,
    required this.devices,
    required this.searchController,
    required this.onSearchChanged,
    required this.onStatusChanged,
    required this.onDeviceChanged,
    required this.onExtensionChanged,
    required this.onPageChanged,
    required this.onOpen,
    required this.onResolve,
    required this.onAction,
    required this.selectedFileIds,
    required this.onSelectionChanged,
    required this.onSelectPage,
    required this.onClearSelection,
    required this.onBatchAction,
  });

  final List<dynamic> files;
  final int total;
  final int offset;
  final int pageSize;
  final bool loading;
  final bool attentionOnly;
  final String status;
  final String? deviceFilter;
  final String? extensionFilter;
  final List<dynamic> devices;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<String?> onDeviceChanged;
  final ValueChanged<String?> onExtensionChanged;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function(Map<String, dynamic>) onOpen;
  final Future<void> Function(Map<String, dynamic>) onResolve;
  final Future<void> Function(int, String) onAction;
  final Set<int> selectedFileIds;
  final void Function(int, bool) onSelectionChanged;
  final void Function(Set<int>, bool) onSelectPage;
  final VoidCallback onClearSelection;
  final Future<void> Function(Set<int>, String) onBatchAction;

  @override
  Widget build(BuildContext context) {
    final maps = files
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .toList(growable: false);
    final pageEnd = min(offset + maps.length, total);
    final range = total == 0 ? '0' : '${offset + 1}–$pageEnd / $total';
    final pageFileIds = maps
        .map((file) => _intValue(file['file_id']))
        .whereType<int>()
        .toSet();
    final selectedOnPage = pageFileIds.intersection(selectedFileIds).length;
    final allPageSelected =
        pageFileIds.isNotEmpty && selectedOnPage == pageFileIds.length;
    final somePageSelected = selectedOnPage > 0 && !allPageSelected;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 2, 22, 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final search = TextField(
                controller: searchController,
                onChanged: onSearchChanged,
                decoration: InputDecoration(
                  hintText: _tr(
                    context,
                    'Search filenames, tracks, albums, devices, and sources',
                  ),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            searchController.clear();
                            onSearchChanged('');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              );
              final filters = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!attentionOnly)
                    _LibraryFilterMenu(
                      label: _libraryStatusLabel(context, status),
                      icon: Icons.filter_alt_outlined,
                      entries: const {
                        'all': 'All states',
                        'available': 'Available',
                        'offline': 'Offline',
                        'missing': 'Missing',
                        'unresolved': 'Unresolved',
                        'ignored': 'Ignored',
                        'retired': 'Retired',
                        'removed': 'Removed',
                      },
                      onSelected: onStatusChanged,
                    ),
                  _LibraryNullableFilterMenu(
                    label: deviceFilter == null
                        ? _tr(context, 'All devices')
                        : _libraryDeviceName(devices, deviceFilter!),
                    icon: Icons.devices_outlined,
                    entries: {
                      for (final value in devices.whereType<Map>())
                        if (value['device_id'] != null)
                          value['device_id'].toString():
                              value['display_name']?.toString() ??
                              value['device_id'].toString(),
                    },
                    allLabel: 'All devices',
                    onSelected: onDeviceChanged,
                  ),
                  _LibraryNullableFilterMenu(
                    label: extensionFilter == null
                        ? _tr(context, 'All formats')
                        : extensionFilter!.toUpperCase(),
                    icon: Icons.high_quality_outlined,
                    entries: const {
                      'flac': 'FLAC',
                      'mp3': 'MP3',
                      'm4a': 'M4A',
                      'aac': 'AAC',
                      'wav': 'WAV',
                      'aiff': 'AIFF',
                      'ape': 'APE',
                      'dsf': 'DSF',
                      'ogg': 'OGG',
                      'opus': 'OPUS',
                      'wma': 'WMA',
                    },
                    allLabel: 'All formats',
                    onSelected: onExtensionChanged,
                  ),
                ],
              );
              if (constraints.maxWidth < 820) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [search, const SizedBox(height: 8), filters],
                );
              }
              return Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 10),
                  Flexible(child: filters),
                ],
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            children: [
              Checkbox(
                value: allPageSelected
                    ? true
                    : somePageSelected
                    ? null
                    : false,
                tristate: true,
                onChanged: loading || pageFileIds.isEmpty
                    ? null
                    : (value) =>
                          onSelectPage(pageFileIds, value ?? !somePageSelected),
              ),
              Expanded(
                child: Text(
                  selectedFileIds.isNotEmpty
                      ? '${selectedFileIds.length} ${_tr(context, 'files selected')}${selectedFileIds.length > selectedOnPage ? ' · $selectedOnPage ${_tr(context, 'on this page')}' : ''}'
                      : attentionOnly
                      ? '$total ${_tr(context, 'files need attention')}'
                      : '$total ${_tr(context, 'physical files')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
              ),
              if (loading) ...[
                const SizedBox(width: 12),
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              if (selectedFileIds.isNotEmpty) ...[
                TextButton(
                  onPressed: onClearSelection,
                  child: Text(_tr(context, 'Clear selection')),
                ),
                PopupMenuButton<String>(
                  tooltip: _tr(context, 'Batch actions'),
                  enabled: !loading,
                  onSelected: (action) async {
                    if (!await _confirmLibraryBatchAction(
                      context,
                      action,
                      selectedFileIds.length,
                    )) {
                      return;
                    }
                    await onBatchAction(Set<int>.of(selectedFileIds), action);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'request_rescan',
                      child: _LibraryMenuLabel(
                        icon: Icons.refresh,
                        label: _tr(context, 'Request metadata rescan'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'ignore',
                      child: _LibraryMenuLabel(
                        icon: Icons.visibility_off_outlined,
                        label: _tr(context, 'Ignore selected files'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'reset',
                      child: _LibraryMenuLabel(
                        icon: Icons.settings_backup_restore,
                        label: _tr(context, 'Reset selected files'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'restore',
                      child: _LibraryMenuLabel(
                        icon: Icons.restore_from_trash_outlined,
                        label: _tr(context, 'Restore selected files'),
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'remove',
                      child: _LibraryMenuLabel(
                        icon: Icons.delete_outline,
                        label: _tr(context, 'Remove selected from inventory'),
                      ),
                    ),
                  ],
                  child: _LibraryFilterPill(
                    label: _tr(context, 'Batch actions'),
                    icon: Icons.library_add_check_outlined,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                range,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: IntMusicTheme.of(context).textSecondary,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: _tr(context, 'Previous page'),
                onPressed: loading || offset <= 0
                    ? null
                    : () => onPageChanged(max(0, offset - pageSize)),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: _tr(context, 'Next page'),
                onPressed: loading || pageEnd >= total
                    ? null
                    : () => onPageChanged(offset + pageSize),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        Expanded(
          child: maps.isEmpty && !loading
              ? _LibraryFilesEmpty(attentionOnly: attentionOnly)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
                  itemCount: maps.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _LibraryFileCard(
                    file: maps[index],
                    selected: selectedFileIds.contains(
                      _intValue(maps[index]['file_id']),
                    ),
                    onSelectionChanged: (selected) {
                      final fileId = _intValue(maps[index]['file_id']);
                      if (fileId != null) {
                        onSelectionChanged(fileId, selected);
                      }
                    },
                    onOpen: () => onOpen(maps[index]),
                    onResolve: () => onResolve(maps[index]),
                    onAction: (action) async {
                      final fileId = _intValue(maps[index]['file_id']);
                      if (fileId == null) return;
                      if (!await _confirmLibraryFileAction(context, action)) {
                        return;
                      }
                      await onAction(fileId, action);
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _LibraryFilterMenu extends StatelessWidget {
  const _LibraryFilterMenu({
    required this.label,
    required this.icon,
    required this.entries,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final Map<String, String> entries;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final entry in entries.entries)
          PopupMenuItem(
            value: entry.key,
            child: Text(_tr(context, entry.value)),
          ),
      ],
      child: _LibraryFilterPill(label: label, icon: icon),
    );
  }
}

class _LibraryNullableFilterMenu extends StatelessWidget {
  const _LibraryNullableFilterMenu({
    required this.label,
    required this.icon,
    required this.entries,
    required this.allLabel,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final Map<String, String> entries;
  final String allLabel;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (value) => onSelected(value == '__all__' ? null : value),
      itemBuilder: (context) => [
        PopupMenuItem(value: '__all__', child: Text(_tr(context, allLabel))),
        for (final entry in entries.entries)
          PopupMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      child: _LibraryFilterPill(label: label, icon: icon),
    );
  }
}

class _LibraryFilterPill extends StatelessWidget {
  const _LibraryFilterPill({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: IntMusicTheme.of(context).stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Text(label),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    );
  }
}

class _LibraryFileCard extends StatelessWidget {
  const _LibraryFileCard({
    required this.file,
    required this.selected,
    required this.onSelectionChanged,
    required this.onOpen,
    required this.onResolve,
    required this.onAction,
  });

  final Map<String, dynamic> file;
  final bool selected;
  final ValueChanged<bool> onSelectionChanged;
  final VoidCallback onOpen;
  final VoidCallback onResolve;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final title = file['track_title']?.toString().trim().isNotEmpty == true
        ? file['track_title'].toString()
        : _libraryFilename(file['relative_path']?.toString() ?? '');
    final artist = file['artist_display']?.toString();
    final album = file['album_title']?.toString();
    final subtitle = [
      if (artist != null && artist.isNotEmpty) artist,
      if (album != null && album.isNotEmpty) album,
    ].join(' · ');
    final presence = file['presence_state']?.toString() ?? 'missing';
    final metadata = file['metadata_state']?.toString() ?? 'verified';
    final identity = file['identity_state']?.toString() ?? 'unresolved';
    final issues = (file['issues'] as List?) ?? const [];
    final canResolve =
        identity == 'unresolved' ||
        metadata == 'legacy_unverified' ||
        metadata == 'missing_required' ||
        metadata == 'parse_error';
    final tokens = IntMusicTheme.of(context);
    return Material(
      color: selected
          ? tokens.accent.withValues(alpha: 0.08)
          : tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? tokens.accent
                  : issues.isEmpty
                  ? tokens.stroke
                  : tokens.accent.withValues(alpha: 0.38),
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Checkbox(
                  value: selected,
                  onChanged: (value) => onSelectionChanged(value ?? false),
                ),
                _LibraryFileIcon(
                  extension: file['extension']?.toString() ?? '',
                  state: presence,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        '${file['device_name'] ?? 'Core local'} · '
                        '${file['root_name'] ?? '-'} · '
                        '${file['relative_path'] ?? '-'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _LibraryStateChip(
                            label:
                                file['extension']?.toString().toUpperCase() ??
                                '-',
                            icon: Icons.audio_file_outlined,
                          ),
                          _LibraryStateChip(
                            label: _formatLibraryBytes(file['size_bytes']),
                            icon: Icons.data_usage_outlined,
                          ),
                          _LibraryStateChip(
                            label: _libraryStateLabel(context, presence),
                            icon: _libraryPresenceIcon(presence),
                            tone: _libraryStateTone(context, presence),
                          ),
                          _LibraryStateChip(
                            label: _libraryMetadataLabel(context, metadata),
                            icon: metadata == 'verified'
                                ? Icons.verified_outlined
                                : Icons.info_outline,
                            tone: metadata == 'verified'
                                ? null
                                : Theme.of(context).colorScheme.tertiary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: _tr(context, 'File actions'),
                  onSelected: (value) {
                    if (value == 'details') {
                      onOpen();
                    } else if (value == 'resolve') {
                      onResolve();
                    } else {
                      onAction(value);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'details',
                      child: Text(_tr(context, 'View file details')),
                    ),
                    if (canResolve)
                      PopupMenuItem(
                        value: 'resolve',
                        child: Text(_tr(context, 'Identify or edit metadata')),
                      ),
                    if (file['scan_status']?.toString() == 'ignored')
                      PopupMenuItem(
                        value: 'reset',
                        child: Text(_tr(context, 'Stop ignoring file')),
                      ),
                    PopupMenuItem(
                      value: 'request_rescan',
                      child: Text(_tr(context, 'Request metadata rescan')),
                    ),
                    if (presence == 'removed')
                      PopupMenuItem(
                        value: 'restore',
                        child: Text(_tr(context, 'Restore to inventory')),
                      )
                    else ...[
                      if (file['scan_status']?.toString() != 'ignored')
                        PopupMenuItem(
                          value: 'ignore',
                          child: Text(_tr(context, 'Ignore file')),
                        ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(_tr(context, 'Remove from inventory')),
                      ),
                    ],
                  ],
                  icon: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryFileIcon extends StatelessWidget {
  const _LibraryFileIcon({required this.extension, required this.state});

  final String extension;
  final String state;

  @override
  Widget build(BuildContext context) {
    final tone = _libraryStateTone(context, state);
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.audio_file_outlined, color: tone, size: 27),
          Positioned(
            right: 4,
            bottom: 3,
            child: Text(
              extension.toUpperCase(),
              style: TextStyle(
                color: tone,
                fontSize: 7,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryStateChip extends StatelessWidget {
  const _LibraryStateChip({required this.label, required this.icon, this.tone});

  final String label;
  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final color = tone ?? IntMusicTheme.of(context).textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _LibraryFilesEmpty extends StatelessWidget {
  const _LibraryFilesEmpty({required this.attentionOnly});

  final bool attentionOnly;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              attentionOnly
                  ? Icons.task_alt_outlined
                  : Icons.audio_file_outlined,
              size: 52,
              color: IntMusicTheme.of(context).textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              _tr(
                context,
                attentionOnly
                    ? 'No files currently need attention'
                    : 'No files match these filters',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryFileDetailDialog extends StatelessWidget {
  const _LibraryFileDetailDialog({
    required this.detail,
    required this.onOpenTrack,
  });

  final Map<String, dynamic> detail;
  final ValueChanged<int> onOpenTrack;

  @override
  Widget build(BuildContext context) {
    final file = _asMap(detail['file']);
    final metadata = _asMap(detail['embedded_metadata']);
    final issues = (detail['issues'] as List?) ?? const [];
    final trackId = _intValue(file['track_id']);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 12, 14),
              child: Row(
                children: [
                  _LibraryFileIcon(
                    extension: file['extension']?.toString() ?? '',
                    state: file['presence_state']?.toString() ?? 'missing',
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file['track_title']?.toString() ??
                              _libraryFilename(
                                file['relative_path']?.toString() ?? '',
                              ),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          file['relative_path']?.toString() ?? '-',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: IntMusicTheme.of(context).textSecondary,
                              ),
                        ),
                      ],
                    ),
                  ),
                  if (trackId != null)
                    TextButton.icon(
                      onPressed: () => onOpenTrack(trackId),
                      icon: const Icon(Icons.open_in_new),
                      label: Text(_tr(context, 'Open track')),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  _LibraryDetailSection(
                    title: 'Source and availability',
                    icon: Icons.folder_copy_outlined,
                    children: [
                      _LibraryDetailFact(
                        label: 'Device',
                        value: file['device_name']?.toString() ?? '-',
                      ),
                      _LibraryDetailFact(
                        label: 'Source',
                        value: file['root_name']?.toString() ?? '-',
                      ),
                      _LibraryDetailFact(
                        label: 'Availability',
                        value: _libraryStateLabel(
                          context,
                          file['presence_state']?.toString() ?? 'missing',
                        ),
                      ),
                      _LibraryDetailFact(
                        label: 'Last verified',
                        value: _libraryDate(file['last_verified_at']),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _LibraryDetailSection(
                    title: 'Technical properties',
                    icon: Icons.tune_outlined,
                    children: [
                      _LibraryDetailFact(
                        label: 'Format',
                        value:
                            file['extension']?.toString().toUpperCase() ?? '-',
                      ),
                      _LibraryDetailFact(
                        label: 'Codec',
                        value: file['codec']?.toString().toUpperCase() ?? '-',
                      ),
                      _LibraryDetailFact(
                        label: 'File size',
                        value: _formatLibraryBytes(file['size_bytes']),
                      ),
                      _LibraryDetailFact(
                        label: 'Modified',
                        value: _libraryDate(file['modified_at']),
                      ),
                      _LibraryDetailFact(
                        label: 'Duration',
                        value: _formatDuration(file['duration_ms']).isEmpty
                            ? '-'
                            : _formatDuration(file['duration_ms']),
                      ),
                      _LibraryDetailFact(
                        label: 'Sample rate',
                        value: _librarySampleRate(file['sample_rate']),
                      ),
                      _LibraryDetailFact(
                        label: 'Bit depth',
                        value: file['bit_depth'] == null
                            ? '-'
                            : '${file['bit_depth']} bit',
                      ),
                      _LibraryDetailFact(
                        label: 'Bitrate',
                        value: _libraryBitrate(file['bitrate']),
                      ),
                      _LibraryDetailFact(
                        label: 'Channels',
                        value: file['channels']?.toString() ?? '-',
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _LibraryDetailSection(
                    title: 'Embedded metadata',
                    icon: Icons.sell_outlined,
                    children: [
                      _LibraryDetailFact(
                        label: 'Title',
                        value: metadata['title']?.toString() ?? '-',
                      ),
                      _LibraryDetailFact(
                        label: 'Artists',
                        value: _libraryListText(metadata['track_artists']),
                      ),
                      _LibraryDetailFact(
                        label: 'Album',
                        value: metadata['album']?.toString() ?? '-',
                      ),
                      _LibraryDetailFact(
                        label: 'Album artists',
                        value: _libraryListText(metadata['album_artists']),
                      ),
                      _LibraryDetailFact(
                        label: 'Disc / track',
                        value:
                            '${metadata['disc_number'] ?? '-'} / '
                            '${metadata['track_number'] ?? '-'}',
                      ),
                      _LibraryDetailFact(
                        label: 'Year',
                        value: metadata['year']?.toString() ?? '-',
                      ),
                    ],
                  ),
                  if (issues.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _LibraryDetailSection(
                      title: 'Issue history',
                      icon: Icons.rule_folder_outlined,
                      children: [
                        for (final issueValue in issues.whereType<Map>())
                          _LibraryDetailFact(
                            label: _libraryIssueLabel(
                              context,
                              issueValue['issue_kind']?.toString() ?? '',
                            ),
                            value:
                                issueValue['message']?.toString() ??
                                issueValue['state']?.toString() ??
                                '-',
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryDetailSection extends StatelessWidget {
  const _LibraryDetailSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: IntMusicTheme.of(context).stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 19, color: IntMusicTheme.of(context).accent),
                const SizedBox(width: 8),
                Text(
                  _tr(context, title),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 12, children: children),
          ],
        ),
      ),
    );
  }
}

class _LibraryDetailFact extends StatelessWidget {
  const _LibraryDetailFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr(context, label),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: IntMusicTheme.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

Future<bool> _confirmLibraryFileAction(
  BuildContext context,
  String action,
) async {
  if (action != 'remove' && action != 'ignore') return true;
  final destructive = action == 'remove';
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            _tr(
              context,
              destructive ? 'Remove from inventory?' : 'Ignore this file?',
            ),
          ),
          content: Text(
            _tr(
              context,
              destructive
                  ? 'This removes only the catalog copy record. It does not delete the physical file.'
                  : 'The physical file remains on its device and can be restored later.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_tr(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_tr(context, destructive ? 'Remove' : 'Ignore')),
            ),
          ],
        ),
      ) ??
      false;
}

Future<bool> _confirmLibraryBatchAction(
  BuildContext context,
  String action,
  int count,
) async {
  if (action != 'remove' && action != 'ignore') return true;
  final destructive = action == 'remove';
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            _tr(
              context,
              destructive
                  ? 'Remove selected files from inventory?'
                  : 'Ignore selected files?',
            ),
          ),
          content: Text(
            destructive
                ? '${_tr(context, 'This removes')} $count '
                      '${_tr(context, 'catalog copy records. Physical files are not deleted.')}'
                : '${_tr(context, 'Ignore')} $count '
                      '${_tr(context, 'selected files? They remain on their devices.')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_tr(context, 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_tr(context, destructive ? 'Remove' : 'Ignore')),
            ),
          ],
        ),
      ) ??
      false;
}
