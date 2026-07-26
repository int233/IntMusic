part of '../intmusic_client.dart';

class _OfflineTrackCopy {
  const _OfflineTrackCopy({
    required this.trackId,
    required this.mediaVariantId,
    required this.rootExternalId,
    required this.fileExternalId,
    required this.relativePath,
    required this.extension,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.metadata,
    this.isFavorite = false,
    this.playCount = 0,
  });

  factory _OfflineTrackCopy.fromJson(Map<String, dynamic> json) {
    return _OfflineTrackCopy(
      trackId: _intValue(json['track_id']) ?? 0,
      mediaVariantId: _intValue(json['media_variant_id']) ?? 0,
      rootExternalId: json['root_external_id']?.toString() ?? '',
      fileExternalId: json['file_external_id']?.toString() ?? '',
      relativePath: json['relative_path']?.toString() ?? '',
      extension: json['extension']?.toString() ?? '',
      sizeBytes: _intValue(json['size_bytes']) ?? 0,
      modifiedAt:
          DateTime.tryParse(json['modified_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      metadata:
          (json['metadata'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      isFavorite: json['is_favorite'] == true,
      playCount: _intValue(json['play_count']) ?? 0,
    );
  }

  final int trackId;
  final int mediaVariantId;
  final String rootExternalId;
  final String fileExternalId;
  final String relativePath;
  final String extension;
  final int sizeBytes;
  final DateTime modifiedAt;
  final Map<String, dynamic> metadata;
  final bool isFavorite;
  final int playCount;

  String get copyKey => '$rootExternalId\u0000$fileExternalId';

  _OfflineTrackCopy copyWith({
    bool? isFavorite,
    int? playCount,
    int? durationMs,
  }) {
    return _OfflineTrackCopy(
      trackId: trackId,
      mediaVariantId: mediaVariantId,
      rootExternalId: rootExternalId,
      fileExternalId: fileExternalId,
      relativePath: relativePath,
      extension: extension,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      metadata: durationMs == null
          ? metadata
          : <String, dynamic>{...metadata, 'duration_ms': durationMs},
      isFavorite: isFavorite ?? this.isFavorite,
      playCount: playCount ?? this.playCount,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'track_id': trackId,
    'media_variant_id': mediaVariantId,
    'root_external_id': rootExternalId,
    'file_external_id': fileExternalId,
    'relative_path': relativePath,
    'extension': extension,
    'size_bytes': sizeBytes,
    'modified_at': modifiedAt.toUtc().toIso8601String(),
    'metadata': metadata,
    'is_favorite': isFavorite,
    'play_count': playCount,
  };

  Map<String, dynamic> toTrackSummary() {
    final artists = (metadata['track_artists'] as List?)
        ?.map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    return <String, dynamic>{
      'id': trackId,
      'file_id': -trackId.abs(),
      'album_id': _offlineEntityId(
        'album',
        '${metadata['album'] ?? ''}\u0000${artists?.join(';') ?? ''}',
      ),
      'title': metadata['title']?.toString() ?? _filenameWithoutExtension(),
      'artist_display': artists?.join(', '),
      'album_title': metadata['album']?.toString(),
      'disc_number': _intValue(metadata['disc_number']),
      'track_number': _intValue(metadata['track_number']),
      'duration_ms': _intValue(metadata['duration_ms']),
      'year': _intValue(metadata['year']),
      'cover_asset_id': null,
      'is_favorite': isFavorite,
      'user_rating': isFavorite ? 100 : null,
      'tag_rating': null,
      'tag_rating_scale': null,
      'effective_rating': isFavorite ? 100 : null,
      'size_bytes': sizeBytes,
      'added_at': modifiedAt.toUtc().toIso8601String(),
      'play_count': playCount,
      '_offline': true,
    };
  }

  Map<String, dynamic> toTrackDetail(String localPath) {
    return <String, dynamic>{
      'track': toTrackSummary(),
      'file_path': localPath,
      'relative_path': relativePath,
      'extension': extension,
      'size_bytes': sizeBytes,
      'modified_at': modifiedAt.toUtc().toIso8601String(),
      'scan_status': 'offline_ready',
      'genres': (metadata['genres'] as List?) ?? const [],
      'composers': (metadata['composers'] as List?) ?? const [],
      'lyricists': (metadata['lyricists'] as List?) ?? const [],
      'lyrics': null,
      'media': null,
    };
  }

  String _filenameWithoutExtension() {
    final name = relativePath.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

class _OfflineMutation {
  const _OfflineMutation({
    required this.id,
    required this.kind,
    required this.trackId,
    required this.occurredAt,
    required this.payload,
  });

  factory _OfflineMutation.fromJson(Map<String, dynamic> json) {
    return _OfflineMutation(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      trackId: _intValue(json['track_id']) ?? 0,
      occurredAt:
          DateTime.tryParse(json['occurred_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      payload:
          (json['payload'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  final String id;
  final String kind;
  final int trackId;
  final DateTime occurredAt;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind,
    'track_id': trackId,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'payload': payload,
  };
}

class _OfflineLibrarySnapshot {
  _OfflineLibrarySnapshot({
    this.serverId,
    Map<String, _OfflineTrackCopy>? copies,
    List<_OfflineMutation>? outbox,
  }) : copies = copies ?? <String, _OfflineTrackCopy>{},
       outbox = outbox ?? <_OfflineMutation>[];

  factory _OfflineLibrarySnapshot.fromJson(Map<String, dynamic> json) {
    final copies = <String, _OfflineTrackCopy>{};
    for (final value in (json['copies'] as List?) ?? const []) {
      if (value is! Map) continue;
      final copy = _OfflineTrackCopy.fromJson(value.cast<String, dynamic>());
      if (copy.trackId > 0 &&
          copy.rootExternalId.isNotEmpty &&
          copy.fileExternalId.isNotEmpty) {
        copies[copy.copyKey] = copy;
      }
    }
    final outbox = <_OfflineMutation>[];
    for (final value in (json['outbox'] as List?) ?? const []) {
      if (value is! Map) continue;
      final mutation = _OfflineMutation.fromJson(value.cast<String, dynamic>());
      if (mutation.id.isNotEmpty &&
          mutation.kind.isNotEmpty &&
          mutation.trackId > 0) {
        outbox.add(mutation);
      }
    }
    return _OfflineLibrarySnapshot(
      serverId: json['server_id']?.toString(),
      copies: copies,
      outbox: outbox,
    );
  }

  String? serverId;
  final Map<String, _OfflineTrackCopy> copies;
  final List<_OfflineMutation> outbox;

  Iterable<_OfflineTrackCopy> get distinctTracks {
    final byTrack = <int, _OfflineTrackCopy>{};
    for (final copy in copies.values) {
      byTrack.putIfAbsent(copy.trackId, () => copy);
    }
    return byTrack.values;
  }

  _OfflineTrackCopy? track(int trackId) {
    for (final copy in copies.values) {
      if (copy.trackId == trackId) return copy;
    }
    return null;
  }

  void upsert(_OfflineTrackCopy copy) {
    copies[copy.copyKey] = copy;
  }

  void retainRootFiles(String rootExternalId, Set<String> externalIds) {
    copies.removeWhere(
      (_, copy) =>
          copy.rootExternalId == rootExternalId &&
          !externalIds.contains(copy.fileExternalId),
    );
  }

  void setFavorite(int trackId, bool favorite) {
    for (final entry in copies.entries.toList(growable: false)) {
      if (entry.value.trackId == trackId) {
        copies[entry.key] = entry.value.copyWith(isFavorite: favorite);
      }
    }
  }

  void incrementPlayCount(int trackId) {
    for (final entry in copies.entries.toList(growable: false)) {
      if (entry.value.trackId == trackId) {
        copies[entry.key] = entry.value.copyWith(
          playCount: entry.value.playCount + 1,
        );
      }
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'server_id': serverId,
    'copies': copies.values
        .map((copy) => copy.toJson())
        .toList(growable: false),
    'outbox': outbox
        .map((mutation) => mutation.toJson())
        .toList(growable: false),
  };
}

class _OfflineLibraryStore {
  static Future<void> _writeQueue = Future<void>.value();

  static Future<File> _snapshotFile() async {
    final directory = await getApplicationSupportDirectory();
    final storage = Directory(
      '${directory.path}${Platform.pathSeparator}offline',
    );
    await storage.create(recursive: true);
    return File('${storage.path}${Platform.pathSeparator}library-v1.json');
  }

  static Future<_OfflineLibrarySnapshot> load() async {
    try {
      final file = await _snapshotFile();
      if (!await file.exists()) return _OfflineLibrarySnapshot();
      final value = jsonDecode(await file.readAsString());
      return value is Map
          ? _OfflineLibrarySnapshot.fromJson(value.cast<String, dynamic>())
          : _OfflineLibrarySnapshot();
    } catch (_) {
      return _OfflineLibrarySnapshot();
    }
  }

  static Future<void> save(_OfflineLibrarySnapshot snapshot) {
    final encoded = jsonEncode(snapshot.toJson());
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      final file = await _snapshotFile();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
    });
    return _writeQueue;
  }
}

int _offlineEntityId(String type, String value) {
  final digest = sha256.convert(utf8.encode('$type\u0000$value')).bytes;
  var number = 0;
  for (var index = 0; index < 7; index += 1) {
    number = (number << 8) | digest[index];
  }
  return -max(1, number & 0x1fffffffffffff);
}

String _newClientMutationId() {
  final random = Random.secure();
  final suffix = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return 'mutation-$suffix';
}

List<dynamic> _offlineTrackSummaries(_OfflineLibrarySnapshot snapshot) {
  final tracks = snapshot.distinctTracks
      .map((copy) => copy.toTrackSummary())
      .toList(growable: false);
  tracks.sort(
    (left, right) => (left['title']?.toString() ?? '').toLowerCase().compareTo(
      (right['title']?.toString() ?? '').toLowerCase(),
    ),
  );
  return tracks;
}

List<dynamic> _offlineAlbumSummaries(_OfflineLibrarySnapshot snapshot) {
  final groups = <int, List<_OfflineTrackCopy>>{};
  for (final copy in snapshot.distinctTracks) {
    final summary = copy.toTrackSummary();
    final albumId = _intValue(summary['album_id']);
    if (albumId != null) {
      groups.putIfAbsent(albumId, () => <_OfflineTrackCopy>[]).add(copy);
    }
  }
  final albums = groups.entries
      .map((entry) {
        final first = entry.value.first;
        final artists = (first.metadata['album_artists'] as List?)
            ?.map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .join(', ');
        return <String, dynamic>{
          'id': entry.key,
          'title': first.metadata['album']?.toString() ?? 'Unknown album',
          'album_artist_display': artists,
          'date': first.metadata['date']?.toString(),
          'year': _intValue(first.metadata['year']),
          'total_discs': _intValue(first.metadata['disc_total']),
          'track_count': entry.value.length,
          'cover_asset_id': null,
          '_offline': true,
        };
      })
      .toList(growable: false);
  albums.sort(
    (left, right) => (left['title']?.toString() ?? '').toLowerCase().compareTo(
      (right['title']?.toString() ?? '').toLowerCase(),
    ),
  );
  return albums;
}

List<dynamic> _offlineArtistSummaries(_OfflineLibrarySnapshot snapshot) {
  final tracksByArtist = <String, Set<int>>{};
  final albumsByArtist = <String, Set<int>>{};
  for (final copy in snapshot.distinctTracks) {
    final summary = copy.toTrackSummary();
    final artists = (copy.metadata['track_artists'] as List?)
        ?.map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty);
    for (final artist in artists ?? const <String>[]) {
      tracksByArtist.putIfAbsent(artist, () => <int>{}).add(copy.trackId);
      final albumId = _intValue(summary['album_id']);
      if (albumId != null) {
        albumsByArtist.putIfAbsent(artist, () => <int>{}).add(albumId);
      }
    }
  }
  final artists = tracksByArtist.entries
      .map((entry) {
        return <String, dynamic>{
          'id': _offlineEntityId('artist', entry.key),
          'name': entry.key,
          'sort_name': entry.key,
          'track_count': entry.value.length,
          'album_count': albumsByArtist[entry.key]?.length ?? 0,
          'artwork_revision': 0,
          'has_artwork': false,
          '_offline': true,
        };
      })
      .toList(growable: false);
  artists.sort(
    (left, right) => (left['name']?.toString() ?? '').toLowerCase().compareTo(
      (right['name']?.toString() ?? '').toLowerCase(),
    ),
  );
  return artists;
}

Map<String, dynamic>? _offlineAlbumDetail(
  _OfflineLibrarySnapshot snapshot,
  int albumId,
) {
  final album = _offlineAlbumSummaries(snapshot)
      .whereType<Map>()
      .map((value) => value.cast<String, dynamic>())
      .where((value) => _intValue(value['id']) == albumId);
  if (album.isEmpty) return null;
  final tracks = snapshot.distinctTracks
      .map((copy) => copy.toTrackSummary())
      .where((track) => _intValue(track['album_id']) == albumId)
      .toList(growable: false);
  tracks.sort((left, right) {
    final disc = (_intValue(left['disc_number']) ?? 1).compareTo(
      _intValue(right['disc_number']) ?? 1,
    );
    if (disc != 0) return disc;
    return (_intValue(left['track_number']) ?? 0).compareTo(
      _intValue(right['track_number']) ?? 0,
    );
  });
  return <String, dynamic>{'album': album.first, 'tracks': tracks};
}

Map<String, dynamic>? _offlineArtistDetail(
  _OfflineLibrarySnapshot snapshot,
  int artistId,
) {
  final artists = _offlineArtistSummaries(snapshot)
      .whereType<Map>()
      .map((value) => value.cast<String, dynamic>())
      .where((value) => _intValue(value['id']) == artistId);
  if (artists.isEmpty) return null;
  final artist = artists.first;
  final name = artist['name']?.toString() ?? '';
  final copies = snapshot.distinctTracks
      .where((copy) {
        return ((copy.metadata['track_artists'] as List?) ?? const []).any(
          (value) => value.toString() == name,
        );
      })
      .toList(growable: false);
  final albumIds = copies
      .map((copy) => _intValue(copy.toTrackSummary()['album_id']))
      .whereType<int>()
      .toSet();
  final albums = _offlineAlbumSummaries(snapshot)
      .whereType<Map>()
      .map((value) => value.cast<String, dynamic>())
      .where((value) => albumIds.contains(_intValue(value['id'])));
  return <String, dynamic>{
    'artist': artist,
    'profile': <String, dynamic>{
      'display_name': name,
      'sort_name': name,
      'aliases': const <String>[],
      'genres': const <String>[],
      'links': const <dynamic>[],
    },
    'assets': const <dynamic>[],
    'visuals': const <dynamic>[],
    'albums': albums.toList(growable: false),
    'tracks': copies
        .map((copy) => copy.toTrackSummary())
        .toList(growable: false),
  };
}

String? _offlineCopyPath(
  _OfflineTrackCopy copy,
  List<_ClientLibraryRoot> roots,
) {
  final root = roots
      .where((value) => value.externalId == copy.rootExternalId)
      .firstOrNull;
  if (root == null) return null;
  final segments = copy.relativePath
      .replaceAll('\\', '/')
      .split('/')
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (segments.any((value) => value == '..')) return null;
  return <String>[root.path, ...segments].join(Platform.pathSeparator);
}
