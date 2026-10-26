import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/collection_sources.dart';

void main() {
  test(
    'source rules use labelled numeric roots and exclude retired sources',
    () {
      final options = collectionSourceOptionsFromDevices([
        {
          'device_id': 'mac',
          'display_name': 'Mac',
          'sources': [
            {'root_id': 10, 'display_name': 'Music', 'state': 'offline'},
            {'root_id': 11, 'display_name': 'Old', 'state': 'retired'},
            {'display_name': 'Unregistered'},
          ],
        },
        {
          'device_id': 'phone',
          'sources': [
            {'root_id': 12},
          ],
        },
      ]);
      expect(options.map((s) => s['id']), [10, 12]);
      expect(options.first['label'], 'Mac · Music');
      expect(options.last['label'], 'Unknown device · Music source');
      expect(options.first['state'], 'offline');
    },
  );

  test('same-named roots on one device show distinct paths', () {
    final options = collectionSourceOptionsFromDevices([
      {
        'device_id': 'phone',
        'display_name': 'Mate80PM',
        'sources': [
          {
            'root_id': 10,
            'display_name': 'Music',
            'path_hint': '/storage/emulated/0/Music',
          },
          {
            'root_id': 15,
            'display_name': 'Music',
            'path_hint': '/storage/39E1-8C80/Music',
          },
        ],
      },
    ]);
    expect(options.first['label'], 'Mate80PM · /storage/emulated/0/Music');
    expect(options.last['label'], 'Mate80PM · /storage/39E1-8C80/Music');
    expect(options.map((value) => value['id']), [10, 15]);
  });
}
