/// Release identity comes from the catalog, never from file format or device.
class ReleaseMediaGroup {
  ReleaseMediaGroup(this.identity, this.release);
  final int identity;
  Map<String, dynamic> release;
  final List<Map<String, dynamic>> tracks = [];
  final List<Map<String, dynamic>> copies = [];
  bool get isCurrent => tracks.any((t) => t['is_current'] == true);
  int? get trackId =>
      tracks.map((t) => t['legacy_track_id']).whereType<int>().firstOrNull;
}

List<ReleaseMediaGroup> groupReleaseMedia(
  Map<String, dynamic> media, {
  Map<String, dynamic>? localCopy,
}) {
  final groups = <int, ReleaseMediaGroup>{};
  final byTrack = <int, ReleaseMediaGroup>{};
  for (final raw in (media['related_release_tracks'] as List? ?? const [])) {
    final track = Map<String, dynamic>.from(raw as Map);
    final identity = track['release_identity_id'];
    final id = track['release_track_id'];
    if (identity is! int || id is! int) continue;
    final release = Map<String, dynamic>.from(track['release'] as Map? ?? {});
    final group = groups.putIfAbsent(
      identity,
      () => ReleaseMediaGroup(identity, release),
    );
    if (group.release['year'] == null && release['year'] != null) {
      group.release = release;
    }
    group.tracks.add(track);
    byTrack[id] = group;
  }
  for (final raw in (media['variants'] as List? ?? const [])) {
    final variant = Map<String, dynamic>.from(raw as Map);
    final destinations = <ReleaseMediaGroup>{
      for (final id in (variant['release_track_ids'] as List? ?? const []))
        ?byTrack[id],
    };
    final replicas = [
      for (final replica in (variant['replicas'] as List? ?? const []))
        Map<String, dynamic>.from(replica as Map),
    ];
    // Only a verified exact binding can attach a local copy to an edition.
    if (localCopy != null && localCopy['media_variant_id'] == variant['id']) {
      replicas.removeWhere(
        (r) =>
            localCopy['client_file_id'] != null &&
            localCopy['device_id'] != null &&
            r['device_id'] == localCopy['device_id'] &&
            r['root_external_id'] == localCopy['root_external_id'] &&
            r['client_file_id'] == localCopy['client_file_id'],
      );
      replicas.add(localCopy);
    }
    for (final group in destinations) {
      for (final replica in replicas) {
        if (group.copies.any(
          (r) =>
              replica['file_id'] != null && r['file_id'] == replica['file_id'],
        )) {
          continue;
        }
        group.copies.add({...variant, ...replica});
      }
    }
  }
  return groups.values.toList()..sort((a, b) {
    if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
    return (a.release['title']?.toString() ?? '').compareTo(
      b.release['title']?.toString() ?? '',
    );
  });
}

String replicaPresence(
  Map<String, dynamic> copy, {
  required bool coreConnected,
  DateTime? now,
}) {
  if (copy['availability_state'] != 'ready') return 'missing';
  if (copy['local_verified'] == true) return 'available';
  if (!coreConnected) return 'offline';
  if (copy['source_kind'] == 'core') {
    return copy['presence_state'] == 'available' ? 'available' : 'missing';
  }
  final until = DateTime.tryParse(copy['online_until']?.toString() ?? '');
  return until != null && until.isAfter(now ?? DateTime.now())
      ? 'available'
      : 'offline';
}
