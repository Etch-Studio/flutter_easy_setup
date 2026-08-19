import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../exceptions.dart';

/// Status code + decoded JSON body of an HTTP response.
class JsonResponse {
  final int status;
  final Object? body;

  JsonResponse(this.status, this.body);

  bool get ok => status >= 200 && status < 300;
}

/// Minimal JSON-over-HTTP client, injectable for tests.
abstract class HttpJsonClient {
  Future<JsonResponse> get(Uri uri, {Map<String, String> headers});
  Future<JsonResponse> post(Uri uri,
      {Map<String, String> headers, Object? body});
  Future<JsonResponse> delete(Uri uri, {Map<String, String> headers});
}

/// dart:io implementation (no extra dependencies). Network failures are
/// wrapped as [SetupException] with the target host, and every request has
/// a hard timeout.
class IoHttpJsonClient implements HttpJsonClient {
  final Duration timeout;

  IoHttpJsonClient({this.timeout = const Duration(seconds: 30)});

  @override
  Future<JsonResponse> get(Uri uri, {Map<String, String> headers = const {}}) =>
      _send('GET', uri, headers: headers);

  @override
  Future<JsonResponse> post(Uri uri,
          {Map<String, String> headers = const {}, Object? body}) =>
      _send('POST', uri, headers: headers, body: body);

  @override
  Future<JsonResponse> delete(Uri uri,
          {Map<String, String> headers = const {}}) =>
      _send('DELETE', uri, headers: headers);

  Future<JsonResponse> _send(String method, Uri uri,
      {Map<String, String> headers = const {}, Object? body}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      return await _request(client, method, uri, headers: headers, body: body)
          .timeout(timeout);
    } on TimeoutException {
      throw SetupException(
          'Request to ${uri.host} timed out after ${timeout.inSeconds}s.');
    } on SocketException catch (e) {
      throw SetupException(
          'Could not reach ${uri.host}: ${e.message} — check the network.');
    } on HandshakeException catch (e) {
      throw SetupException('TLS handshake with ${uri.host} failed: $e');
    } on HttpException catch (e) {
      throw SetupException('HTTP error talking to ${uri.host}: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<JsonResponse> _request(
      HttpClient client, String method, Uri uri,
      {Map<String, String> headers = const {}, Object? body}) async {
    final request = await client.openUrl(method, uri);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(json.encode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? decoded;
    if (text.isNotEmpty) {
      try {
        decoded = json.decode(text);
      } on FormatException {
        decoded = text;
      }
    }
    return JsonResponse(response.statusCode, decoded);
  }
}
