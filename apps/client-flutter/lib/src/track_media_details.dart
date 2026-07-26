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

class _MediaIdentityChip extends StatelessWidget {
  const _MediaIdentityChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _MediaVariantRow extends StatelessWidget {
  const _MediaVariantRow({
    required this.variant,
    required this.legacyReplica,
    required this.localCopy,
  });

  final Map<String, dynamic> variant;
  final Map<String, dynamic>? legacyReplica;
  final Map<String, dynamic>? localCopy;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final master = _asMap(variant['master']);
    final replicas = (variant['replicas'] as List? ?? const [])
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList();
    final variantId = _intValue(variant['id']);
    final localVariantId = _intValue(localCopy?['media_variant_id']);
    if (legacyReplica != null) {
      final legacyFileId = _intValue(legacyReplica!['file_id']);
      final match = replicas.indexWhere(
        (replica) => _intValue(replica['file_id']) == legacyFileId,
      );
      if (match >= 0) {
        replicas[match] = <String, dynamic>{
          ...legacyReplica!,
          ...replicas[match],
        };
      }
    }
    if (localCopy != null &&
        (variantId == null ||
            localVariantId == null ||
            variantId == localVariantId) &&
        !replicas.any(
          (replica) =>
              replica['client_file_id']?.toString() ==
              localCopy!['client_file_id']?.toString(),
        )) {
      replicas.add(localCopy!);
    }
    if (legacyReplica != null &&
        !replicas.any(
          (replica) =>
              _intValue(replica['file_id']) ==
              _intValue(legacyReplica!['file_id']),
        )) {
      replicas.insert(0, legacyReplica!);
    }
    final format = _joinParts([
      variant['codec']?.toString().toUpperCase(),
      _audioResolutionLabel(variant),
      _audioBitrateLabel(variant),
    ]);
    final masterLabel = _joinParts([
      master['label'],
      master['mastering_kind'] == 'unknown' ? null : master['mastering_kind'],
    ]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: tokens.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                variant['is_preferred'] == true
                    ? Icons.high_quality_outlined
                    : Icons.audio_file_outlined,
                color: tokens.accent,
                size: 21,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    format.isEmpty ? _tr(context, 'Available files') : format,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (masterLabel.isNotEmpty)
                    Text(
                      masterLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            if (variant['is_preferred'] == true)
              _TrackMetaPill(
                icon: Icons.check_circle_outline,
                label: _tr(context, 'Preferred'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (replicas.isEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceRaised.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: tokens.stroke),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_outlined, color: tokens.textSecondary),
                  const SizedBox(width: 9),
                  Text(_tr(context, 'No physical copies are available')),
                ],
              ),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth >= 720
                  ? (constraints.maxWidth - 10) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: replicas
                    .map(
                      (replica) => SizedBox(
                        width: width,
                        child: _MediaReplicaCard(
                          replica: replica,
                          variant: variant,
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),
      ],
    );
  }
}

class _MediaReplicaCard extends StatelessWidget {
  const _MediaReplicaCard({required this.replica, required this.variant});

  final Map<String, dynamic> replica;
  final Map<String, dynamic> variant;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final available = replica['availability_state']?.toString() == 'ready';
    Object? value(String key) => replica[key] ?? variant[key];
    final codec = <String>{
      for (final candidate in [
        value('container'),
        value('extension'),
        value('codec'),
      ])
        if ((candidate?.toString().trim() ?? '').isNotEmpty)
          candidate!.toString().trim().toUpperCase(),
    }.join(' · ');
    final resolution = _audioResolutionLabel(<String, dynamic>{
      'bit_depth': value('bit_depth'),
      'sample_rate': value('sample_rate'),
    });
    final bitrate = _audioBitrateLabel(<String, dynamic>{
      'bitrate': value('bitrate'),
    });
    final channels = _intValue(value('channels'));
    final modified = _compactMediaDate(replica['modified_at']);
    final verified = _compactMediaDate(replica['last_verified_at']);
    final path =
        replica['relative_path']?.toString() ??
        replica['file_path']?.toString() ??
        '';
    final facts = <(IconData, String)>[
      if (codec.isNotEmpty) (Icons.audio_file_outlined, codec),
      if (resolution != null) (Icons.graphic_eq, resolution),
      if (bitrate != null) (Icons.speed_outlined, bitrate),
      if (channels != null)
        (
          Icons.surround_sound_outlined,
          channels == 1
              ? _tr(context, 'Mono')
              : channels == 2
              ? _tr(context, 'Stereo')
              : '$channels ch',
        ),
      if (_formatBytes(replica['size_bytes']).isNotEmpty)
        (Icons.data_usage_outlined, _formatBytes(replica['size_bytes'])),
      if (modified.isNotEmpty) (Icons.update_outlined, modified),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: available
              ? tokens.playing.withValues(alpha: 0.34)
              : tokens.stroke,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: (available ? tokens.playing : tokens.textSecondary)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    replica['source_kind']?.toString() == 'core'
                        ? Icons.dns_outlined
                        : Icons.devices_outlined,
                    size: 18,
                    color: available ? tokens.playing : tokens.textSecondary,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        replica['device_name']?.toString() ??
                            _tr(
                              context,
                              replica['source_kind']?.toString() == 'core'
                                  ? 'Core local'
                                  : 'Unknown device',
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _tr(
                          context,
                          replica['source_kind']?.toString() == 'core'
                              ? 'Core library'
                              : 'Device library',
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                _AvailabilityBadge(available: available),
              ],
            ),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: facts
                    .map((fact) => _ReplicaFact(icon: fact.$1, label: fact.$2))
                    .toList(growable: false),
              ),
            ],
            if (path.isNotEmpty) ...[
              const SizedBox(height: 11),
              Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Tooltip(
                      message: path,
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (verified.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '${_tr(context, 'Verified')} $verified',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AvailabilityBadge extends StatelessWidget {
  const _AvailabilityBadge({required this.available});

  final bool available;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    final color = available ? tokens.playing : tokens.textSecondary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              available ? Icons.check_circle : Icons.cloud_off_outlined,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              _tr(context, available ? 'Ready' : 'Unavailable'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplicaFact extends StatelessWidget {
  const _ReplicaFact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = IntMusicTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: tokens.textSecondary),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

String _compactMediaDate(Object? value) {
  final raw = value?.toString() ?? '';
  final date = DateTime.tryParse(raw)?.toLocal();
  if (date == null) return '';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

String _recordingKindLabel(BuildContext context, String? kind) {
  return switch (kind) {
    'live' => _tr(context, 'Live recording'),
    'acoustic' => _tr(context, 'Acoustic recording'),
    'demo' => _tr(context, 'Demo recording'),
    _ => _tr(context, 'Studio recording'),
  };
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
