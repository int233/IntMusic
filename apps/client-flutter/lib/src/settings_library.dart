part of '../intmusic_client.dart';

class _ClientLibraryRootsPanel extends StatelessWidget {
  const _ClientLibraryRootsPanel({
    required this.roots,
    required this.statuses,
    required this.syncingRootIds,
    required this.clientId,
    required this.onAddFolder,
    required this.onSyncFolder,
    required this.onSyncAll,
    required this.onRemoveFolder,
  });

  final List<_ClientLibraryRoot> roots;
  final List<dynamic> statuses;
  final Set<String> syncingRootIds;
  final String clientId;
  final VoidCallback onAddFolder;
  final ValueChanged<String> onSyncFolder;
  final VoidCallback onSyncAll;
  final ValueChanged<String> onRemoveFolder;

  @override
  Widget build(BuildContext context) {
    final remoteByExternalId = <String, Map<String, dynamic>>{
      for (final value in statuses.whereType<Map>())
        if (value['external_id'] != null &&
            value['device_id']?.toString() == clientId)
          value['external_id'].toString(): value.cast<String, dynamic>(),
    };
    final isSyncing = syncingRootIds.isNotEmpty;
    return _HomePanel(
      title: _tr(context, 'This device music'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr(
              context,
              'Files stay on this device. Core receives metadata and records this device as the playable copy.',
            ),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: IntMusicTheme.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: isSyncing ? null : onAddFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(_tr(context, 'Add local folder')),
              ),
              OutlinedButton.icon(
                onPressed: isSyncing || roots.isEmpty ? null : onSyncAll,
                icon: isSyncing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(_tr(context, 'Sync all')),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (roots.isEmpty)
            Text(
              _tr(context, 'No folders from this device'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            )
          else
            for (final root in roots)
              _ClientLibraryRootRow(
                root: root,
                remoteStatus: remoteByExternalId[root.externalId],
                syncing: syncingRootIds.contains(root.externalId),
                onSync: onSyncFolder,
                onRemove: onRemoveFolder,
              ),
        ],
      ),
    );
  }
}

class _ClientLibraryRootRow extends StatelessWidget {
  const _ClientLibraryRootRow({
    required this.root,
    required this.remoteStatus,
    required this.syncing,
    required this.onSync,
    required this.onRemove,
  });

  final _ClientLibraryRoot root;
  final Map<String, dynamic>? remoteStatus;
  final bool syncing;
  final ValueChanged<String> onSync;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final readyCount =
        _intValue(remoteStatus?['ready_file_count']) ?? root.fileCount;
    final lastSynced = root.lastSyncedAt?.toLocal();
    final statusText = root.lastError != null
        ? _tr(context, 'Folder unavailable')
        : lastSynced == null
        ? _tr(context, 'Not synced yet')
        : '$readyCount ${_tr(context, 'tracks')} · '
              '${lastSynced.year.toString().padLeft(4, '0')}-'
              '${lastSynced.month.toString().padLeft(2, '0')}-'
              '${lastSynced.day.toString().padLeft(2, '0')} '
              '${lastSynced.hour.toString().padLeft(2, '0')}:'
              '${lastSynced.minute.toString().padLeft(2, '0')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        border: Border.all(
          color: root.lastError == null
              ? IntMusicTheme.of(context).stroke
              : Theme.of(context).colorScheme.error.withValues(alpha: 0.55),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            root.lastError == null
                ? Icons.folder_copy_outlined
                : Icons.folder_off_outlined,
            color: root.lastError == null
                ? IntMusicTheme.of(context).accent
                : Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  root.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  root.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  statusText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: root.lastError == null
                        ? IntMusicTheme.of(context).textSecondary
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          if (syncing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: _tr(context, 'Sync now'),
              onPressed: () => onSync(root.externalId),
              icon: const Icon(Icons.sync),
            ),
          IconButton(
            tooltip: _tr(context, 'Remove'),
            onPressed: syncing ? null : () => onRemove(root.externalId),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _LibraryRootsPanel extends StatelessWidget {
  const _LibraryRootsPanel({
    required this.roots,
    required this.controller,
    required this.loading,
    required this.onAddFolder,
    required this.onRemoveFolder,
    required this.onScan,
  });

  final List<dynamic> roots;
  final TextEditingController controller;
  final bool loading;
  final VoidCallback onAddFolder;
  final ValueChanged<int> onRemoveFolder;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return _HomePanel(
      title: _tr(context, 'Music folders'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 700;
              final input = TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: _tr(context, 'Core-side folder path'),
                  helperText: _tr(
                    context,
                    'Use a path that the Core server can access',
                  ),
                  prefixIcon: const Icon(Icons.folder_outlined),
                ),
                onSubmitted: (_) => onAddFolder(),
              );
              final buttons = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: loading ? null : onAddFolder,
                    icon: const Icon(Icons.add),
                    label: Text(_tr(context, 'Add folder')),
                  ),
                  OutlinedButton.icon(
                    onPressed: loading ? null : onScan,
                    icon: const Icon(Icons.radar_outlined),
                    label: Text(_tr(context, 'Rescan library')),
                  ),
                ],
              );
              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [input, const SizedBox(height: 10), buttons],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: input),
                  const SizedBox(width: 10),
                  Flexible(child: buttons),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          if (roots.isEmpty)
            Text(
              _tr(context, 'No music folders configured'),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
              ),
            )
          else
            Column(
              children: [
                for (final root in roots)
                  _LibraryRootRow(
                    root: (root as Map).cast<String, dynamic>(),
                    loading: loading,
                    onRemove: onRemoveFolder,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LibraryRootRow extends StatelessWidget {
  const _LibraryRootRow({
    required this.root,
    required this.loading,
    required this.onRemove,
  });

  final Map<String, dynamic> root;
  final bool loading;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final id = _intValue(root['id']);
    final enabled = root['enabled'] != false;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: IntMusicTheme.of(context).surfaceRaised,
        border: Border.all(color: IntMusicTheme.of(context).stroke),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.folder_outlined : Icons.folder_off_outlined,
            color: enabled
                ? IntMusicTheme.of(context).accent
                : IntMusicTheme.of(context).textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              root['path']?.toString() ?? '-',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: _tr(context, 'Remove'),
            onPressed: loading || id == null ? null : () => onRemove(id),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
