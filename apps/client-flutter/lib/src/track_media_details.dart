part of '../intmusic_client.dart';

class _TrackLyricsCard extends StatefulWidget {
  const _TrackLyricsCard({
    super.key,
    required this.lyrics,
    required this.album,
  });
  final Map<String, dynamic>? lyrics;
  final String album;
  @override
  State<_TrackLyricsCard> createState() => _TrackLyricsCardState();
}

class _TrackLyricsCardState extends State<_TrackLyricsCard> {
  bool _raw = false;
  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final lyrics = widget.lyrics;
    final original = lyrics?['text']?.toString().trim() ?? '';
    final translation = lyrics?['translation']?.toString().trim() ?? '';
    final pronunciation = lyrics?['pronunciation']?.toString().trim() ?? '';
    Widget section(String label, String text, {bool primary = false}) {
      final body = _raw
          ? text
          : _parseLyricLines(text).map((line) => line.text).join('\n');
      return Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!primary) ...[
              Text(label, style: TextStyle(color: tokens.textSecondary)),
              const SizedBox(height: 8),
            ],
            SelectableText(
              body,
              key: primary ? const Key('song-lyrics-text') : null,
              style: TextStyle(
                fontSize: _raw
                    ? 13
                    : primary
                    ? 18
                    : 14,
                height: 1.9,
                color: tokens.textPrimary,
                fontFamily: _raw ? 'monospace' : null,
              ),
            ),
          ],
        ),
      );
    }

    return _SongDetailPanel(
      title: '歌词',
      trailing: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          ChoiceChip(
            label: const Text('正文'),
            selected: !_raw,
            onSelected: (_) => setState(() => _raw = false),
          ),
          ChoiceChip(
            label: const Text('原始文本'),
            selected: _raw,
            onSelected: (_) => setState(() => _raw = true),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前收录 · ${widget.album}',
            style: TextStyle(color: tokens.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 18),
          if (original.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text('此收录暂无歌词'),
            )
          else ...[
            section('原文', original, primary: true),
            if (translation.isNotEmpty) section('译文', translation),
            if (pronunciation.isNotEmpty) section('发音', pronunciation),
          ],
          if (original.isNotEmpty)
            Text(
              _joinParts([
                lyrics?['kind']?.toString().toUpperCase(),
                lyrics?['language'],
                if (lyrics?['revision'] != null) '修订 ${lyrics!['revision']}',
              ]),
              style: TextStyle(color: tokens.textSecondary, fontSize: 12),
            ),
        ],
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
