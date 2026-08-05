part of '../intmusic_client.dart';

class _TrackMergeDialog extends StatefulWidget {
  const _TrackMergeDialog({
    required this.api,
    required this.fileIds,
    required this.initialPreview,
  });

  final CoreApiClient api;
  final List<int> fileIds;
  final Map<String, dynamic> initialPreview;

  @override
  State<_TrackMergeDialog> createState() => _TrackMergeDialogState();
}

class _TrackMergeDialogState extends State<_TrackMergeDialog> {
  late Map<String, dynamic> _preview;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _preview = widget.initialPreview;
  }

  Future<void> _chooseTarget(int trackId) async {
    if (_intValue(_preview['target_track_id']) == trackId || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = _asMap(
        await widget.api.postBulkJson(
          '/library-management/tracks/merge/preview',
          <String, dynamic>{
            'file_ids': widget.fileIds,
            'target_track_id': trackId,
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
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

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final targetTrackId = _intValue(_preview['target_track_id']);
    final candidates = (_preview['candidates'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
    final conflicts = (_preview['conflicts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList(growable: false);
    final canMerge = _preview['can_merge'] == true && !_loading;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860, maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: tokens.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(Icons.merge_type, color: tokens.accent),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Merge physical files'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          _tr(
                            context,
                            'Keep one song identity while preserving every encoding and device copy.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: tokens.stroke),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _tr(context, 'Choose the canonical song'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _tr(
                        context,
                        'Its title, album placement, artwork, and lyrics remain the primary metadata.',
                      ),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final candidate in candidates) ...[
                      _TrackMergeCandidateTile(
                        candidate: candidate,
                        selected:
                            _intValue(candidate['track_id']) == targetTrackId,
                        enabled: !_loading,
                        onSelected: () {
                          final trackId = _intValue(candidate['track_id']);
                          if (trackId != null) {
                            unawaited(_chooseTarget(trackId));
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 12),
                    _TrackMergeConflictPanel(conflicts: conflicts),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      _LibraryManagementError(message: _error!),
                    ],
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: tokens.stroke),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
              child: Row(
                children: [
                  if (_loading)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      canMerge
                          ? Icons.verified_outlined
                          : Icons.report_problem_outlined,
                      size: 19,
                      color: canMerge
                          ? const Color(0xff29a37a)
                          : Theme.of(context).colorScheme.error,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _tr(
                        context,
                        canMerge
                            ? 'The files can be safely represented as one song.'
                            : 'Resolve the identity conflicts before merging.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(_tr(context, 'Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: !canMerge || targetTrackId == null
                        ? null
                        : () {
                            final sources =
                                (_preview['source_track_ids'] as List? ??
                                        const [])
                                    .map(_intValue)
                                    .whereType<int>()
                                    .toList(growable: false);
                            Navigator.of(context).pop(<String, dynamic>{
                              'target_track_id': targetTrackId,
                              'source_track_ids': sources,
                              'confirm_conflicts': conflicts.isNotEmpty,
                            });
                          },
                    icon: const Icon(Icons.check),
                    label: Text(_tr(context, 'Merge files')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackMergeCandidateTile extends StatelessWidget {
  const _TrackMergeCandidateTile({
    required this.candidate,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final Map<String, dynamic> candidate;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final metadata = _joinParts([
      candidate['artist_display'],
      candidate['album_title'],
      if (_intValue(candidate['disc_number']) case final disc?) 'Disc $disc',
      if (_intValue(candidate['track_number']) case final track?) '#$track',
    ]);
    return Material(
      color: selected
          ? tokens.accent.withValues(alpha: 0.09)
          : tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: enabled ? onSelected : null,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 10, 14, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: selected ? tokens.accent : tokens.stroke,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? tokens.accent : tokens.textSecondary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      candidate['title']?.toString() ?? '-',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (metadata.isNotEmpty)
                      Text(
                        metadata,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              _TrackMetaPill(
                icon: Icons.audio_file_outlined,
                label:
                    '${candidate['media_variant_count'] ?? 0} '
                    '${_tr(context, 'versions')}',
              ),
              const SizedBox(width: 6),
              _TrackMetaPill(
                icon: Icons.devices_outlined,
                label:
                    '${candidate['file_count'] ?? 0} '
                    '${_tr(context, 'copies')}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackMergeConflictPanel extends StatelessWidget {
  const _TrackMergeConflictPanel({required this.conflicts});

  final List<Map<String, dynamic>> conflicts;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    if (conflicts.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xff29a37a).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xff29a37a).withValues(alpha: 0.28),
          ),
        ),
        child: Text(
          _tr(
            context,
            'Title, artist, release, track position, and duration are consistent.',
          ),
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tr(context, 'Identity differences'),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final conflict in conflicts)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    conflict['severity'] == 'error'
                        ? Icons.block_outlined
                        : Icons.info_outline,
                    size: 17,
                    color: conflict['severity'] == 'error'
                        ? Theme.of(context).colorScheme.error
                        : tokens.textSecondary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${_trackMergeFieldLabel(context, conflict['field']?.toString())}: '
                      '${conflict['target_value'] ?? '—'} → '
                      '${(conflict['source_values'] as List? ?? const []).join(', ')}',
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

String _trackMergeFieldLabel(BuildContext context, String? field) {
  return _tr(context, switch (field) {
    'title' => 'Title',
    'artist' => 'Artist',
    'album' => 'Album',
    'disc_number' => 'Disc number',
    'track_number' => 'Track number',
    'duration_ms' => 'Duration',
    'recording_kind' => 'Recording type',
    _ => field ?? 'Metadata',
  });
}
