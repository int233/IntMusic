import 'package:flutter_test/flutter_test.dart';
import 'package:intmusic_client/core/song_detail.dart';
import 'song_display_test.dart' show song;

void main() {
  test('family ignores display overrides and deduplicates file copies', () {
    final a = song(1, mode: 'independent');
    final b = song(2);
    final copy = {...song(3), 'release_identity_id': 1};
    final otherArtist = song(4, group: 'different artist');
    final result = songDetailEditions(b, [a, b, copy, otherArtist]);
    expect(result.map((t) => t['id']), [2, 1]);
    expect(result.first['album_title'], 'The Eras Tour');
  });
  test('unknown artist/title identity stays a separate song', () {
    final a = song(1, group: null);
    expect(songDetailEditions(a, [song(2, group: null)]), [a]);
  });
}
