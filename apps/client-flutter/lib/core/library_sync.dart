const libraryDetailKinds = <String>{'track', 'album', 'artist'};

/// Pending local intent remains visible until the Core acknowledges it.
List<dynamic> projectPendingFavorites(
  List<dynamic> tracks,
  Map<int, bool> pending,
) {
  if (pending.isEmpty) return tracks;
  return tracks
      .map((track) {
        if (track is! Map || !pending.containsKey(track['id'])) return track;
        return <String, dynamic>{
          ...track.cast<String, dynamic>(),
          'is_favorite': pending[track['id']],
        };
      })
      .toList(growable: false);
}

/// Logical IDs are meaningful only within this Core catalog.
class CatalogIdentity {
  const CatalogIdentity(this.serverId, this.epoch);

  final String serverId;
  final String epoch;

  bool matches(Map<String, dynamic> response) =>
      serverId.isNotEmpty &&
      epoch.isNotEmpty &&
      response['server_id'] == serverId &&
      response['catalog_epoch'] == epoch;
}

typedef LibrarySyncResult = ({
  Map<String, dynamic>? snapshot,
  Set<String> detailKinds,
});

Future<LibrarySyncResult> fetchLibrarySnapshot({
  required CatalogIdentity identity,
  required int cursor,
  required String deviceId,
  required bool force,
  required Future<Map<String, dynamic>> Function(String path) get,
}) async {
  final kinds = <String>{};
  var coveredCursor = cursor;
  if (force) {
    kinds.addAll(libraryDetailKinds);
  } else {
    final response = await get('/client-sync/changes?after=$cursor&limit=500');
    if (!identity.matches(response)) {
      throw StateError('Core catalog changed during synchronization');
    }
    // An empty page is not proof that the newer high-water mark was read.
    // Changes and the cursor are separate reads, allowing a write between
    // them. Only an unchanged cursor permits skipping the snapshot.
    final changes = (response['changes'] as List?) ?? const [];
    if (response['requires_snapshot'] == false &&
        response['cursor'] == cursor &&
        changes.isEmpty) {
      return (snapshot: null, detailKinds: kinds);
    }
    for (final change in changes.whereType<Map>()) {
      final value = change['cursor'];
      if (value is int && value > coveredCursor) coveredCursor = value;
      final reason = change['reason']?.toString().toLowerCase() ?? '';
      switch (change['scope']) {
        case 'tracks':
          if (!reason.contains('favorite') && !reason.contains('mutation')) {
            kinds.addAll(libraryDetailKinds);
          }
        case 'albums':
          kinds.add('album');
        case 'artists':
          kinds.add('artist');
        case 'collections':
          break;
        default:
          kinds.addAll(libraryDetailKinds);
      }
    }
    if (changes.isEmpty) kinds.addAll(libraryDetailKinds);
  }
  final snapshot = await get(
    '/client-sync/snapshot?device_id=${Uri.encodeQueryComponent(deviceId)}',
  );
  if (!identity.matches(snapshot)) {
    throw StateError('Core catalog changed during synchronization');
  }
  for (final key in const [
    'tracks',
    'albums',
    'artists',
    'collections',
    'library_roots',
    'client_library_roots',
    'client_file_bindings',
    'playback_history',
  ]) {
    if (snapshot[key] is! List) {
      throw FormatException('Missing library snapshot list: $key');
    }
  }
  for (final key in const ['settings', 'playback_stats']) {
    if (snapshot[key] is! Map) {
      throw FormatException('Missing library snapshot object: $key');
    }
  }
  final nextCursor = snapshot['cursor'];
  if (nextCursor is! int || nextCursor < 0) {
    throw const FormatException('Invalid library snapshot cursor');
  }
  // A snapshot can include changes beyond the limited change page (or writes
  // concurrent with it). Their scopes are unknown, so refresh every detail.
  if (nextCursor != coveredCursor) kinds.addAll(libraryDetailKinds);
  return (snapshot: snapshot, detailKinds: kinds);
}

/// Returns false on suspension without declaring the unfinished scope complete.
Future<bool> syncLibraryDetailPages({
  required int afterId,
  required bool Function() canContinue,
  required Future<Map<String, dynamic>> Function(int afterId) load,
  required Future<void> Function(Map<String, dynamic> page, int next, bool done)
  save,
}) async {
  while (canContinue()) {
    final page = await load(afterId);
    if (!canContinue()) return false;
    final next = page['next_after_id'];
    final done = page['has_more'] == false;
    if (next is! int ||
        next < afterId ||
        (!done && next <= afterId) ||
        page['has_more'] is! bool) {
      throw const FormatException('Library detail pagination did not advance');
    }
    await save(page, next, done);
    if (!canContinue()) return false;
    if (done) return true;
    afterId = next;
  }
  return false;
}
