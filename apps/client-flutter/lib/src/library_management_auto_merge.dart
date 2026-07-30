part of '../intmusic_client.dart';

class _AutoTrackMergeDialog extends StatefulWidget {
  const _AutoTrackMergeDialog({required this.preview});

  final Map<String, dynamic> preview;

  @override
  State<_AutoTrackMergeDialog> createState() => _AutoTrackMergeDialogState();
}

class _AutoTrackMergeDialogState extends State<_AutoTrackMergeDialog> {
  late final List<Map<String, dynamic>> _groups;
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _groups = (widget.preview['groups'] as List? ?? const [])
        .whereType<Map>()
        .map((group) => group.cast<String, dynamic>())
        .toList(growable: false);
    _selected = _groups
        .map((group) => group['group_id']?.toString())
        .whereType<String>()
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final allSelected = _selected.length == _groups.length;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940, maxHeight: 780),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: tokens.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.auto_awesome_outlined,
                      color: tokens.accent,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Exact duplicate songs'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          _tr(
                            context,
                            'Review matches before folding device copies and encodings into one release track.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
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
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        _AutoMergeMetric(
                          icon: Icons.layers_outlined,
                          value:
                              '${widget.preview['duplicate_groups'] ?? _groups.length}',
                          label: _tr(context, 'duplicate groups'),
                        ),
                        _AutoMergeMetric(
                          icon: Icons.music_note_outlined,
                          value:
                              '${widget.preview['duplicate_tracks'] ?? _groups.length * 2}',
                          label: _tr(context, 'catalog songs'),
                        ),
                        _AutoMergeMetric(
                          icon: Icons.audio_file_outlined,
                          value: '${widget.preview['physical_files'] ?? 0}',
                          label: _tr(context, 'Physical files'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: tokens.accent.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: tokens.accent.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.verified_user_outlined,
                            size: 20,
                            color: tokens.accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _tr(
                                context,
                                'Only verified files with matching title, primary artist, album, disc and track position, year, version, recording type, and a duration difference of at most 2 seconds are included.',
                              ),
                              style: Theme.of(
                                context,
                              ).textTheme.bodyMedium?.copyWith(height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.preview['truncated'] == true) ...[
                      const SizedBox(height: 12),
                      _AutoMergeNotice(
                        text: _tr(
                          context,
                          'Only the first 200 groups are shown. Run the scan again after this batch.',
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _tr(context, 'Matched groups'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              if (allSelected) {
                                _selected.clear();
                              } else {
                                _selected
                                  ..clear()
                                  ..addAll(
                                    _groups
                                        .map(
                                          (group) =>
                                              group['group_id']?.toString(),
                                        )
                                        .whereType<String>(),
                                  );
                              }
                            });
                          },
                          icon: Icon(
                            allSelected
                                ? Icons.deselect_outlined
                                : Icons.select_all_outlined,
                          ),
                          label: Text(
                            _tr(
                              context,
                              allSelected ? 'Deselect all' : 'Select all',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    for (final group in _groups) ...[
                      _AutoMergeGroupCard(
                        group: group,
                        selected: _selected.contains(
                          group['group_id']?.toString(),
                        ),
                        onChanged: (selected) {
                          final groupId = group['group_id']?.toString();
                          if (groupId == null) return;
                          setState(() {
                            if (selected) {
                              _selected.add(groupId);
                            } else {
                              _selected.remove(groupId);
                            }
                          });
                        },
                      ),
                      const SizedBox(height: 9),
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
                  Icon(
                    Icons.history_outlined,
                    size: 19,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _tr(
                        context,
                        'Every merge keeps an audit record and can still be undone individually.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(_tr(context, 'Cancel')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop(_selected.toList(growable: false)),
                    icon: const Icon(Icons.merge_type),
                    label: Text(
                      '${_tr(context, 'Merge')} ${_selected.length} '
                      '${_tr(context, 'groups')}',
                    ),
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

class _AutoMergeMetric extends StatelessWidget {
  const _AutoMergeMetric({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return Container(
      width: 188,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.stroke),
      ),
      child: Row(
        children: [
          Icon(icon, color: tokens.accent),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AutoMergeNotice extends StatelessWidget {
  const _AutoMergeNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.tertiaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text),
    );
  }
}

class _AutoMergeGroupCard extends StatelessWidget {
  const _AutoMergeGroupCard({
    required this.group,
    required this.selected,
    required this.onChanged,
  });

  final Map<String, dynamic> group;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final minimum = _intValue(group['duration_min_ms']) ?? 0;
    final maximum = _intValue(group['duration_max_ms']) ?? minimum;
    final metadata = _joinParts([
      group['artist_display'],
      group['album_title'],
      if (_intValue(group['year']) case final year?) '$year',
      if (_intValue(group['disc_number']) case final disc?)
        '${_tr(context, 'Disc')} $disc',
      if (_intValue(group['track_number']) case final track?) '#$track',
      if (group['recording_kind']?.toString() case final kind?)
        kind == 'unknown' ? null : kind,
    ]);
    return Material(
      color: selected
          ? tokens.accent.withValues(alpha: 0.075)
          : tokens.surfaceRaised,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? tokens.accent : tokens.stroke,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (value) => onChanged(value ?? false),
              ),
              const SizedBox(width: 4),
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tokens.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.music_note, color: tokens.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group['title']?.toString() ?? '-',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _TrackMetaPill(
                          icon: Icons.call_merge_outlined,
                          label:
                              '${group['track_count'] ?? 0} '
                              '${_tr(context, 'catalog songs')}',
                        ),
                        _TrackMetaPill(
                          icon: Icons.audio_file_outlined,
                          label:
                              '${group['file_count'] ?? 0} '
                              '${_tr(context, 'files')}',
                        ),
                        _TrackMetaPill(
                          icon: Icons.timer_outlined,
                          label: minimum == maximum
                              ? _formatAutoMergeDuration(minimum)
                              : '${_formatAutoMergeDuration(minimum)}–'
                                    '${_formatAutoMergeDuration(maximum)}',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: _tr(
                  context,
                  'The richest available copy is kept as canonical metadata.',
                ),
                child: Icon(
                  Icons.verified_outlined,
                  color: const Color(0xff29a37a),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatAutoMergeDuration(int milliseconds) {
  final seconds = (milliseconds / 1000).round().clamp(0, 359999);
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}
