part of '../intmusic_client.dart';

class _TrackVersionManagerDialog extends StatefulWidget {
  const _TrackVersionManagerDialog({
    required this.api,
    required this.trackId,
    required this.detail,
  });

  final CoreApiClient api;
  final int trackId;
  final Map<String, dynamic> detail;

  @override
  State<_TrackVersionManagerDialog> createState() =>
      _TrackVersionManagerDialogState();
}

class _TrackVersionManagerDialogState
    extends State<_TrackVersionManagerDialog> {
  late Map<String, dynamic> _media;
  List<Map<String, dynamic>> _candidates = const [];
  bool _loading = true;
  bool _saving = false;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _media = widget.detail['media'] == null
        ? <String, dynamic>{}
        : _asMap(widget.detail['media']);
    unawaited(_loadCandidates());
  }

  Future<void> _loadCandidates() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await widget.api.getJson(
        '/tracks/${widget.trackId}/recording/candidates',
      );
      final candidates = (response as List? ?? const [])
          .map((item) => (item as Map).cast<String, dynamic>())
          .toList(growable: false);
      if (!mounted) {
        return;
      }
      setState(() {
        _candidates = candidates;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _linkCandidate(Map<String, dynamic> candidate) async {
    final sourceTrackId = _intValue(candidate['track_id']);
    if (sourceTrackId == null || candidate['already_linked'] == true) {
      return;
    }
    final album = candidate['album_title']?.toString() ?? '-';
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_tr(context, 'Link the same recording?')),
            content: Text(
              '${_tr(context, 'This release track will be associated with the recording used by')} “$album”. '
              '${_tr(context, 'Albums, files, masters, and lyric timing remain independent.')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_tr(context, 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_tr(context, 'Link recording')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    await _mutate('/tracks/${widget.trackId}/recording/link', <String, dynamic>{
      'source_track_id': sourceTrackId,
    });
  }

  Future<void> _detach(ReleaseMediaGroup group) async {
    final trackId = group.trackId;
    if (trackId == null) return;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              '${_tr(context, 'Separate')} · ${group.release['title'] ?? ''}',
            ),
            content: Text(
              _tr(
                context,
                'This release track will receive an independent recording identity. Its album and audio files will not change.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_tr(context, 'Cancel')),
              ),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_tr(context, 'Separate')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) {
      return;
    }
    await _mutate(
      '/tracks/$trackId/recording/detach',
      const <String, dynamic>{},
    );
  }

  Future<void> _mutate(String path, Map<String, dynamic> payload) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.postJson(path, payload);
      final media = _asMap(
        await widget.api.getJson('/tracks/${widget.trackId}/media'),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _media = media;
        _saving = false;
        _changed = true;
      });
      await _loadCandidates();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final groups = groupReleaseMedia(_media);
    final unlinked = _candidates
        .where((candidate) => candidate['already_linked'] != true)
        .toList(growable: false);

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, color: tokens.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _tr(context, 'Manage recording versions'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          _tr(
                            context,
                            'Connect release tracks only when they use the same recorded performance.',
                          ),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.pop(context, _changed),
                    icon: const Icon(Icons.close),
                    tooltip: _tr(context, 'Close'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(22),
                children: [
                  _VersionManagerNotice(),
                  const SizedBox(height: 18),
                  for (final group in groups) ...[
                    _ReleaseMediaCard(
                      group: group,
                      coreConnected: true,
                      action: groups.length <= 1
                          ? null
                          : IconButton(
                              onPressed: _saving ? null : () => _detach(group),
                              tooltip: _tr(context, 'Separate'),
                              icon: const Icon(Icons.link_off),
                            ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 6),
                  _VersionManagerSection(
                    title: _tr(context, 'Possible matches'),
                    trailing: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            onPressed: _saving ? null : _loadCandidates,
                            icon: const Icon(Icons.refresh, size: 19),
                            tooltip: _tr(context, 'Refresh'),
                          ),
                    child: _loading
                        ? const SizedBox(height: 72)
                        : unlinked.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              _tr(
                                context,
                                'No safe metadata candidates found.',
                              ),
                              style: TextStyle(color: tokens.textSecondary),
                            ),
                          )
                        : Column(
                            children: [
                              for (
                                var index = 0;
                                index < unlinked.length;
                                index++
                              ) ...[
                                _RecordingCandidateRow(
                                  candidate: unlinked[index],
                                  enabled: !_saving,
                                  onLink: () => _linkCandidate(unlinked[index]),
                                ),
                                if (index != unlinked.length - 1)
                                  Divider(height: 18, color: tokens.stroke),
                              ],
                            ],
                          ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!, style: TextStyle(color: tokens.danger)),
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

class _VersionManagerNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.accent.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: tokens.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _tr(
                  context,
                  'Linking shares only the recording identity. Every album keeps its own track, artwork, master, audio file, and lyric timing.',
                ),
                style: const TextStyle(height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionManagerSection extends StatelessWidget {
  const _VersionManagerSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _RecordingCandidateRow extends StatelessWidget {
  const _RecordingCandidateRow({
    required this.candidate,
    required this.enabled,
    required this.onLink,
  });

  final Map<String, dynamic> candidate;
  final bool enabled;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final confidence = (candidate['confidence'] as num?)?.toDouble() ?? 0;
    final reasons = (candidate['reasons'] as List? ?? const [])
        .map((reason) => _candidateReasonLabel(context, reason.toString()))
        .toList(growable: false);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Column(
            children: [
              Text(
                '${(confidence * 100).round()}%',
                style: TextStyle(
                  color: confidence >= 0.85
                      ? tokens.playing
                      : tokens.accentWarm,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                _tr(context, 'match'),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                candidate['album_title']?.toString() ??
                    candidate['title']?.toString() ??
                    '-',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                _joinParts([
                  candidate['artist_display'],
                  candidate['year'],
                  _formatDuration(candidate['duration_ms']),
                ]),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
              ),
              if (reasons.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: reasons
                      .map(
                        (reason) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: tokens.surfaceRaised,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            reason,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          onPressed: enabled ? onLink : null,
          child: Text(_tr(context, 'Link')),
        ),
      ],
    );
  }
}

String _candidateReasonLabel(BuildContext context, String reason) {
  return switch (reason) {
    'same_title' => _tr(context, 'same title'),
    'same_primary_artist' => _tr(context, 'same artist'),
    'duration_within_1s' => _tr(context, 'duration ±1s'),
    'duration_within_3s' => _tr(context, 'duration ±3s'),
    'duration_within_10s' => _tr(context, 'duration ±10s'),
    'same_recording_kind' => _tr(context, 'same recording type'),
    'already_linked' => _tr(context, 'already linked'),
    _ => reason,
  };
}
