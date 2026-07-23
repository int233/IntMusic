part of '../main.dart';

class CoreApiClient {
  CoreApiClient(String baseUrl, {this.timeout = const Duration(seconds: 20)})
    : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;
  final Duration timeout;

  Future<dynamic> getJson(String path) => _request('GET', path);

  Future<dynamic> postJson(String path, Map<String, dynamic> body) =>
      _request('POST', path, body: body);

  Future<dynamic> deleteJson(String path) => _request('DELETE', path);

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
  }) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final uri = Uri.parse(apiUrl(path));
      final request = switch (method) {
        'POST' => await client.postUrl(uri).timeout(timeout),
        'DELETE' => await client.deleteUrl(uri).timeout(timeout),
        _ => await client.getUrl(uri).timeout(timeout),
      };
      request.headers.contentType = ContentType.json;
      if (body != null) {
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
      }
      if (text.isEmpty) {
        return null;
      }
      return jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }
}
