part of '../intmusic_client.dart';

class _ClientLibraryPendingFilesPanel extends StatefulWidget {
  const _ClientLibraryPendingFilesPanel({
    required this.files,
    required this.tracks,
    required this.onResolve,
  });

  final List<dynamic> files;
  final List<dynamic> tracks;
  final Future<void> Function(int, Map<String, dynamic>) onResolve;

  @override
  State<_ClientLibraryPendingFilesPanel> createState() =>
      _ClientLibraryPendingFilesPanelState();
}

class _ClientLibraryPendingFilesPanelState
    extends State<_ClientLibraryPendingFilesPanel> {
  final Set<int> _busyFileIds = <int>{};
  bool _showIgnored = false;

  Future<void> _resolve(int fileId, Map<String, dynamic> resolution) async {
    if (_busyFileIds.contains(fileId)) return;
    setState(() => _busyFileIds.add(fileId));
    try {
      await widget.onResolve(fileId, resolution);
    } finally {
      if (mounted) {
        setState(() => _busyFileIds.remove(fileId));
      }
    }
  }

  Future<void> _openResolver(
    BuildContext context,
    Map<String, dynamic> file,
  ) async {
    final resolution = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _ClientLibraryFileResolverDialog(file: file, tracks: widget.tracks),
    );
    final fileId = _intValue(file['file_id']);
    if (resolution == null || fileId == null) return;
    await _resolve(fileId, resolution);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final allFiles = widget.files
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .toList(growable: false);
    final attentionCount = allFiles
        .where((file) => file['scan_status']?.toString() != 'ignored')
        .length;
    final ignoredCount = allFiles.length - attentionCount;
    final visibleFiles = allFiles
        .where(
          (file) =>
              _showIgnored || file['scan_status']?.toString() != 'ignored',
        )
        .toList(growable: false);
    return _HomePanel(
      title: _tr(context, 'Files needing attention'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _tr(
                    context,
                    'Files without usable embedded title and artist tags stay here until you match them or enter metadata.',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: tokens.textSecondary),
                ),
              ),
              if (ignoredCount > 0) ...[
                const SizedBox(width: 12),
                FilterChip(
                  selected: _showIgnored,
                  onSelected: (value) => setState(() => _showIgnored = value),
                  label: Text('${_tr(context, 'Ignored')} $ignoredCount'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _PendingFileSummary(
                icon: Icons.rule_folder_outlined,
                value: attentionCount.toString(),
                label: _tr(context, 'To review'),
                highlighted: attentionCount > 0,
              ),
              const SizedBox(width: 8),
              _PendingFileSummary(
                icon: Icons.inventory_2_outlined,
                value: allFiles.length.toString(),
                label: _tr(context, 'Recorded files'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (visibleFiles.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              decoration: BoxDecoration(
                color: tokens.surfaceRaised,
                border: Border.all(color: tokens.stroke),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Icon(
                    Icons.library_add_check_outlined,
                    color: tokens.accent,
                    size: 30,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _tr(context, 'No files need attention'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
            )
          else
            for (final file in visibleFiles)
              _ClientLibraryPendingFileCard(
                file: file,
                busy: _busyFileIds.contains(_intValue(file['file_id'])),
                onProcess: () => _openResolver(context, file),
                onIgnore: () {
                  final fileId = _intValue(file['file_id']);
                  if (fileId != null) {
                    _resolve(fileId, const <String, dynamic>{
                      'action': 'ignore',
                    });
                  }
                },
                onReset: () {
                  final fileId = _intValue(file['file_id']);
                  if (fileId != null) {
                    _resolve(fileId, const <String, dynamic>{
                      'action': 'reset',
                    });
                  }
                },
              ),
        ],
      ),
    );
  }
}

class _PendingFileSummary extends StatelessWidget {
  const _PendingFileSummary({
    required this.icon,
    required this.value,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String value;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final color = highlighted ? tokens.accent : tokens.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: highlighted
            ? tokens.accent.withValues(alpha: 0.1)
            : tokens.surfaceRaised,
        border: Border.all(
          color: highlighted
              ? tokens.accent.withValues(alpha: 0.28)
              : tokens.stroke,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 7),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: color),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ClientLibraryPendingFileCard extends StatelessWidget {
  const _ClientLibraryPendingFileCard({
    required this.file,
    required this.busy,
    required this.onProcess,
    required this.onIgnore,
    required this.onReset,
  });

  final Map<String, dynamic> file;
  final bool busy;
  final VoidCallback onProcess;
  final VoidCallback onIgnore;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final ignored = file['scan_status']?.toString() == 'ignored';
    final parseError = file['scan_status']?.toString() == 'tag_parse_error';
    final message = file['scan_message']?.toString().trim();
    final extension =
        file['codec']?.toString().trim().toUpperCase() ??
        file['extension']?.toString().trim().toUpperCase() ??
        '';
    final technical = <String>[
      if (extension.isNotEmpty) extension,
      if (_formatBytes(file['size_bytes']).isNotEmpty)
        _formatBytes(file['size_bytes']),
      if (_intValue(file['sample_rate']) case final sampleRate?)
        '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz',
      if (_intValue(file['bit_depth']) case final bitDepth?) '$bitDepth-bit',
      if (_formatDuration(file['duration_ms']).isNotEmpty)
        _formatDuration(file['duration_ms']),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(
          color: ignored
              ? tokens.stroke
              : tokens.accent.withValues(alpha: 0.32),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 720;
          final details = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color:
                      (ignored
                              ? tokens.textSecondary
                              : parseError
                              ? Theme.of(context).colorScheme.error
                              : tokens.accent)
                          .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  ignored
                      ? Icons.visibility_off_outlined
                      : parseError
                      ? Icons.broken_image_outlined
                      : Icons.sell_outlined,
                  color: ignored
                      ? tokens.textSecondary
                      : parseError
                      ? Theme.of(context).colorScheme.error
                      : tokens.accent,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _clientLibraryBasename(
                        file['relative_path']?.toString() ?? '',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _joinParts([
                        file['device_name'],
                        file['root_display_name'],
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      file['relative_path']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    if (technical.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 5,
                        children: [
                          for (final item in technical)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: tokens.stroke),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                item,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (message != null && message.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        _clientLibraryStatusMessage(context, message),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: parseError
                              ? Theme.of(context).colorScheme.error
                              : tokens.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
          final actions = ignored
              ? OutlinedButton.icon(
                  onPressed: busy ? null : onReset,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_outlined),
                  label: Text(_tr(context, 'Review again')),
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy ? null : onProcess,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.rule_outlined),
                      label: Text(_tr(context, 'Process')),
                    ),
                    TextButton(
                      onPressed: busy ? null : onIgnore,
                      child: Text(_tr(context, 'Ignore')),
                    ),
                  ],
                );
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: details),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _ClientLibraryFileResolverDialog extends StatefulWidget {
  const _ClientLibraryFileResolverDialog({
    required this.file,
    required this.tracks,
  });

  final Map<String, dynamic> file;
  final List<dynamic> tracks;

  @override
  State<_ClientLibraryFileResolverDialog> createState() =>
      _ClientLibraryFileResolverDialogState();
}

class _ClientLibraryFileResolverDialogState
    extends State<_ClientLibraryFileResolverDialog> {
  final _queryController = TextEditingController();
  final _titleController = TextEditingController();
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();
  final _albumArtistController = TextEditingController();
  final _trackNumberController = TextEditingController();
  final _discNumberController = TextEditingController();
  final _yearController = TextEditingController();
  int _mode = 0;
  int? _selectedTrackId;

  @override
  void initState() {
    super.initState();
    final metadata = _asMap(widget.file['metadata']);
    _titleController.text = metadata['title']?.toString() ?? '';
    _artistController.text = (metadata['track_artists'] as List? ?? const [])
        .map((value) => value.toString())
        .join('; ');
    _albumController.text = metadata['album']?.toString() ?? '';
    _albumArtistController.text =
        (metadata['album_artists'] as List? ?? const [])
            .map((value) => value.toString())
            .join('; ');
    _trackNumberController.text =
        _intValue(metadata['track_number'])?.toString() ?? '';
    _discNumberController.text =
        _intValue(metadata['disc_number'])?.toString() ?? '';
    _yearController.text = _intValue(metadata['year'])?.toString() ?? '';
  }

  @override
  void dispose() {
    _queryController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _albumArtistController.dispose();
    _trackNumberController.dispose();
    _discNumberController.dispose();
    _yearController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _matchingTracks {
    final query = _queryController.text.trim().toLowerCase();
    final currentTrackId = _intValue(widget.file['track_id']);
    final tracks = widget.tracks
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .where((track) => _intValue(track['id']) != currentTrackId);
    if (query.isEmpty) {
      return tracks.take(40).toList(growable: false);
    }
    return tracks
        .where((track) {
          final haystack = <Object?>[
            track['title'],
            track['artist_display'],
            track['album_title'],
          ].join(' ').toLowerCase();
          return haystack.contains(query);
        })
        .take(40)
        .toList(growable: false);
  }

  void _submit() {
    if (_mode == 0) {
      if (_selectedTrackId == null) return;
      Navigator.of(context).pop(<String, dynamic>{
        'action': 'match',
        'target_track_id': _selectedTrackId,
      });
      return;
    }
    final title = _titleController.text.trim();
    final artists = _splitManualTagValues(_artistController.text);
    if (title.isEmpty || artists.isEmpty) return;
    final albumArtists = _splitManualTagValues(_albumArtistController.text);
    Navigator.of(context).pop(<String, dynamic>{
      'action': 'metadata',
      'metadata': <String, dynamic>{
        'title': title,
        'album': _nullableText(_albumController.text),
        'track_artists': artists,
        'album_artists': albumArtists.isEmpty ? artists : albumArtists,
        'track_number': int.tryParse(_trackNumberController.text.trim()),
        'disc_number': int.tryParse(_discNumberController.text.trim()),
        'year': int.tryParse(_yearController.text.trim()),
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final candidates = _matchingTracks;
    final canSubmit = _mode == 0
        ? _selectedTrackId != null
        : _titleController.text.trim().isNotEmpty &&
              _splitManualTagValues(_artistController.text).isNotEmpty;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Process local music file'),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.file['relative_path']?.toString() ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _tr(context, 'Close'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    selected: _mode == 0,
                    onSelected: (_) => setState(() => _mode = 0),
                    avatar: const Icon(Icons.link_outlined, size: 18),
                    label: Text(_tr(context, 'Match existing track')),
                  ),
                  ChoiceChip(
                    selected: _mode == 1,
                    onSelected: (_) => setState(() => _mode = 1),
                    avatar: const Icon(Icons.edit_note_outlined, size: 18),
                    label: Text(_tr(context, 'Enter metadata')),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _mode == 0
                      ? Column(
                          key: const ValueKey('match'),
                          children: [
                            TextField(
                              controller: _queryController,
                              autofocus: true,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: _tr(
                                  context,
                                  'Search title, artist, or album',
                                ),
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: _queryController.text.isEmpty
                                    ? null
                                    : IconButton(
                                        onPressed: () {
                                          _queryController.clear();
                                          setState(() {});
                                        },
                                        icon: const Icon(Icons.clear),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Expanded(
                              child: candidates.isEmpty
                                  ? Center(
                                      child: Text(
                                        _tr(context, 'No matching tracks'),
                                      ),
                                    )
                                  : ListView.separated(
                                      itemCount: candidates.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(height: 5),
                                      itemBuilder: (context, index) {
                                        final track = candidates[index];
                                        final trackId = _intValue(track['id']);
                                        final selected =
                                            trackId != null &&
                                            trackId == _selectedTrackId;
                                        return InkWell(
                                          onTap: trackId == null
                                              ? null
                                              : () => setState(
                                                  () => _selectedTrackId =
                                                      trackId,
                                                ),
                                          borderRadius: BorderRadius.circular(
                                            9,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 10,
                                            ),
                                            decoration: BoxDecoration(
                                              color: selected
                                                  ? tokens.accent.withValues(
                                                      alpha: 0.11,
                                                    )
                                                  : tokens.surfaceRaised,
                                              border: Border.all(
                                                color: selected
                                                    ? tokens.accent
                                                    : tokens.stroke,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  selected
                                                      ? Icons
                                                            .check_circle_rounded
                                                      : Icons
                                                            .radio_button_unchecked,
                                                  color: selected
                                                      ? tokens.accent
                                                      : tokens.textSecondary,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        track['title']
                                                                ?.toString() ??
                                                            '-',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.titleSmall,
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        _joinParts([
                                                          track['artist_display'],
                                                          track['album_title'],
                                                        ]),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              color: tokens
                                                                  .textSecondary,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        )
                      : ListView(
                          key: const ValueKey('metadata'),
                          children: [
                            Text(
                              _tr(
                                context,
                                'This creates a catalog entry from values you confirm. The filename and folder are never used as identity.',
                              ),
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: tokens.textSecondary),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _titleController,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: '${_tr(context, 'Title')} *',
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _artistController,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: '${_tr(context, 'Artists')} *',
                                helperText: _tr(
                                  context,
                                  'Separate multiple names with semicolons',
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _albumController,
                              decoration: InputDecoration(
                                labelText: _tr(context, 'Album'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _albumArtistController,
                              decoration: InputDecoration(
                                labelText: _tr(context, 'Album artists'),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _discNumberController,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: _tr(context, 'Disc number'),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _trackNumberController,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: _tr(context, 'Track number'),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextField(
                                    controller: _yearController,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: _tr(context, 'Year'),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(_tr(context, 'Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: canSubmit ? _submit : null,
                    icon: const Icon(Icons.check),
                    label: Text(
                      _mode == 0
                          ? _tr(context, 'Confirm match')
                          : _tr(context, 'Create track'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _clientLibraryBasename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

String _clientLibraryStatusMessage(BuildContext context, String message) {
  if (message.startsWith('Missing required embedded ')) {
    final tags = message
        .replaceFirst('Missing required embedded ', '')
        .replaceFirst(' tags', '');
    return '${_tr(context, 'Missing embedded tags')}: $tags';
  }
  return message;
}

List<String> _splitManualTagValues(String value) {
  return value
      .split(RegExp(r'[;\n]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList(growable: false);
}

String? _nullableText(String value) {
  final text = value.trim();
  return text.isEmpty ? null : text;
}
