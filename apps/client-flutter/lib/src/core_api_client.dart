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
