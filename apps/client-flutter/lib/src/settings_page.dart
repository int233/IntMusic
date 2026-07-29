part of '../intmusic_client.dart';

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.coreUrlController,
    required this.serverAliasController,
    required this.clientAliasController,
    required this.loading,
    required this.status,
    required this.rendererStatus,
    required this.settings,
    required this.metadataSettings,
    required this.libraryRoots,
    required this.clientLibraryRoots,
    required this.clientLibraryStatuses,
    required this.clientLibraryPendingFiles,
    required this.tracks,
    required this.clientLibrarySyncingRootIds,
    required this.distributionJobs,
    required this.transcodingStatus,
    required this.clientId,
    required this.diagnostics,
    required this.diagnosticLoggingEnabled,
    required this.diagnosticLogPath,
    required this.language,
    required this.pinCurrentClientRegion,
    required this.zoneRegionSort,
    required this.libraryRootController,
    required this.onConnect,
    required this.onDiscover,
    required this.onScan,
    required this.onAddLibraryRoot,
    required this.onRemoveLibraryRoot,
    required this.onAddClientLibraryRoot,
    required this.onSyncClientLibraryRoot,
    required this.onSyncAllClientLibraryRoots,
    required this.onRemoveClientLibraryRoot,
    required this.onResolveClientLibraryFile,
    required this.onRefreshDistributions,
    required this.onCancelDistribution,
    required this.onSaveServerAlias,
    required this.onSaveClientAlias,
    required this.onLanguageChanged,
    required this.onPinCurrentClientRegionChanged,
    required this.onZoneRegionSortChanged,
    required this.onDiagnosticLoggingChanged,
    required this.onExportDiagnosticLog,
    required this.onUpdateFavoriteSettings,
    required this.onUpdateMetadataSettings,
  });

  final TextEditingController coreUrlController;
  final TextEditingController serverAliasController;
  final TextEditingController clientAliasController;
  final bool loading;
  final Map<String, dynamic>? status;
  final String? rendererStatus;
  final Map<String, dynamic>? settings;
  final Map<String, dynamic>? metadataSettings;
  final List<dynamic> libraryRoots;
  final List<_ClientLibraryRoot> clientLibraryRoots;
  final List<dynamic> clientLibraryStatuses;
  final List<dynamic> clientLibraryPendingFiles;
  final List<dynamic> tracks;
  final Set<String> clientLibrarySyncingRootIds;
  final List<dynamic> distributionJobs;
  final Map<String, dynamic>? transcodingStatus;
  final String clientId;
  final Map<String, dynamic>? diagnostics;
  final bool diagnosticLoggingEnabled;
  final String diagnosticLogPath;
  final _AppLanguage language;
  final bool pinCurrentClientRegion;
  final _ZoneRegionSort zoneRegionSort;
  final TextEditingController libraryRootController;
  final VoidCallback onConnect;
  final VoidCallback onDiscover;
  final VoidCallback onScan;
  final VoidCallback onAddLibraryRoot;
  final ValueChanged<int> onRemoveLibraryRoot;
  final VoidCallback onAddClientLibraryRoot;
  final ValueChanged<String> onSyncClientLibraryRoot;
  final VoidCallback onSyncAllClientLibraryRoots;
  final ValueChanged<String> onRemoveClientLibraryRoot;
  final Future<void> Function(int, Map<String, dynamic>)
  onResolveClientLibraryFile;
  final VoidCallback onRefreshDistributions;
  final ValueChanged<String> onCancelDistribution;
  final VoidCallback onSaveServerAlias;
  final VoidCallback onSaveClientAlias;
  final ValueChanged<_AppLanguage> onLanguageChanged;
  final ValueChanged<bool> onPinCurrentClientRegionChanged;
  final ValueChanged<_ZoneRegionSort> onZoneRegionSortChanged;
  final ValueChanged<bool> onDiagnosticLoggingChanged;
  final VoidCallback onExportDiagnosticLog;
  final Future<void> Function(Map<String, dynamic>) onUpdateFavoriteSettings;
  final Future<void> Function(Map<String, dynamic>) onUpdateMetadataSettings;

  @override
  Widget build(BuildContext context) {
    final treatMax = settings?['treat_max_rating_as_favorite'] != false;
    final writeRating = settings?['write_rating_on_favorite'] == true;
    final counts =
        (status?['counts'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};

    return _PageFrame(
      title: 'Settings',
      child: ListView(
        key: const Key('settings-scroll-view'),
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
        children: [
          _HomePanel(
            title: _tr(context, 'Core Server'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 640;
                    final input = TextField(
                      controller: coreUrlController,
                      decoration: InputDecoration(
                        labelText: _tr(context, 'Core URL'),
                        prefixIcon: const Icon(Icons.hub_outlined),
                      ),
                      onSubmitted: (_) => onConnect(),
                    );
                    final actionButtons = [
                      FilledButton.icon(
                        onPressed: loading ? null : onConnect,
                        icon: loading
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.link),
                        label: Text(_tr(context, 'Connect')),
                      ),
                      OutlinedButton.icon(
                        onPressed: loading ? null : onDiscover,
                        icon: const Icon(Icons.travel_explore_outlined),
                        label: Text(_tr(context, 'Discover')),
                      ),
                    ];
                    final actions = Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.start,
                      children: [
                        for (final button in actionButtons)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: narrow
                                  ? constraints.maxWidth
                                  : double.infinity,
                            ),
                            child: button,
                          ),
                      ],
                    );
                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [input, const SizedBox(height: 10), actions],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: input),
                        const SizedBox(width: 10),
                        actions,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 14),
                _InfoRow(
                  label: _tr(context, 'Renderer'),
                  value: rendererStatus ?? 'pending',
                ),
                _InfoRow(
                  label: _tr(context, 'Version'),
                  value: status?['version']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: _tr(context, 'API'),
                  value: status?['api_version']?.toString() ?? '-',
                ),
                _InfoRow(
                  label: _tr(context, 'Database'),
                  value: status?['database_path']?.toString() ?? '-',
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _LibraryRootsPanel(
            roots: libraryRoots,
            controller: libraryRootController,
            loading: loading,
            onAddFolder: onAddLibraryRoot,
            onRemoveFolder: onRemoveLibraryRoot,
            onScan: onScan,
          ),
          const SizedBox(height: 14),
          _DeviceRegionPreferencesPanel(
            pinCurrentClientRegion: pinCurrentClientRegion,
            regionSort: zoneRegionSort,
            onPinChanged: onPinCurrentClientRegionChanged,
            onSortChanged: onZoneRegionSortChanged,
          ),
          const SizedBox(height: 14),
          _ClientLibraryRootsPanel(
            roots: clientLibraryRoots,
            statuses: clientLibraryStatuses,
            syncingRootIds: clientLibrarySyncingRootIds,
            clientId: clientId,
            onAddFolder: onAddClientLibraryRoot,
            onSyncFolder: onSyncClientLibraryRoot,
            onSyncAll: onSyncAllClientLibraryRoots,
            onRemoveFolder: onRemoveClientLibraryRoot,
          ),
          const SizedBox(height: 14),
          _ClientLibraryPendingFilesPanel(
            files: clientLibraryPendingFiles,
            tracks: tracks,
            onResolve: onResolveClientLibraryFile,
          ),
          const SizedBox(height: 14),
          _TranscodingPanel(status: transcodingStatus),
          const SizedBox(height: 14),
          _DistributionJobsPanel(
            jobs: distributionJobs,
            onRefresh: onRefreshDistributions,
            onCancel: onCancelDistribution,
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Aliases'),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 640;
                final serverField = _AliasEditor(
                  controller: serverAliasController,
                  label: _tr(context, 'Server alias'),
                  icon: Icons.dns_outlined,
                  loading: loading,
                  onSave: onSaveServerAlias,
                );
                final clientField = _AliasEditor(
                  controller: clientAliasController,
                  label: _tr(context, 'Client alias'),
                  icon: Icons.devices_outlined,
                  loading: loading,
                  onSave: onSaveClientAlias,
                );
                if (narrow) {
                  return Column(
                    children: [
                      serverField,
                      const SizedBox(height: 12),
                      clientField,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: serverField),
                    const SizedBox(width: 12),
                    Expanded(child: clientField),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Favorites'),
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsSwitchRow(
                  value: treatMax,
                  title: 'Max rating counts as favorite',
                  subtitle:
                      'RATING 5/5, 100/100, or POPM 255 is shown as favorite',
                  onChanged: (value) => onUpdateFavoriteSettings(
                    <String, dynamic>{'treat_max_rating_as_favorite': value},
                  ),
                ),
                const Divider(height: 1),
                _SettingsSwitchRow(
                  value: writeRating,
                  title: 'Favorite writes max rating',
                  subtitle: 'Writes the maximum rating tag when enabled',
                  onChanged: (value) => onUpdateFavoriteSettings(
                    <String, dynamic>{'write_rating_on_favorite': value},
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Language'),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _tr(context, 'Interface language'),
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                SegmentedButton<_AppLanguage>(
                  segments: [
                    ButtonSegment(
                      value: _AppLanguage.en,
                      label: Text(_tr(context, 'English')),
                    ),
                    ButtonSegment(
                      value: _AppLanguage.zh,
                      label: Text(_tr(context, 'Chinese')),
                    ),
                  ],
                  selected: {language},
                  onSelectionChanged: (values) =>
                      onLanguageChanged(values.first),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _MetadataSeparatorsPanel(
            settings: metadataSettings,
            onUpdate: onUpdateMetadataSettings,
          ),
          const SizedBox(height: 14),
          _HomePanel(
            title: _tr(context, 'Diagnostics'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SettingsSwitchRow(
                  key: const Key('diagnostic-logging-setting'),
                  value: diagnosticLoggingEnabled,
                  title: _tr(context, 'Playback diagnostics log'),
                  subtitle: _tr(
                    context,
                    'Records local playback timing, source selection, Core requests, and renderer errors.',
                  ),
                  onChanged: onDiagnosticLoggingChanged,
                ),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: IntMusicTheme.of(context).surfaceRaised,
                    border: Border.all(color: IntMusicTheme.of(context).stroke),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          color: IntMusicTheme.of(context).accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _tr(context, 'Local log file'),
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                diagnosticLogPath.isEmpty
                                    ? _tr(context, 'Preparing log file…')
                                    : diagnosticLogPath,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: onExportDiagnosticLog,
                          icon: const Icon(Icons.ios_share_outlined),
                          label: Text(_tr(context, 'Export log')),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _InfoRow(
                  label: _tr(context, 'Library'),
                  value: _joinParts([
                    '${counts['tracks'] ?? 0} ${_tr(context, 'Tracks')}',
                    '${counts['albums'] ?? 0} ${_tr(context, 'Albums')}',
                    '${counts['scan_problems'] ?? 0} scan problems',
                  ]),
                ),
                const SizedBox(height: 8),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: IntMusicTheme.of(context).surfaceRaised,
                    border: Border.all(color: IntMusicTheme.of(context).stroke),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 260,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        const JsonEncoder.withIndent(
                          '  ',
                        ).convert(diagnostics ?? const <String, dynamic>{}),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
