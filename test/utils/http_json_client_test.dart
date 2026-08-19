import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';

/// One request as the server saw it.
typedef Received = ({String method, String? contentType, String body});

void main() {
  late HttpServer server;
  late Uri uri;
  final received = <Received>[];
  var response = (status: 200, body: '{"ok": true}');

  setUp(() async {
    received.clear();
    response = (status: 200, body: '{"ok": true}');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/token');
    server.listen((request) async {
      received.add((
        method: request.method,
        contentType: request.headers.contentType?.mimeType,
        body: await utf8.decoder.bind(request).join(),
      ));
      request.response.statusCode = response.status;
      request.response.write(response.body);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  group('IoHttpJsonClient', () {
    test('post sends a JSON body', () async {
      final result =
          await IoHttpJsonClient().post(uri, body: {'grant_type': 'refresh'});
      expect(result.status, 200);
      expect((result.body as Map)['ok'], isTrue);
      expect(received.single.contentType, 'application/json');
      expect(json.decode(received.single.body), {'grant_type': 'refresh'});
    });

    test('postForm sends url-encoded fields, as token endpoints document',
        () async {
      await IoHttpJsonClient().postForm(uri, fields: {
        'grant_type': 'refresh_token',
        // Refresh tokens really do contain characters that must be escaped.
        'refresh_token': '1//abc+def/ghi=',
      });
      expect(received.single.contentType, 'application/x-www-form-urlencoded');
      expect(
        Uri.splitQueryString(received.single.body),
        {'grant_type': 'refresh_token', 'refresh_token': '1//abc+def/ghi='},
      );
    });

    test('a non-JSON body comes back as text with its status', () async {
      response = (status: 503, body: 'upstream down');
      final result = await IoHttpJsonClient().get(uri);
      expect(result.status, 503);
      expect(result.ok, isFalse);
      expect(result.body, 'upstream down');
    });

    test('an unreachable host is a SetupException naming it', () async {
      await server.close(force: true);
      await expectLater(
        () => IoHttpJsonClient(timeout: const Duration(seconds: 2)).get(uri),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('127.0.0.1'))),
      );
    });
  });
}
