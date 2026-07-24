part of '../main.dart';

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

Future<Map<String, dynamic>> _clientFileManifest(
  String rootPath,
  File file,
) async {
  final stat = await file.stat();
  final relativePath = _relativeClientPath(rootPath, file.path);
  final normalized = relativePath.replaceAll('\\', '/');
  final segments = normalized.split('/');
  final filename = segments.last;
  final dot = filename.lastIndexOf('.');
  final stem = dot > 0 ? filename.substring(0, dot) : filename;
  final parsed = RegExp(
    r'^\s*(?:(\d{1,3})\s*[-._ ]+\s*)?(.+?)\s*$',
  ).firstMatch(stem);
  final title = parsed?.group(2)?.trim().isNotEmpty == true
      ? parsed!.group(2)!.trim()
      : stem;
  final trackNumber = int.tryParse(parsed?.group(1) ?? '');
  var album = segments.length >= 2 ? segments[segments.length - 2] : null;
  int? discNumber;
  if (album != null) {
    final discMatch = RegExp(
      r'^(?:cd|disc|disk|碟)\s*[-._ ]*(\d+)$',
      caseSensitive: false,
    ).firstMatch(album);
    if (discMatch != null) {
      discNumber = int.tryParse(discMatch.group(1) ?? '');
      album = segments.length >= 3 ? segments[segments.length - 3] : null;
    }
  }
  final artistIndex = discNumber == null
      ? segments.length - 3
      : segments.length - 4;
  final artist = artistIndex >= 0 ? segments[artistIndex].trim() : '';
  final extension = dot >= 0 ? filename.substring(dot + 1).toLowerCase() : '';
  final quickHash = await _quickClientFileHash(file, stat.size);
  return <String, dynamic>{
    'external_id': normalized,
    'relative_path': normalized,
    'extension': extension,
    'size_bytes': stat.size,
    'modified_at': stat.modified.toUtc().toIso8601String(),
    'quick_hash': quickHash,
    'content_hash': null,
    'codec': extension,
    'sample_rate': null,
    'channels': null,
    'duration_ms': null,
    'bitrate': null,
    'bit_depth': null,
    'metadata': <String, dynamic>{
      'title': title,
      'album': album?.trim().isEmpty == true ? null : album?.trim(),
      'track_artists': artist.isEmpty ? <String>[] : <String>[artist],
      'album_artists': artist.isEmpty ? <String>[] : <String>[artist],
      'track_number': trackNumber,
      'disc_number': discNumber,
    },
  };
}

Future<String> _quickClientFileHash(File file, int size) async {
  const sampleSize = 64 * 1024;
  final handle = await file.open();
  try {
    final first = await handle.read(min(sampleSize, size));
    var last = <int>[];
    if (size > sampleSize) {
      await handle.setPosition(max(0, size - sampleSize));
      last = await handle.read(min(sampleSize, size));
    }
    return sha256.convert(<int>[
      ...first,
      ...last,
      for (var index = 0; index < 8; index++) (size >> (index * 8)) & 0xff,
    ]).toString();
  } finally {
    await handle.close();
  }
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
