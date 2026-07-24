part of '../main.dart';

class _DistributionDownloadResult {
  const _DistributionDownloadResult({
    required this.bytes,
    required this.quickHash,
  });

  final int bytes;
  final String quickHash;
}

Future<_DistributionDownloadResult> _downloadDistributionFile({
  required CoreApiClient api,
  required String contentPath,
  required String deviceId,
  required String taskId,
  required String targetPath,
  required int expectedSize,
  required String? expectedQuickHash,
  required Future<void> Function(int bytes) onProgress,
}) async {
  final target = File(targetPath);
  await target.parent.create(recursive: true);
  final partial = File('${target.path}.intmusic-$taskId.part');
  var existingBytes = await partial.exists() ? await partial.length() : 0;
  if (existingBytes < 0 || existingBytes > expectedSize) {
    await partial.delete();
    existingBytes = 0;
  }

  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 30);
  try {
    while (existingBytes < expectedSize) {
      final separator = contentPath.contains('?') ? '&' : '?';
      final uri = Uri.parse(
        api.apiUrl(
          '$contentPath${separator}device_id=${Uri.encodeQueryComponent(deviceId)}',
        ),
      );
      final request = await client.getUrl(uri);
      if (existingBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
      }
      final response = await request.close();
      if (existingBytes > 0 && response.statusCode == HttpStatus.ok) {
        await response.drain<void>();
        await partial.delete();
        existingBytes = 0;
        continue;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        final message = await response.transform(utf8.decoder).join();
        throw HttpException(
          'Distribution download failed with HTTP '
          '${response.statusCode}: $message',
          uri: uri,
        );
      }
      final sink = partial.openWrite(
        mode: existingBytes > 0 ? FileMode.append : FileMode.write,
      );
      var downloaded = existingBytes;
      var lastProgress = DateTime.now();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          downloaded += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastProgress) >= const Duration(seconds: 2)) {
            await onProgress(downloaded);
            lastProgress = now;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      existingBytes = await partial.length();
      await onProgress(existingBytes);
      if (existingBytes >= expectedSize) {
        break;
      }
      throw const FileSystemException(
        'Distribution source ended before the expected file size',
      );
    }

    final size = await partial.length();
    if (size != expectedSize) {
      throw FileSystemException(
        'Downloaded file size $size does not match expected size $expectedSize',
        partial.path,
      );
    }
    final quickHash = await _quickClientFileHash(partial, size);
    if (expectedQuickHash != null &&
        expectedQuickHash.trim().isNotEmpty &&
        quickHash.toLowerCase() != expectedQuickHash.trim().toLowerCase()) {
      throw FileSystemException(
        'Downloaded file failed its content verification',
        partial.path,
      );
    }
    if (await target.exists()) {
      await target.delete();
    }
    await partial.rename(target.path);
    return _DistributionDownloadResult(bytes: size, quickHash: quickHash);
  } finally {
    client.close(force: true);
  }
}

String? _distributionTargetPath(_ClientLibraryRoot root, String relativePath) {
  final segments = relativePath
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty ||
      segments.any(
        (segment) =>
            segment == '.' ||
            segment == '..' ||
            segment.contains('\u0000') ||
            segment.contains('/') ||
            segment.contains('\\'),
      )) {
    return null;
  }
  return <String>[root.path, ...segments].join(Platform.pathSeparator);
}
