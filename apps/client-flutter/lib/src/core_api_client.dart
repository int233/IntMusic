part of '../main.dart';

class CoreApiClient {
  factory CoreApiClient(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
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
      request.write('Content-Type: application/octet-stream\r\n\r\n');
      request.add(await file.readAsBytes().timeout(uploadTimeout));
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

    _ClientLog.event(
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
      _ClientLog.event(
        'core.http.end',
        data: <String, Object?>{
          'method': method,
          'path': uri.path,
          'status': response.statusCode,
          'elapsed_ms': stopwatch.elapsedMilliseconds,
          'response_bytes': utf8.encode(text).length,
          'channel': control ? 'playback_control' : 'background',
        },
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      if (text.isEmpty) {
        return null;
      }
      return jsonDecode(text);
    } catch (error, stackTrace) {
      _ClientLog.error(
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
