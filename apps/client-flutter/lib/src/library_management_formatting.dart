part of '../intmusic_client.dart';

String _libraryFilename(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.isEmpty ? path : parts.last;
}

String _libraryDeviceName(List<dynamic> devices, String id) {
  for (final value in devices.whereType<Map>()) {
    if (value['device_id']?.toString() == id) {
      return value['display_name']?.toString() ?? id;
    }
  }
  return id;
}

String _libraryStatusLabel(BuildContext context, String value) => _tr(
  context,
  const {
        'all': 'All states',
        'available': 'Available',
        'offline': 'Offline',
        'missing': 'Missing',
        'unresolved': 'Unresolved',
        'ignored': 'Ignored',
        'retired': 'Retired',
        'removed': 'Removed',
      }[value] ??
      value,
);

String _libraryStateLabel(BuildContext context, String value) => _tr(
  context,
  const {
        'available': 'Available',
        'offline': 'Offline',
        'missing': 'Missing',
        'retired': 'Retired',
        'removed': 'Removed',
        'online': 'Online',
      }[value] ??
      value,
);

String _libraryMetadataLabel(BuildContext context, String value) => _tr(
  context,
  const {
        'verified': 'Tags verified',
        'manual': 'Manual metadata',
        'legacy_unverified': 'Legacy unverified',
        'missing_required': 'Missing tags',
        'parse_error': 'Tag error',
        'awaiting_rescan': 'Awaiting rescan',
        'ignored': 'Ignored',
      }[value] ??
      value,
);

String _libraryIssueLabel(BuildContext context, String value) => _tr(
  context,
  const {
        'legacy_unverified': 'Legacy unverified metadata',
        'missing_required_tags': 'Missing required tags',
        'tag_parse_error': 'Tag parsing error',
        'rescan_requested': 'Metadata rescan requested',
      }[value] ??
      value,
);

IconData _libraryPresenceIcon(String state) => switch (state) {
  'available' => Icons.check_circle_outline,
  'offline' => Icons.cloud_off_outlined,
  'retired' => Icons.archive_outlined,
  'removed' => Icons.delete_outline,
  _ => Icons.warning_amber_outlined,
};

Color _libraryStateTone(BuildContext context, String state) => switch (state) {
  'available' || 'online' => const Color(0xFF2BAA7B),
  'offline' => const Color(0xFFE5A13A),
  'retired' || 'removed' => IntMusicTheme.of(context).textSecondary,
  _ => Theme.of(context).colorScheme.error,
};

String _librarySampleRate(Object? value) {
  final rate = _intValue(value);
  if (rate == null || rate <= 0) return '-';
  return '${(rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1)} kHz';
}

String _libraryBitrate(Object? value) {
  final bitrate = _intValue(value);
  if (bitrate == null || bitrate <= 0) return '-';
  return '${(bitrate / 1000).round()} kbps';
}

String _libraryDate(Object? value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (date == null) return '-';
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}

String _libraryListText(Object? value) {
  if (value is List) {
    final texts = value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    return texts.isEmpty ? '-' : texts.join('; ');
  }
  return value?.toString() ?? '-';
}
