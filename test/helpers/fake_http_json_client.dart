import 'package:easy_setup/easy_setup.dart';

/// Shared HTTP fake: routes every request through [handler] and records
/// (method, uri, body) triples.
class FakeHttpJsonClient implements HttpJsonClient {
  final JsonResponse Function(String method, Uri uri, Object? body) handler;
  final requests = <(String, Uri, Object?)>[];

  FakeHttpJsonClient(this.handler);

  @override
  Future<JsonResponse> get(Uri uri,
      {Map<String, String> headers = const {}}) async {
    requests.add(('GET', uri, null));
    return handler('GET', uri, null);
  }

  @override
  Future<JsonResponse> post(Uri uri,
      {Map<String, String> headers = const {}, Object? body}) async {
    requests.add(('POST', uri, body));
    return handler('POST', uri, body);
  }

  @override
  Future<JsonResponse> delete(Uri uri,
      {Map<String, String> headers = const {}}) async {
    requests.add(('DELETE', uri, null));
    return handler('DELETE', uri, null);
  }
}

/// Throwaway P-256 key generated for tests only — never used anywhere real.
const testEcPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgLB+Q9Jh6qW68nZ4T
G9nwlFhhYMCWDGEVMuRv5biD2DehRANCAAT/LWx97EFUaE/zrCq1tq78K2t/+tzi
569EClltb1CsbnGLgR1RRFmaFUycDXl7BlrS7RmBJnbfLspN3gLQjqpa
-----END PRIVATE KEY-----
''';
