import 'song_display.dart';

/// Runs in a worker isolate for large catalogs, outside Flutter's frame loop.
List<Map<String, dynamic>> projectTrackLibrary(Map<String, dynamic> input) {
  final query = (input['query'] as String).trim().toLowerCase();
  final sort = input['sort'] as String;
  final tracks = (input['tracks'] as List).cast<Map<String, dynamic>>().where((
    t,
  ) {
    return query.isEmpty ||
        '${t['title']} ${t['artist_display']} ${t['album_title']} ${t['genres']} ${songDisplayModeLabel(t['display_mode'])} ${t['display_mode'] ?? 'inherit'}'
            .toLowerCase()
            .contains(query);
  }).toList();
  String key(Map<String, dynamic> t) => switch (sort) {
    'artist' => '${t['artist_display'] ?? ''}\u0000${t['title'] ?? ''}',
    'album' => '${t['album_title'] ?? ''}\u0000${t['disc_number'] ?? ''}',
    _ => '${t['title'] ?? ''}',
  };
  final keys = {for (final t in tracks) t: key(t).toLowerCase()};
  tracks.sort((a, b) {
    if (sort == 'duration') {
      final duration = (num.tryParse('${b['duration_ms']}') ?? 0).compareTo(
        num.tryParse('${a['duration_ms']}') ?? 0,
      );
      if (duration != 0) return duration;
    }
    return keys[a]!.compareTo(keys[b]!);
  });
  return projectSongList(
    tracks,
    mergeSameName: input['merge'] == true,
    filter: input['filter'] as String? ?? 'all',
    sortByMode: input['sortByMode'] == true,
  );
}
