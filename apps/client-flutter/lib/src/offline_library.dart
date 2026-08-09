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
    int? trackId,
    int? mediaVariantId,
    Map<String, dynamic>? metadata,
    bool? isFavorite,
    int? playCount,
    int? durationMs,
  }) {
    return _OfflineTrackCopy(
      trackId: trackId ?? this.trackId,
      mediaVariantId: mediaVariantId ?? this.mediaVariantId,
      rootExternalId: rootExternalId,
      fileExternalId: fileExternalId,
      relativePath: relativePath,
      extension: extension,
      sizeBytes: sizeBytes,
      modifiedAt: modifiedAt,
      metadata: durationMs == null
          ? metadata ?? this.metadata
          : <String, dynamic>{
              ...this.metadata,
              ...?metadata,
              'duration_ms': durationMs,
            },
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
    this.catalogEpoch,
    Map<String, _OfflineTrackCopy>? copies,
    List<_OfflineMutation>? outbox,
  }) : copies = copies ?? <String, _OfflineTrackCopy>{},
       outbox = outbox ?? <_OfflineMutation>[];

  factory _OfflineLibrarySnapshot.fromJson(Map<String, dynamic> json) {
    if ((_intValue(json['version']) ?? 0) < 2) {
      // Development hard reset: pre-epoch track IDs are deliberately not
      // redirected. The saved folder configuration remains available and will
      // submit a fresh manifest after the next Core connection.
      return _OfflineLibrarySnapshot();
    }
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
      catalogEpoch: json['catalog_epoch']?.toString(),
      copies: copies,
      outbox: outbox,
    );
  }

  String? serverId;
  String? catalogEpoch;
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
    'version': 2,
    'server_id': serverId,
    'catalog_epoch': catalogEpoch,
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

String _newClientMutationId() {
  final random = Random.secure();
  final suffix = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return 'mutation-$suffix';
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
