import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Device-owned records have stable negative IDs until Core assigns a binding.
/// A failed upload must not make an already inspected file disappear locally.
int localLibraryId(String key) =>
    -1 -
    int.parse(
      sha256.convert(utf8.encode(key)).toString().substring(0, 12),
      radix: 16,
    );

Map<String, dynamic> localFileTrack(Map<String, dynamic> copy) {
  final metadata = Map<String, dynamic>.from(copy['metadata'] as Map? ?? {});
  final artists = (metadata['track_artists'] as List? ?? [])
      .map((v) => v.toString())
      .toList();
  final album = metadata['album']?.toString() ?? '';
  final title = metadata['title']?.toString().trim();
  final path = copy['relative_path']?.toString() ?? '';
  final id = copy['track_id'] as int;
  return {
    'id': id,
    'release_identity_id': id,
    'recording_id': id,
    'title': title?.isNotEmpty == true
        ? title
        : path.replaceAll('\\', '/').split('/').last,
    'artist_display': artists.join(' / '),
    'artists': artists,
    'artist_ids': artists
        .map((name) => localLibraryId('artist:$name'))
        .toList(),
    'album_title': album,
    'album_id': localLibraryId('album:$album:${artists.join('|')}'),
    'duration_ms': metadata['duration_ms'] ?? 0,
    'track_number': metadata['track_number'],
    'disc_number': metadata['disc_number'],
    'year': metadata['year'],
    'genres': metadata['genres'] ?? [],
    'is_favorite': copy['is_favorite'] == true,
    'play_count': copy['play_count'] ?? 0,
    'is_available': true,
    'display_mode': 'inherit',
    'added_at': copy['modified_at'],
    'size_bytes': copy['size_bytes'],
    'local_file': true,
  };
}

/// A verified device file already has enough information for its edition card.
Map<String, dynamic> localFileMedia(
  Map<String, dynamic> track,
  Map<String, dynamic> copy,
) {
  final release = track['release_identity_id'] ?? track['id'];
  return {
    'related_release_tracks': [
      {
        'release_identity_id': release,
        'release_track_id': release,
        'legacy_track_id': track['id'],
        'is_current': true,
        'release': {'title': track['album_title'], 'year': track['year']},
      },
    ],
    'variants': [
      {
        'id': copy['media_variant_id'],
        'release_track_ids': [release],
        'replicas': [copy],
      },
    ],
  };
}
