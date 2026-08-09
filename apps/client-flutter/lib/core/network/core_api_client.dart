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
    _backgroundClient = _createClient(_CoreApiChannel.background);
    _controlClient = _createClient(_CoreApiChannel.control);
    _criticalClient = _createClient(_CoreApiChannel.critical);
    _bulkClient = _createClient(_CoreApiChannel.bulk);
    _librarySyncClient = _createClient(_CoreApiChannel.librarySync);
  }

  static final Map<String, CoreApiClient> _instances =
      <String, CoreApiClient>{};

  final String baseUrl;
  final Duration timeout;
  late HttpClient _backgroundClient;
  late HttpClient _controlClient;
  late HttpClient _criticalClient;
  late HttpClient _bulkClient;
  late HttpClient _librarySyncClient;
  final Map<HttpClient, Timer> _retiredClientTimers = <HttpClient, Timer>{};
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
    _backgroundClient.close(force: true);
    _controlClient.close(force: true);
    _criticalClient.close(force: true);
    _bulkClient.close(force: true);
    _librarySyncClient.close(force: true);
    for (final entry in _retiredClientTimers.entries) {
      entry.value.cancel();
      entry.key.close(force: true);
    }
    _retiredClientTimers.clear();
  }

  Future<dynamic> getJson(String path, {Duration? requestTimeout}) =>
      _request('GET', path, requestTimeout: requestTimeout);

  /// Reads latency-sensitive state without sharing sockets with metadata and
  /// inventory work. Renderer heartbeats and connection health use this path.
  Future<dynamic> getCriticalJson(
    String path, {
    Duration requestTimeout = const Duration(seconds: 5),
  }) => _request(
    'GET',
    path,
    requestTimeout: requestTimeout,
    channel: _CoreApiChannel.critical,
  );

  /// Runs large, cancelable inventory reads on their own small connection pool.
  Future<dynamic> getBulkJson(
    String path, {
    Duration requestTimeout = const Duration(seconds: 30),
  }) => _request(
    'GET',
    path,
    requestTimeout: requestTimeout,
    channel: _CoreApiChannel.bulk,
  );

  Future<dynamic> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? requestTimeout,
  }) => _request('POST', path, body: body, requestTimeout: requestTimeout);

  Future<dynamic> postCriticalJson(
    String path,
    Map<String, dynamic> body, {
    Duration requestTimeout = const Duration(seconds: 5),
  }) => _request(
    'POST',
    path,
    body: body,
    requestTimeout: requestTimeout,
    channel: _CoreApiChannel.critical,
  );

  Future<dynamic> postBulkJson(
    String path,
    Map<String, dynamic> body, {
    Duration requestTimeout = const Duration(seconds: 30),
  }) => _request(
    'POST',
    path,
    body: body,
    requestTimeout: requestTimeout,
    channel: _CoreApiChannel.bulk,
  );

  /// Uploads a Client library manifest without sharing sockets with catalog
  /// warmup, renderer reporting, or distribution polling.
  ///
  /// Manifest batches can spend significant time in Core database
  /// reconciliation. Keeping them on a serialized, long-timeout channel means
  /// a slow scan cannot consume or recycle foreground transport capacity.
  Future<dynamic> postLibrarySyncJson(
    String path,
    Map<String, dynamic> body, {
    Duration requestTimeout = const Duration(seconds: 120),
  }) => _request(
    'POST',
    path,
    body: body,
    requestTimeout: requestTimeout,
    channel: _CoreApiChannel.librarySync,
  );

  Future<dynamic> postControlJson(
    String path,
    Map<String, dynamic> body, {
    Duration requestTimeout = const Duration(seconds: 5),
  }) => _request(
    'POST',
    path,
    body: body,
    requestTimeout: requestTimeout,
    channel: _CoreApiChannel.control,
  );

  Future<dynamic> deleteJson(String path, {Duration? requestTimeout}) =>
      _request('DELETE', path, requestTimeout: requestTimeout);

  /// Cancels obsolete inventory reads before a newer filter/page request.
  ///
  /// `Future.timeout` alone does not cancel a queued `HttpClient` operation.
  /// Recycling this isolated channel guarantees that stale work cannot retain
  /// sockets or starve renderer health traffic.
  void cancelBulkRequests() {
    if (_closed) return;
    final previous = _bulkClient;
    _bulkClient = _createClient(_CoreApiChannel.bulk);
    previous.close(force: true);
  }

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
    _CoreApiChannel channel = _CoreApiChannel.background,
  }) async {
    final hasIdempotencyKey =
        body?['intent_id']?.toString().trim().isNotEmpty == true ||
        body?['command_id']?.toString().trim().isNotEmpty == true;
    final attempts = channel == _CoreApiChannel.librarySync
        ? 3
        : channel == _CoreApiChannel.control && hasIdempotencyKey
        ? 2
        : method == 'GET' && channel != _CoreApiChannel.bulk
        ? 2
        : 1;
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      var retryable = true;
      try {
        return await _requestOnce(
          method,
          path,
          body: body,
          requestTimeout: requestTimeout,
          channel: channel,
        );
      } on SocketException catch (error) {
        lastError = error;
      } on HttpException catch (error) {
        lastError = error;
        if (RegExp(r'^HTTP 4\d\d:').hasMatch(error.message)) {
          retryable = false;
        }
      } on TimeoutException catch (error) {
        lastError = error;
      }
      if (!retryable) break;
      if (attempt + 1 < attempts) {
        final delay = channel == _CoreApiChannel.librarySync
            ? Duration(milliseconds: 800 * (1 << attempt))
            : const Duration(milliseconds: 180);
        ClientLog.event(
          'core.http.retry_scheduled',
          level: 'warning',
          data: <String, Object?>{
            'method': method,
            'path': path,
            'channel': channel.logName,
            'attempt': attempt + 2,
            'delay_ms': delay.inMilliseconds,
          },
        );
        await Future<void>.delayed(delay);
      }
    }
    throw lastError ?? StateError('request failed without an error');
  }

  Future<dynamic> _requestOnce(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration? requestTimeout,
    _CoreApiChannel channel = _CoreApiChannel.background,
  }) async {
    if (_closed) {
      throw StateError('CoreApiClient for $baseUrl has been closed.');
    }
    final effectiveTimeout = requestTimeout ?? timeout;
    final uri = Uri.parse(apiUrl(path));
    final stopwatch = Stopwatch()..start();
    final client = _clientFor(channel);
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
        'channel': channel.logName,
      },
    );
    try {
      final request = switch (method) {
        'POST' => await client.postUrl(uri).timeout(remainingTimeout()),
        'DELETE' => await client.deleteUrl(uri).timeout(remainingTimeout()),
        _ => await client.getUrl(uri).timeout(remainingTimeout()),
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
          'channel': channel.logName,
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
      if (error is TimeoutException) {
        _retireTimedOutClient(channel, client, effectiveTimeout);
      }
      ClientLog.error(
        'core.http.error',
        error,
        stackTrace: stackTrace,
        data: <String, Object?>{
          'method': method,
          'path': uri.path,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          'channel': channel.logName,
        },
      );
      rethrow;
    }
  }

  HttpClient _createClient(_CoreApiChannel channel) {
    final client = HttpClient()..autoUncompress = true;
    switch (channel) {
      case _CoreApiChannel.background:
        client
          ..connectionTimeout = timeout
          ..idleTimeout = const Duration(seconds: 75)
          ..maxConnectionsPerHost = 8;
      case _CoreApiChannel.control:
        client
          ..connectionTimeout = const Duration(seconds: 4)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = 4;
      case _CoreApiChannel.critical:
        client
          ..connectionTimeout = const Duration(seconds: 4)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = 3;
      case _CoreApiChannel.bulk:
        client
          ..connectionTimeout = const Duration(seconds: 8)
          ..idleTimeout = const Duration(seconds: 20)
          ..maxConnectionsPerHost = 2;
      case _CoreApiChannel.librarySync:
        client
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30)
          ..maxConnectionsPerHost = 1;
    }
    return client;
  }

  HttpClient _clientFor(_CoreApiChannel channel) => switch (channel) {
    _CoreApiChannel.background => _backgroundClient,
    _CoreApiChannel.control => _controlClient,
    _CoreApiChannel.critical => _criticalClient,
    _CoreApiChannel.bulk => _bulkClient,
    _CoreApiChannel.librarySync => _librarySyncClient,
  };

  void _retireTimedOutClient(
    _CoreApiChannel channel,
    HttpClient timedOutClient,
    Duration requestTimeout,
  ) {
    if (_closed || !identical(_clientFor(channel), timedOutClient)) return;
    final replacement = _createClient(channel);
    switch (channel) {
      case _CoreApiChannel.background:
        _backgroundClient = replacement;
      case _CoreApiChannel.control:
        _controlClient = replacement;
      case _CoreApiChannel.critical:
        _criticalClient = replacement;
      case _CoreApiChannel.bulk:
        _bulkClient = replacement;
      case _CoreApiChannel.librarySync:
        _librarySyncClient = replacement;
    }
    // Future.timeout does not cancel dart:io's underlying socket operation.
    // Rotate new work onto a fresh pool, but give unrelated requests that were
    // already using the retired pool time to finish before forcing it closed.
    // Immediate force-close was the source of correlated background failures
    // on high-latency links.
    final graceMilliseconds = requestTimeout.inMilliseconds
        .clamp(
          const Duration(seconds: 5).inMilliseconds,
          const Duration(seconds: 60).inMilliseconds,
        )
        .toInt();
    final timer = Timer(Duration(milliseconds: graceMilliseconds), () {
      _retiredClientTimers.remove(timedOutClient);
      timedOutClient.close(force: true);
    });
    _retiredClientTimers[timedOutClient] = timer;
    ClientLog.event(
      'core.http.channel_retired',
      level: 'warning',
      data: <String, Object?>{
        'channel': channel.logName,
        'grace_ms': graceMilliseconds,
      },
    );
  }
}

enum _CoreApiChannel {
  background('background'),
  control('playback_control'),
  critical('connection_health'),
  bulk('library_inventory'),
  librarySync('library_sync');

  const _CoreApiChannel(this.logName);

  final String logName;
}
