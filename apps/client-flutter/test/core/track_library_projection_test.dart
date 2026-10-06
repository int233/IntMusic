import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:intmusic_client/core/track_library_projection.dart';

void main() {
  test(
    'large catalog sorting and filtering preserve release grouping',
    () async {
      final tracks = List.generate(
        6000,
        (id) => <String, dynamic>{
          'id': id,
          'title': 'Song ${id.toString().padLeft(4, '0')}',
          'artist_display': 'Artist',
          'display_group_key': 'song-${id ~/ 2}',
          'display_mode': 'inherit',
          'is_available': true,
        },
      );
      final input = <String, dynamic>{
        'tracks': tracks.reversed.toList(),
        'query': '',
        'sort': 'title',
        'merge': true,
      };
      final grouped = await compute(projectTrackLibrary, input);
      expect(grouped.length, 3000);
      expect(grouped.first['id'], 0);
      expect((grouped.first['_display_members'] as List).length, 2);
      expect(
        projectTrackLibrary({...input, 'query': 'Song 1234'}).single['id'],
        1234,
      );
      expect(tracks.first.containsKey('_display_members'), isFalse);
    },
  );
}
