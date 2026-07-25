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
  }

  static final Map<String, CoreApiClient> _instances =
      <String, CoreApiClient>{};

  final String baseUrl;
  final Duration timeout;
  late final HttpClient _client;

  Future<dynamic> getJson(String path, {Duration? requestTimeout}) =>
      _request('GET', path, requestTimeout: requestTimeout);

  Future<dynamic> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration? requestTimeout,
  }) => _request('POST', path, body: body, requestTimeout: requestTimeout);

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
  }) async {
    final effectiveTimeout = requestTimeout ?? timeout;
    final uri = Uri.parse(apiUrl(path));
    final request = switch (method) {
      'POST' => await _client.postUrl(uri).timeout(effectiveTimeout),
      'DELETE' => await _client.deleteUrl(uri).timeout(effectiveTimeout),
      _ => await _client.getUrl(uri).timeout(effectiveTimeout),
    };
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(effectiveTimeout);
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(effectiveTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
    }
    if (text.isEmpty) {
      return null;
    }
    return jsonDecode(text);
  }
}
