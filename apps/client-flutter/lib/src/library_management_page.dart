part of '../intmusic_client.dart';

enum _LibraryInventoryTab { overview, files, devices, attention }

class _LibraryManagementPage extends StatefulWidget {
  const _LibraryManagementPage({
    required this.coreBaseUrl,
    required this.tracks,
    required this.onOpenTrack,
    required this.onLibraryChanged,
  });

  final String coreBaseUrl;
  final List<dynamic> tracks;
  final Future<void> Function(int) onOpenTrack;
  final Future<void> Function() onLibraryChanged;

  @override
  State<_LibraryManagementPage> createState() => _LibraryManagementPageState();
}

class _LibraryManagementPageState extends State<_LibraryManagementPage> {
  static const _filePageSize = 100;

  final _searchController = TextEditingController();
  _LibraryInventoryTab _tab = _LibraryInventoryTab.overview;
  Map<String, dynamic> _summary = const {};
  List<dynamic> _files = const [];
  List<dynamic> _devices = const [];
  String _fileStatus = 'all';
  String? _deviceFilter;
  String? _extensionFilter;
  int _fileTotal = 0;
  int _fileOffset = 0;
  bool _loading = true;
  String? _error;
  Timer? _searchDebounce;
  final Set<int> _selectedFileIds = <int>{};
  int _loadGeneration = 0;

  CoreApiClient get _api => CoreApiClient(widget.coreBaseUrl);

  @override
  void initState() {
    super.initState();
    unawaited(_refreshAll());
  }

