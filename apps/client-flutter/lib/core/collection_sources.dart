/// Source rule values are numeric library-root IDs, not device IDs or labels.
List<Map<String, dynamic>> collectionSourceOptionsFromDevices(
  List<dynamic> devices, {
  String unknownDevice = 'Unknown device',
  String unknownSource = 'Music source',
}) {
  String name(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  return [
    for (final device in devices.whereType<Map>())
      for (final source
          in ((device['sources'] as List?) ?? []).whereType<Map>())
        if (source['state'] != 'retired' &&
            int.tryParse('${source['root_id']}') != null)
          {
            'id': int.parse('${source['root_id']}'),
            'device_id': device['device_id'],
            'device_name': name(device['display_name'], unknownDevice),
            'source_name': name(source['display_name'], unknownSource),
            'path_hint': source['path_hint'],
            'label':
                '${name(device['display_name'], unknownDevice)} · ${name(source['path_hint'], name(source['display_name'], unknownSource))}',
            'state': source['state'] ?? 'offline',
            'file_count': source['file_count'] ?? 0,
          },
  ];
}
