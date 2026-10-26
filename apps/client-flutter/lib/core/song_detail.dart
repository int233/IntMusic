/// The detail page is a song family, independent of list presentation settings.
/// Only the catalog's artist/title identity can join editions; file copies do
/// not create new editions, and missing identity never joins unrelated tracks.
List<Map<String, dynamic>> songDetailEditions(
  Map<String, dynamic> selected,
  Iterable<dynamic> catalog,
) {
  Object identity(Map track) =>
      track['release_identity_id'] ?? 'track:${track['id']}';
  final key = selected['display_group_key'];
  final editions = <Object, Map<String, dynamic>>{identity(selected): selected};
  if (key is String && key.isNotEmpty) {
    for (final value in catalog.whereType<Map>()) {
      if (value['display_group_key'] == key) {
        editions.putIfAbsent(
          identity(value),
          () => Map<String, dynamic>.from(value),
        );
      }
    }
  }
  final rest = editions.values.skip(1).toList()
    ..sort((a, b) {
      final year = (a['year'] as int? ?? 0).compareTo(b['year'] as int? ?? 0);
      return year != 0
          ? year
          : '${a['album_title']}'.compareTo('${b['album_title']}');
    });
  return [selected, ...rest];
}