  @override
  void didUpdateWidget(covariant _LibraryManagementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coreBaseUrl != widget.coreBaseUrl) {
      unawaited(_refreshAll());
    }
  }

  @override
  void dispose() {
    _loadGeneration += 1;
    _api.cancelBulkRequests();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    final generation = ++_loadGeneration;
    _api.cancelBulkRequests();
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final overviewRefresh = _refreshOverview();
    try {
      final page = await _fetchFiles();
      await overviewRefresh;
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _files = (page['items'] as List?) ?? const [];
        _fileTotal = _intValue(page['total']) ?? _files.length;
        _loading = false;
      });
    } catch (error) {
      await overviewRefresh;
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _refreshOverview() async {
    try {
      final values = await Future.wait<dynamic>([
        _api.getJson('/library-management/summary'),
        _api.getJson('/library-management/devices'),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = _asMap(values[0]);
        _devices = values[1] as List<dynamic>;
      });
    } catch (error) {
      if (mounted && _summary.isEmpty && _devices.isEmpty) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<Map<String, dynamic>> _fetchFiles() async {
    final parameters = <String, String>{
      'limit': '$_filePageSize',
      'offset': '$_fileOffset',
      'status': _tab == _LibraryInventoryTab.attention
          ? 'attention'
          : _fileStatus,
      if (_searchController.text.trim().isNotEmpty)
        'search': _searchController.text.trim(),
    };
    if (_deviceFilter case final deviceFilter?) {
      parameters['device_id'] = deviceFilter;
    }
    if (_extensionFilter case final extensionFilter?) {
      parameters['extension'] = extensionFilter;
    }
    final query = parameters.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}='
              '${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    return _asMap(await _api.getBulkJson('/library-management/files?$query'));
  }

  Future<void> _refreshFiles({bool resetOffset = false}) async {
    final generation = ++_loadGeneration;
    _api.cancelBulkRequests();
    if (mounted) {
      setState(() {
        if (resetOffset) _fileOffset = 0;
        _loading = true;
        _error = null;
      });
    }
    try {
      final page = await _fetchFiles();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _files = (page['items'] as List?) ?? const [];
        _fileTotal = _intValue(page['total']) ?? _files.length;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _selectTab(_LibraryInventoryTab tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _selectedFileIds.clear();
    });
    if (tab == _LibraryInventoryTab.files ||
        tab == _LibraryInventoryTab.attention) {
      unawaited(_refreshFiles(resetOffset: true));
    }
  }

  void _searchChanged(String value) {
    _searchDebounce?.cancel();
    if (_selectedFileIds.isNotEmpty) {
      setState(_selectedFileIds.clear);
    }
    _searchDebounce = Timer(
      const Duration(milliseconds: 260),
      () => unawaited(_refreshFiles(resetOffset: true)),
    );
  }

  Future<void> _fileAction(int fileId, String action) async {
    try {
      await _api.postBulkJson(
        '/library-management/files/$fileId/action',
        <String, dynamic>{'action': action},
      );
      await _refreshAll();
      await widget.onLibraryChanged();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _batchFileAction(Set<int> fileIds, String action) async {
    if (fileIds.isEmpty) return;
    try {
      final sortedIds = fileIds.toList()..sort();
      var updated = 0;
      for (var offset = 0; offset < sortedIds.length; offset += 500) {
        final end = min(offset + 500, sortedIds.length);
        final result = _asMap(
          await _api.postBulkJson(
            '/library-management/files/actions',
            <String, dynamic>{
              'action': action,
              'file_ids': sortedIds.sublist(offset, end),
            },
          ),
        );
        updated += _intValue(result['updated']) ?? end - offset;
      }
      if (mounted) {
        setState(_selectedFileIds.clear);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$updated ${_tr(context, 'files updated')}')),
        );
      }
      await _refreshAll();
      await widget.onLibraryChanged();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _mergeSelectedFiles(Set<int> fileIds) async {
    if (fileIds.length < 2) return;
    try {
      final sortedFileIds = fileIds.toList()..sort();
      final preview = _asMap(
        await _api.postBulkJson(
          '/library-management/tracks/merge/preview',
          <String, dynamic>{'file_ids': sortedFileIds},
        ),
      );
      if (!mounted) return;
      final request = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _TrackMergeDialog(
          api: _api,
          fileIds: sortedFileIds,
          initialPreview: preview,
        ),
      );
      if (request == null) return;
      final result = _asMap(
        await _api.postBulkJson('/library-management/tracks/merge', request),
      );
      if (!mounted) return;
      setState(_selectedFileIds.clear);
      await _refreshAll();
      await widget.onLibraryChanged();
      if (!mounted) return;
      final mergeId = result['merge_id']?.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_intValue(result['merged_tracks']) ?? 0} '
            '${_tr(context, 'tracks merged as one song')}',
          ),
          action: mergeId == null
              ? null
              : SnackBarAction(
                  label: _tr(context, 'Undo'),
                  onPressed: () => unawaited(_undoTrackMerge(mergeId)),
                ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _undoTrackMerge(String mergeId) async {
    try {
      await _api.postBulkJson(
        '/library-management/track-merges/'
        '${Uri.encodeComponent(mergeId)}/undo',
        const <String, dynamic>{},
      );
      await _refreshAll();
      await widget.onLibraryChanged();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _autoMergeExactDuplicates() async {
    try {
      final preview = _asMap(
        await _api.postBulkJson(
          '/library-management/tracks/auto-merge/preview',
          const <String, dynamic>{'limit': 500},
        ),
      );
      if (!mounted) return;
      final groups = preview['groups'] as List? ?? const [];
      if (groups.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_tr(context, 'No safe exact duplicates were found.')),
          ),
        );
        return;
      }
      final groupIds = await showDialog<List<String>>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _AutoTrackMergeDialog(preview: preview),
      );
      if (groupIds == null || groupIds.isEmpty) return;
      final result = _asMap(
        await _api.postBulkJson(
          '/library-management/tracks/auto-merge',
          <String, dynamic>{'group_ids': groupIds},
        ),
      );
      await _refreshAll();
      await widget.onLibraryChanged();
      if (!mounted) return;
      final failures = result['failures'] as List? ?? const [];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_intValue(result['merged_groups']) ?? 0} '
            '${_tr(context, 'duplicate groups merged')}, '
            '${_intValue(result['merged_tracks']) ?? 0} '
            '${_tr(context, 'duplicate songs folded')}'
            '${failures.isEmpty ? '' : ' · ${failures.length} ${_tr(context, 'groups skipped')}'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _resolveFile(int fileId, Map<String, dynamic> resolution) async {
    try {
      await _api.postJson('/client-library/files/$fileId/resolve', resolution);
      await _refreshAll();
      await widget.onLibraryChanged();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _openResolver(Map<String, dynamic> file) async {
    final fileId = _intValue(file['file_id']);
    if (fileId == null) return;
    var resolverFile = file;
    try {
      final detail = _asMap(
        await _api.getBulkJson('/library-management/files/$fileId'),
      );
      resolverFile = <String, dynamic>{
        ...file,
        'metadata': detail['embedded_metadata'],
      };
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      return;
    }
    if (!mounted) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _ClientLibraryFileResolverDialog(
        file: resolverFile,
        tracks: widget.tracks,
      ),
    );
    if (result != null) {
      await _resolveFile(fileId, result);
    }
  }

  Future<void> _openFileDetail(Map<String, dynamic> file) async {
    final fileId = _intValue(file['file_id']);
    if (fileId == null) return;
    try {
      final detail = _asMap(
        await _api.getBulkJson('/library-management/files/$fileId'),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _LibraryFileDetailDialog(
          detail: detail,
          onOpenTrack: (trackId) {
            Navigator.of(context).pop();
            unawaited(widget.onOpenTrack(trackId));
          },
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _deviceAction(String deviceId, String action) async {
    try {
      await _api.postBulkJson(
        '/library-management/devices/${Uri.encodeComponent(deviceId)}/action',
        <String, dynamic>{'action': action},
      );
      await _refreshAll();
      await widget.onLibraryChanged();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _sourceAction(int rootId, String action) async {
    try {
      await _api.postBulkJson(
        '/library-management/sources/$rootId/action',
        <String, dynamic>{'action': action},
      );
      await _refreshAll();
      await widget.onLibraryChanged();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: 'Library management',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<_LibraryInventoryTab>(
                        segments: [
                          ButtonSegment(
                            value: _LibraryInventoryTab.overview,
                            icon: const Icon(Icons.dashboard_outlined),
                            label: Text(_tr(context, 'Overview')),
                          ),
                          ButtonSegment(
                            value: _LibraryInventoryTab.files,
                            icon: const Icon(Icons.audio_file_outlined),
                            label: Text(_tr(context, 'All files')),
                          ),
                          ButtonSegment(
                            value: _LibraryInventoryTab.devices,
                            icon: const Icon(Icons.devices_outlined),
                            label: Text(_tr(context, 'Devices and sources')),
                          ),
                          ButtonSegment(
                            value: _LibraryInventoryTab.attention,
                            icon: const Icon(Icons.rule_folder_outlined),
                            label: Text(_tr(context, 'Needs attention')),
                          ),
                        ],
                        selected: {_tab},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) => _selectTab(value.first),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _tr(context, 'Refresh'),
                  onPressed: _loading ? null : () => unawaited(_refreshAll()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
              child: _LibraryManagementError(message: _error!),
            ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: switch (_tab) {
                _LibraryInventoryTab.overview => _LibraryOverviewView(
                  key: const ValueKey('library-overview'),
                  summary: _summary,
                  devices: _devices,
                  loading: _loading,
                  onOpenFiles: () => _selectTab(_LibraryInventoryTab.files),
                  onOpenAttention: () =>
                      _selectTab(_LibraryInventoryTab.attention),
                  onOpenDevices: () => _selectTab(_LibraryInventoryTab.devices),
                  onFindDuplicates: _autoMergeExactDuplicates,
                ),
                _LibraryInventoryTab.files ||
                _LibraryInventoryTab.attention => _LibraryFilesView(
                  key: ValueKey('library-files-${_tab.name}'),
                  files: _files,
                  total: _fileTotal,
                  offset: _fileOffset,
                  pageSize: _filePageSize,
                  loading: _loading,
                  attentionOnly: _tab == _LibraryInventoryTab.attention,
                  status: _fileStatus,
                  deviceFilter: _deviceFilter,
                  extensionFilter: _extensionFilter,
                  devices: _devices,
                  searchController: _searchController,
                  onSearchChanged: _searchChanged,
                  onStatusChanged: (value) {
                    setState(() {
                      _fileStatus = value;
                      _selectedFileIds.clear();
                    });
                    unawaited(_refreshFiles(resetOffset: true));
                  },
                  onDeviceChanged: (value) {
                    setState(() {
                      _deviceFilter = value;
                      _selectedFileIds.clear();
                    });
                    unawaited(_refreshFiles(resetOffset: true));
                  },
                  onExtensionChanged: (value) {
                    setState(() {
                      _extensionFilter = value;
                      _selectedFileIds.clear();
                    });
                    unawaited(_refreshFiles(resetOffset: true));
                  },
                  onPageChanged: (offset) {
                    setState(() => _fileOffset = offset);
                    unawaited(_refreshFiles());
                  },
                  onOpen: _openFileDetail,
                  onResolve: _openResolver,
                  onAction: _fileAction,
                  selectedFileIds: _selectedFileIds,
                  onSelectionChanged: (fileId, selected) {
                    setState(() {
                      if (selected) {
                        _selectedFileIds.add(fileId);
                      } else {
                        _selectedFileIds.remove(fileId);
                      }
                    });
                  },
                  onSelectPage: (fileIds, selected) {
                    setState(() {
                      if (selected) {
                        _selectedFileIds.addAll(fileIds);
                      } else {
                        _selectedFileIds.removeAll(fileIds);
                      }
                    });
                  },
                  onClearSelection: () => setState(_selectedFileIds.clear),
                  onBatchAction: _batchFileAction,
                  onMerge: _mergeSelectedFiles,
                ),
                _LibraryInventoryTab.devices => _LibraryDevicesView(
                  key: const ValueKey('library-devices'),
                  devices: _devices,
                  loading: _loading,
                  onDeviceAction: _deviceAction,
                  onSourceAction: _sourceAction,
                  onShowFiles: (deviceId) {
                    setState(() {
                      _deviceFilter = deviceId;
                      _fileOffset = 0;
                      _tab = _LibraryInventoryTab.files;
                    });
                    unawaited(_refreshFiles());
                  },
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryManagementError extends StatelessWidget {
  const _LibraryManagementError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryOverviewView extends StatelessWidget {
  const _LibraryOverviewView({
    super.key,
    required this.summary,
    required this.devices,
    required this.loading,
    required this.onOpenFiles,
    required this.onOpenAttention,
    required this.onOpenDevices,
    required this.onFindDuplicates,
  });

  final Map<String, dynamic> summary;
  final List<dynamic> devices;
  final bool loading;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenAttention;
  final VoidCallback onOpenDevices;
  final VoidCallback onFindDuplicates;

  @override
  Widget build(BuildContext context) {
    final metrics = <(String, Object, IconData, VoidCallback)>[
      (
        'All files',
        summary['active_files'] ?? 0,
        Icons.audio_file_outlined,
        onOpenFiles,
      ),
      (
        'Available',
        summary['available_files'] ?? 0,
        Icons.cloud_done_outlined,
        onOpenFiles,
      ),
      (
        'Needs attention',
        summary['attention_files'] ?? 0,
        Icons.rule_folder_outlined,
        onOpenAttention,
      ),
      (
        'Devices',
        summary['device_count'] ?? devices.length,
        Icons.devices_outlined,
        onOpenDevices,
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 28),
      children: [
        if (loading && summary.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: CircularProgressIndicator(),
            ),
          )
        else ...[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final metric in metrics)
                _LibraryMetricCard(
                  label: _tr(context, metric.$1),
                  value: metric.$2,
                  icon: metric.$3,
                  onTap: metric.$4,
                ),
            ],
          ),
          const SizedBox(height: 16),
          _HomePanel(
            title: _tr(context, 'Storage and availability'),
            child: Wrap(
              spacing: 28,
              runSpacing: 14,
              children: [
                _LibraryOverviewFact(
                  label: _tr(context, 'Total size'),
                  value: _formatLibraryBytes(summary['total_bytes']),
                ),
                _LibraryOverviewFact(
                  label: _tr(context, 'Unavailable'),
                  value: '${summary['unavailable_files'] ?? 0}',
                ),
                _LibraryOverviewFact(
                  label: _tr(context, 'Sources'),
                  value: '${summary['source_count'] ?? 0}',
                ),
                _LibraryOverviewFact(
                  label: _tr(context, 'Ignored'),
                  value: '${summary['ignored_files'] ?? 0}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _HomePanel(
            title: _tr(context, 'Management model'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tr(
                    context,
                    'Core keeps every physical file in this inventory. Offline and retired devices remain manageable; attention is a filter, not a separate library.',
                  ),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: IntMusicTheme.of(context).textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: loading ? null : onFindDuplicates,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(_tr(context, 'Find exact duplicate songs')),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

String _formatLibraryBytes(Object? value) {
  final bytes = _intValue(value) ?? 0;
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var amount = bytes.toDouble();
  var unit = -1;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  return '${amount.toStringAsFixed(amount >= 100 ? 0 : 1)} ${units[unit]}';
}

class _LibraryMetricCard extends StatelessWidget {
  const _LibraryMetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final Object value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return SizedBox(
      width: 210,
      height: 126,
      child: Material(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: tokens.stroke),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: tokens.accent),
                  const Spacer(),
                  Text(
                    '$value',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(label, style: Theme.of(context).textTheme.labelLarge),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryOverviewFact extends StatelessWidget {
  const _LibraryOverviewFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: IntMusicTheme.of(context).textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
