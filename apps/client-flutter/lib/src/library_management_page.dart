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
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final values = await Future.wait<dynamic>([
        _api.getJson('/library-management/summary'),
        _api.getJson('/library-management/devices'),
        _fetchFiles(),
      ]);
      if (!mounted) return;
      final page = _asMap(values[2]);
      setState(() {
        _summary = _asMap(values[0]);
        _devices = values[1] as List<dynamic>;
        _files = (page['items'] as List?) ?? const [];
        _fileTotal = _intValue(page['total']) ?? _files.length;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
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
    return _asMap(await _api.getJson('/library-management/files?$query'));
  }

  Future<void> _refreshFiles({bool resetOffset = false}) async {
    if (mounted) {
      setState(() {
        if (resetOffset) _fileOffset = 0;
        _loading = true;
        _error = null;
      });
    }
    try {
      final page = await _fetchFiles();
      if (!mounted) return;
      setState(() {
        _files = (page['items'] as List?) ?? const [];
        _fileTotal = _intValue(page['total']) ?? _files.length;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _selectTab(_LibraryInventoryTab tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    if (tab == _LibraryInventoryTab.files ||
        tab == _LibraryInventoryTab.attention) {
      unawaited(_refreshFiles(resetOffset: true));
    }
  }

  void _searchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 260),
      () => unawaited(_refreshFiles(resetOffset: true)),
    );
  }

  Future<void> _fileAction(int fileId, String action) async {
    try {
      await _api.postJson(
        '/library-management/files/$fileId/action',
        <String, dynamic>{'action': action},
      );
      await _refreshAll();
      await widget.onLibraryChanged();
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
        await _api.getJson('/library-management/files/$fileId'),
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
        await _api.getJson('/library-management/files/$fileId'),
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
      await _api.postJson(
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
      await _api.postJson(
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
                    setState(() => _fileStatus = value);
                    unawaited(_refreshFiles(resetOffset: true));
                  },
                  onDeviceChanged: (value) {
                    setState(() => _deviceFilter = value);
                    unawaited(_refreshFiles(resetOffset: true));
                  },
                  onExtensionChanged: (value) {
                    setState(() => _extensionFilter = value);
                    unawaited(_refreshFiles(resetOffset: true));
                  },
                  onPageChanged: (offset) {
                    setState(() => _fileOffset = offset);
                    unawaited(_refreshFiles());
                  },
                  onOpen: _openFileDetail,
                  onResolve: _openResolver,
                  onAction: _fileAction,
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
  });

  final Map<String, dynamic> summary;
  final List<dynamic> devices;
  final bool loading;
  final VoidCallback onOpenFiles;
  final VoidCallback onOpenAttention;
  final VoidCallback onOpenDevices;

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
            child: Text(
              _tr(
                context,
                'Core keeps every physical file in this inventory. Offline and retired devices remain manageable; attention is a filter, not a separate library.',
              ),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: IntMusicTheme.of(context).textSecondary,
                height: 1.5,
              ),
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
