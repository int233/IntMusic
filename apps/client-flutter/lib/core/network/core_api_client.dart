import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';

import '../logging/client_log.dart';

class CoreApiClient {
  factory CoreApiClient(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final normalized = normalizeBaseUrl(baseUrl);
    return _instances.putIfAbsent(
      normalized,
      () => CoreApiClient._(normalized, timeout),
    );
  }

  CoreApiClient._(this.baseUrl, this.timeout) {
    _client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 75)
      ..maxConnectionsPerHost = 8
      ..autoUncompress = true;
    // Keep time-sensitive playback commands away from slow metadata,
    // artwork, heartbeat, and synchronization requests.
    _controlClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 4
      ..autoUncompress = true;
  }

  static final Map<String, CoreApiClient> _instances =
      <String, CoreApiClient>{};

  final String baseUrl;
  final Duration timeout;
  late final HttpClient _client;
  late final HttpClient _controlClient;
  bool _closed = false;

  static String normalizeBaseUrl(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  /// Performs a single, uncached health probe.
  ///
  /// Discovery can inspect thousands of endpoints. These short-lived probes
  /// must not enter the pooled client map or inherit normal GET retries and
  /// per-request diagnostic logging.
  static Future<dynamic> probeJson(
    String baseUrl,
    String path, {
    Duration timeout = const Duration(milliseconds: 900),
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout
      ..maxConnectionsPerHost = 1
      ..autoUncompress = true;
    try {
      final uri = Uri.parse('$normalized/api/v1$path');
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  static int get debugPooledClientCount => _instances.length;

  static void retainOnly(String baseUrl) {
    final retained = normalizeBaseUrl(baseUrl);
    final staleKeys = _instances.keys
        .where((key) => key != retained)
        .toList(growable: false);
    for (final key in staleKeys) {
      _instances.remove(key)?.close();
    }
  }

  static void closeAll() {
    for (final client in _instances.values) {
      client.close();
    }
    _instances.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
    _controlClient.close(force: true);
  }

  Future<dynamic> getJson(String path, {Duration? requestTimeout}) =>
      _request('GET', path, requestTimeout: requestTimeout);

  Future<dynamic> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? requestTimeout,
  }) => _request('POST', path, body: body, requestTimeout: requestTimeout);

  Future<dynamic> postControlJson(
    String path,
    Map<String, dynamic> body, {
    Duration requestTimeout = const Duration(seconds: 5),
  }) => _request(
    'POST',
    path,
    body: body,
    requestTimeout: requestTimeout,
    control: true,
  );

  Future<dynamic> deleteJson(String path, {Duration? requestTimeout}) =>
      _request('DELETE', path, requestTimeout: requestTimeout);

  Future<dynamic> uploadFile(
    String path,
    XFile file, {
    String photoType = 'other',
  }) async {
    const uploadTimeout = Duration(minutes: 5);
    final client = HttpClient();
    client.connectionTimeout = uploadTimeout;
    final boundary =
        '----IntMusic${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    try {
      final uri = Uri.parse(apiUrl(path));
      final request = await client.postUrl(uri).timeout(uploadTimeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      void writeField(String name, String value) {
        request.write('--$boundary\r\n');
        request.write('Content-Disposition: form-data; name="$name"\r\n\r\n');
        request.write(value);
        request.write('\r\n');
      }

      writeField('photo_type', photoType);
      final safeName = file.name.replaceAll(RegExp(r'["\r\n]'), '_');
      request.write('--$boundary\r\n');
      request.write(
        'Content-Disposition: form-data; name="file"; filename="$safeName"\r\n',
      );
      request.write(
        'Content-Type: ${file.mimeType ?? 'application/octet-stream'}\r\n\r\n',
      );
      await request.addStream(file.openRead().timeout(uploadTimeout));
      request.write('\r\n--$boundary--\r\n');
      final response = await request.close().timeout(uploadTimeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(uploadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  String apiUrl(String path) => '$baseUrl/api/v1$path';

  String wsUrl(String path) =>
      '${baseUrl.replaceFirst(RegExp(r'^http'), 'ws')}$path';

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration? requestTimeout,
    bool control = false,
  }) async {
    final attempts = method == 'GET' ? 2 : 1;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      try {
        return await _requestOnce(
          method,
          path,
          body: body,
          requestTimeout: requestTimeout,
          control: control,
        );
      } on SocketException catch (error) {
        lastError = error;
      } on HttpException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = error;
      }
      if (attempt + 1 < attempts) {
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    }
    throw lastError ?? StateError('request failed without an error');
  }

  Future<dynamic> _requestOnce(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration? requestTimeout,
    bool control = false,
  }) async {
    if (_closed) {
      throw StateError('CoreApiClient for $baseUrl has been closed.');
    }
    final effectiveTimeout = requestTimeout ?? timeout;
    final uri = Uri.parse(apiUrl(path));
    final stopwatch = Stopwatch()..start();
    Duration remainingTimeout() {
      final remaining = effectiveTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          '$method ${uri.path} exceeded '
          '${effectiveTimeout.inMilliseconds} ms',
          effectiveTimeout,
        );
      }
      return remaining;
    }

    ClientLog.event(
      'core.http.start',
      data: <String, Object?>{
        'method': method,
        'path': uri.path,
        'timeout_ms': effectiveTimeout.inMilliseconds,
        'channel': control ? 'playback_control' : 'background',
      },
    );
    try {
      final request = switch (method) {
        'POST' =>
          await (control ? _controlClient : _client)
              .postUrl(uri)
              .timeout(remainingTimeout()),
        'DELETE' =>
          await (control ? _controlClient : _client)
              .deleteUrl(uri)
              .timeout(remainingTimeout()),
        _ =>
          await (control ? _controlClient : _client)
              .getUrl(uri)
              .timeout(remainingTimeout()),
      };
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
      if (body != null) {
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(remainingTimeout());
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(remainingTimeout());
      ClientLog.event(
        'core.http.end',
        data: <String, Object?>{
          'method': method,
          'path': uri.path,
          'status': response.statusCode,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          'response_characters': text.length,
          'channel': control ? 'playback_control' : 'background',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      if (text.isEmpty) {
        return null;
      }
      return text.length >= 1024 * 1024
          ? Isolate.run<dynamic>(() => jsonDecode(text))
          : jsonDecode(text);
    } catch (error, stackTrace) {
      ClientLog.error(
        'core.http.error',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'method': method,
          'path': uri.path,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          'channel': control ? 'playback_control' : 'background',
        },
      );
      rethrow;
    }
  }
}
