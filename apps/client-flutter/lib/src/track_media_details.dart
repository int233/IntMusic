part of '../intmusic_client.dart';

class _TrackLyricsCard extends StatelessWidget {
  const _TrackLyricsCard({required this.lyrics});

  final Map<String, dynamic>? lyrics;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final lyrics = this.lyrics;
    final original = lyrics?['text']?.toString().trim() ?? '';
    final translation = lyrics?['translation']?.toString().trim() ?? '';
    final pronunciation = lyrics?['pronunciation']?.toString().trim() ?? '';
    final badges = <String>[
      if ((lyrics?['kind']?.toString() ?? '').isNotEmpty)
        lyrics!['kind'].toString().toUpperCase(),
      if ((lyrics?['language']?.toString() ?? '').isNotEmpty)
        lyrics!['language'].toString().toUpperCase(),
      if (_intValue(lyrics?['revision']) != null)
        '${_tr(context, 'Revision')} ${lyrics!['revision']}',
    ];
    return _HomePanel(
      title: _tr(context, 'Lyrics'),
      trailing: badges.isEmpty
          ? null
          : Wrap(
              spacing: 6,
              children: badges
                  .map(
                    (badge) => _TrackMetaPill(
                      icon: Icons.notes_outlined,
                      label: badge,
                    ),
                  )
                  .toList(growable: false),
            ),
      child: original.isEmpty
          ? SizedBox(
              width: double.infinity,
              height: 130,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lyrics_outlined,
                    size: 34,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(height: 9),
                  Text(_tr(context, 'No embedded lyrics')),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LyricTextSection(
                  label: _tr(context, 'Original lyrics'),
                  text: original,
                  emphasized: true,
                ),
                if (translation.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _LyricTextSection(
                    label: _tr(context, 'Translation'),
                    text: translation,
                  ),
                ],
                if (pronunciation.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _LyricTextSection(
                    label: _tr(context, 'Pronunciation'),
                    text: pronunciation,
                  ),
                ],
              ],
            ),
    );
  }
}

class _LyricTextSection extends StatelessWidget {
  const _LyricTextSection({
    required this.label,
    required this.text,
    this.emphasized = false,
  });

  final String label;
  final String text;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasized
            ? tokens.accent.withValues(alpha: 0.055)
            : tokens.surfaceRaised.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: emphasized ? tokens.accent : tokens.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                height: 1.65,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseMediaCard extends StatelessWidget {
  const _ReleaseMediaCard({
    required this.group,
    required this.coreConnected,
    this.action,
  });
  final ReleaseMediaGroup group;
  final bool coreConnected;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final title = group.release['title']?.toString() ?? '-';
    final edition = group.release['edition_title']?.toString();
    final subtitle = _joinParts([
      group.release['year'],
      if (edition != title) edition,
      if (group.tracks.first['track_number'] != null)
        '#${group.tracks.first['track_number']}',
    ]);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.album_outlined, color: tokens.accent, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: tokens.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (group.isCurrent)
                _TrackMetaPill(
                  icon: Icons.check_circle_outline,
                  label: _tr(context, 'Current'),
                ),
              ?action,
            ],
          ),
          const SizedBox(height: 14),
          if (group.copies.isEmpty)
            Text(
              _tr(context, 'No physical copies are available'),
              style: TextStyle(color: tokens.textSecondary),
            ),
          for (var i = 0; i < group.copies.length; i++) ...[
            if (i > 0) const SizedBox(height: 9),
            _ReleaseCopyRow(
              copy: group.copies[i],
              coreConnected: coreConnected,
            ),
          ],
        ],
      ),
    );
  }
}

class _ReleaseCopyRow extends StatelessWidget {
  const _ReleaseCopyRow({required this.copy, required this.coreConnected});
  final Map<String, dynamic> copy;
  final bool coreConnected;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final presence = replicaPresence(copy, coreConnected: coreConnected);
    final available = presence == 'available';
    final color = available ? tokens.playing : tokens.textSecondary;
    final format =
        (copy['extension'] ?? copy['container'] ?? copy['codec'] ?? '')
            .toString()
            .toUpperCase();
    final path = (copy['relative_path'] ?? copy['file_path'] ?? '').toString();
    return Tooltip(
      message: path,
      child: Wrap(
        spacing: 7,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  available
                      ? Icons.check_circle_outline
                      : Icons.cloud_off_outlined,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '${copy['device_name'] ?? _tr(context, 'Unknown device')} · ${_tr(context, available
                        ? 'Available'
                        : presence == 'offline'
                        ? 'Offline'
                        : 'Missing')}',
                    style: TextStyle(color: color, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (format.isNotEmpty)
            _TrackMetaPill(icon: Icons.audio_file_outlined, label: format),
          if (_audioResolutionLabel(copy) case final resolution?)
            _TrackMetaPill(icon: Icons.graphic_eq, label: resolution),
          if (_audioBitrateLabel(copy) case final bitrate?)
            _TrackMetaPill(icon: Icons.speed_outlined, label: bitrate),
          if (_formatBytes(copy['size_bytes']).isNotEmpty)
            _TrackMetaPill(
              icon: Icons.data_usage_outlined,
              label: _formatBytes(copy['size_bytes']),
            ),
        ],
      ),
    );
  }
}

String? _audioResolutionLabel(Map<String, dynamic> variant) {
  final bitDepth = _intValue(variant['bit_depth']);
  final sampleRate = _intValue(variant['sample_rate']);
  if (bitDepth == null && sampleRate == null) {
    return null;
  }
  final sampleRateLabel = sampleRate == null
      ? null
      : sampleRate >= 1000
      ? '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz'
      : '$sampleRate Hz';
  return _joinParts([if (bitDepth != null) '$bitDepth-bit', sampleRateLabel]);
}

String? _audioBitrateLabel(Map<String, dynamic> variant) {
  final bitrate = _intValue(variant['bitrate']);
  if (bitrate == null || bitrate <= 0) {
    return null;
  }
  return '${(bitrate / 1000).round()} kbps';
}
