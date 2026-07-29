part of '../intmusic_client.dart';

const Set<String> _clientAudioExtensions = <String>{
  'aac',
  'aif',
  'aiff',
  'alac',
  'ape',
  'dsf',
  'flac',
  'm4a',
  'm4b',
  'mp3',
  'mp4',
  'oga',
  'ogg',
  'opus',
  'wav',
  'wave',
  'wma',
};

class _ClientLibraryRoot {
  const _ClientLibraryRoot({
    required this.externalId,
    required this.path,
    required this.displayName,
    this.lastSyncedAt,
    this.fileCount = 0,
    this.lastError,
    this.accessToken,
  });

  factory _ClientLibraryRoot.fromJson(Map<String, dynamic> json) {
    final synced = json['last_synced_at']?.toString();
    return _ClientLibraryRoot(
      externalId: json['external_id']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      lastSyncedAt: synced == null ? null : DateTime.tryParse(synced),
      fileCount: _intValue(json['file_count']) ?? 0,
      lastError: json['last_error']?.toString(),
      accessToken: json['access_token']?.toString(),
    );
  }

  final String externalId;
  final String path;
  final String displayName;
  final DateTime? lastSyncedAt;
  final int fileCount;
  final String? lastError;
  final String? accessToken;

  _ClientLibraryRoot copyWith({
    String? path,
    DateTime? lastSyncedAt,
    int? fileCount,
    String? lastError,
    String? accessToken,
    bool clearError = false,
  }) {
    return _ClientLibraryRoot(
      externalId: externalId,
      path: path ?? this.path,
      displayName: displayName,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      fileCount: fileCount ?? this.fileCount,
      lastError: clearError ? null : lastError ?? this.lastError,
      accessToken: accessToken ?? this.accessToken,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'external_id': externalId,
    'path': path,
    'display_name': displayName,
    'last_synced_at': lastSyncedAt?.toIso8601String(),
    'file_count': fileCount,
    'last_error': lastError,
    'access_token': accessToken,
  };
}

List<_ClientLibraryRoot> _decodeClientLibraryRoots(String? encoded) {
  if (encoded == null || encoded.trim().isEmpty) {
    return const [];
  }
  try {
    final value = jsonDecode(encoded);
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<Map>()
        .map(
          (item) => _ClientLibraryRoot.fromJson(item.cast<String, dynamic>()),
        )
        .where(
          (root) =>
              root.externalId.isNotEmpty &&
              root.path.isNotEmpty &&
              root.displayName.isNotEmpty,
        )
        .toList(growable: false);
  } catch (_) {
    return const [];
  }
}

String _newClientLibraryRootId() {
  final random = Random.secure();
  final suffix = List<int>.generate(
    12,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return 'root-$suffix';
}

String _normalizeLocalRootPath(String path) {
  var normalized = path.trim();
  while (normalized.length > 1 &&
      (normalized.endsWith('/') || normalized.endsWith('\\'))) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String _localRootDisplayName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((part) => part.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

bool _isSupportedClientAudioPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) {
    return false;
  }
  return _clientAudioExtensions.contains(path.substring(dot + 1).toLowerCase());
}

List<Map<String, dynamic>> _clientFileManifestBatch(
  String rootPath,
  List<String> filePaths,
) {
  return filePaths
      .map((path) => _clientFileManifestSync(rootPath, File(path)))
      .toList(growable: false);
}

Future<List<Map<String, dynamic>>> inspectClientFilesInBackground({
  required String rootPath,
  required List<String> filePaths,
}) {
  return compute(_clientFileManifestBatchFromMessage, <String, Object>{
    'rootPath': rootPath,
    'filePaths': List<String>.of(filePaths),
  });
}

List<Map<String, dynamic>> _clientFileManifestBatchFromMessage(
  Map<String, Object> message,
) {
  return _clientFileManifestBatch(
    message['rootPath']! as String,
    (message['filePaths']! as List).cast<String>(),
  );
}

Map<String, dynamic> _clientFileManifestSync(String rootPath, File file) {
  final stat = file.statSync();
  final relativePath = _relativeClientPath(rootPath, file.path);
  final normalized = relativePath.replaceAll('\\', '/');
  final filename = normalized.split('/').last;
  final dot = filename.lastIndexOf('.');
  final extension = dot >= 0 ? filename.substring(dot + 1).toLowerCase() : '';
  final quickHash = _quickClientFileHashSync(file, stat.size);
  var metadata = const <String, dynamic>{};
  var metadataStatus = 'needs_attention';
  String? metadataMessage;
  int? sampleRate;
  int? bitrate;
  int? durationMs;
  try {
    final embedded = readMetadata(file, getImage: false);
    sampleRate = embedded.sampleRate;
    bitrate = embedded.bitrate;
    durationMs = embedded.duration?.inMilliseconds;
    final title = _cleanEmbeddedText(embedded.title);
    final artists = _embeddedTagValues(embedded.artist);
    final missing = <String>[
      if (title == null) 'TITLE',
      if (artists.isEmpty) 'ARTIST',
    ];
    metadata = <String, dynamic>{
      'title': title ?? '',
      'album': _cleanEmbeddedText(embedded.album),
      'track_artists': artists,
      'album_artists': const <String>[],
      'composers': const <String>[],
      'lyricists': const <String>[],
      'genres': embedded.genres
          .map(_cleanEmbeddedText)
          .whereType<String>()
          .toList(growable: false),
      'track_number': embedded.trackNumber,
      'track_total': embedded.trackTotal,
      'disc_number': embedded.discNumber,
      'disc_total': embedded.totalDisc,
      'duration_ms': durationMs,
      'date': embedded.year == null || embedded.year!.year <= 0
          ? null
          : embedded.year!.year.toString(),
      'year': embedded.year == null || embedded.year!.year <= 0
          ? null
          : embedded.year!.year,
      'lyrics': _cleanEmbeddedText(embedded.lyrics),
      'lyrics_kind': _embeddedLyricsKind(embedded.lyrics),
    };
    if (missing.isEmpty) {
      metadataStatus = 'ready';
    } else {
      metadataMessage =
          'Missing required embedded ${missing.join(' and ')} tags';
    }
  } catch (error) {
    metadataStatus = 'tag_parse_error';
    metadataMessage = error.toString();
  }
  return <String, dynamic>{
    'external_id': normalized,
    'relative_path': normalized,
    'extension': extension,
    'size_bytes': stat.size,
    'modified_at': stat.modified.toUtc().toIso8601String(),
    'quick_hash': quickHash,
    'content_hash': null,
    'codec': extension,
    'sample_rate': sampleRate,
    'channels': null,
    'duration_ms': durationMs,
    'bitrate': bitrate,
    'bit_depth': null,
    'metadata_status': metadataStatus,
    'metadata_message': metadataMessage,
    'metadata_source': 'embedded_tag',
    'metadata': metadata,
  };
}

String? _cleanEmbeddedText(Object? value) {
  final text = value?.toString().replaceAll('\u0000', '').trim();
  return text == null || text.isEmpty ? null : text;
}

List<String> _embeddedTagValues(Object? value) {
  final text = _cleanEmbeddedText(value);
  if (text == null) return const [];
  return text
      .split(RegExp(r'\s*;\s*|\u0000+'))
      .map(_cleanEmbeddedText)
      .whereType<String>()
      .toSet()
      .toList(growable: false);
}

String? _embeddedLyricsKind(Object? value) {
  final text = _cleanEmbeddedText(value);
  if (text == null) return null;
  return RegExp(r'\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]').hasMatch(text)
      ? 'lrc'
      : 'plain';
}

String _quickClientFileHashSync(File file, int size) {
  const sampleSize = 64 * 1024;
  final handle = file.openSync();
  try {
    final first = handle.readSync(min(sampleSize, size));
    var last = <int>[];
    if (size > sampleSize) {
      handle.setPositionSync(max(0, size - sampleSize));
      last = handle.readSync(min(sampleSize, size));
    }
    return sha256.convert(<int>[
      ...first,
      ...last,
      for (var index = 0; index < 8; index++) (size >> (index * 8)) & 0xff,
    ]).toString();
  } finally {
    handle.closeSync();
  }
}

Future<String> _quickClientFileHash(File file, int size) {
  final path = file.path;
  return Isolate.run(() => _quickClientFileHashSync(File(path), size));
}

String _relativeClientPath(String rootPath, String filePath) {
  final root = _normalizeLocalRootPath(rootPath);
  if (filePath.length > root.length &&
      filePath.substring(0, root.length) == root) {
    return filePath.substring(root.length).replaceFirst(RegExp(r'^[\\/]'), '');
  }
  return filePath.replaceAll('\\', '/').split('/').last;
}

String? _resolveClientReplicaPath(
  List<_ClientLibraryRoot> roots,
  Map<String, dynamic> media,
  String clientId,
) {
  final variants = media['variants'];
  if (variants is! List) {
    return null;
  }
  for (final variantValue in variants) {
    if (variantValue is! Map) {
      continue;
    }
    final replicas = variantValue['replicas'];
    if (replicas is! List) {
      continue;
    }
    for (final replicaValue in replicas) {
      if (replicaValue is! Map) {
        continue;
      }
      final replica = replicaValue.cast<String, dynamic>();
      if (replica['device_id']?.toString() != clientId ||
          replica['availability_state']?.toString() != 'ready') {
        continue;
      }
      final rootId = replica['root_external_id']?.toString();
      final relativePath = replica['relative_path']?.toString();
      if (rootId == null || relativePath == null) {
        continue;
      }
      final safeSegments = relativePath
          .replaceAll('\\', '/')
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (safeSegments.any((segment) => segment == '..')) {
        continue;
      }
      final root = roots.where((item) => item.externalId == rootId).firstOrNull;
      if (root == null) {
        continue;
      }
      return [root.path, ...safeSegments].join(Platform.pathSeparator);
    }
  }
  return null;
}
