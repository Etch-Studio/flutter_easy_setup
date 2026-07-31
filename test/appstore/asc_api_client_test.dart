import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';

import '../helpers/fake_http_json_client.dart';

void main() {
  AscApiClient client(FakeHttpJsonClient http) =>
      AscApiClient(http: http, token: 'jwt');

  group('AscApiClient.findBundleId', () {
    test('returns the resource id on an exact identifier match', () async {
      final http = FakeHttpJsonClient((method, uri, body) => JsonResponse(200, {
            'data': [
              // The ASC filter matches substrings — com.x.dev must not
              // shadow com.x.
              {
                'id': 'DEV1',
                'attributes': {'identifier': 'com.x.dev'},
              },
              {
                'id': 'PROD',
                'attributes': {'identifier': 'com.x'},
              },
            ],
          }));
      expect(await client(http).findBundleId('com.x'), 'PROD');
    });

    test('returns null when unregistered', () async {
      final http = FakeHttpJsonClient(
          (method, uri, body) => JsonResponse(200, {'data': []}));
      expect(await client(http).findBundleId('com.x'), isNull);
    });

    test('follows pagination until the exact match', () async {
      final http = FakeHttpJsonClient((method, uri, body) {
        if (!uri.queryParameters.containsKey('cursor')) {
          return JsonResponse(200, {
            'data': [
              {
                'id': 'DEV1',
                'attributes': {'identifier': 'com.x.dev'},
              },
            ],
            'links': {
              'next': '${AscApiClient.defaultBaseUrl}/bundleIds?cursor=p2',
            },
          });
        }
        return JsonResponse(200, {
          'data': [
            {
              'id': 'PROD',
              'attributes': {'identifier': 'com.x'},
            },
          ],
        });
      });
      expect(await client(http).findBundleId('com.x'), 'PROD');
      expect(http.requests, hasLength(2));
    });

    test('surfaces API errors with title/detail', () async {
      final http = FakeHttpJsonClient((method, uri, body) => JsonResponse(401, {
            'errors': [
              {'title': 'NOT_AUTHORIZED', 'detail': 'token expired'},
            ],
          }));
      await expectLater(
        () => client(http).findBundleId('com.x'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('token expired'))),
      );
    });
  });

  test('registerBundleId posts the IOS bundle id and returns its id',
      () async {
    final http = FakeHttpJsonClient((method, uri, body) => JsonResponse(201, {
          'data': {'id': 'NEW1'},
        }));
    final id = await client(http).registerBundleId('com.x', 'My App');
    expect(id, 'NEW1');
    final (_, uri, body) = http.requests.single;
    expect(uri.path, endsWith('/bundleIds'));
    final attributes =
        ((body as Map)['data'] as Map)['attributes'] as Map;
    expect(attributes['identifier'], 'com.x');
    expect(attributes['platform'], 'IOS');
  });

  test('registerBundleId resolves a 409 conflict to the existing resource',
      () async {
    final http = FakeHttpJsonClient((method, uri, body) => method == 'POST'
        ? JsonResponse(409, {
            'errors': [
              {'title': 'ENTITY_ERROR', 'detail': 'already exists'},
            ],
          })
        : JsonResponse(200, {
            'data': [
              {
                'id': 'EXISTING',
                'attributes': {'identifier': 'com.x'},
              },
            ],
          }));
    expect(await client(http).registerBundleId('com.x', 'My App'),
        'EXISTING');
  });

  test('capabilityTypes collects the enabled types', () async {
    final http = FakeHttpJsonClient((method, uri, body) => JsonResponse(200, {
          'data': [
            {
              'attributes': {'capabilityType': 'PUSH_NOTIFICATIONS'},
            },
            {
              'attributes': {'capabilityType': 'APP_GROUPS'},
            },
          ],
        }));
    expect(await client(http).capabilityTypes('RES1'),
        {'PUSH_NOTIFICATIONS', 'APP_GROUPS'});
  });

  test('enableCapability posts the type with the bundle id relationship',
      () async {
    final http = FakeHttpJsonClient(
        (method, uri, body) => JsonResponse(201, {'data': {}}));
    await client(http).enableCapability('RES1', 'PUSH_NOTIFICATIONS');
    final (_, uri, body) = http.requests.single;
    expect(uri.path, endsWith('/bundleIdCapabilities'));
    final data = (body as Map)['data'] as Map;
    expect((data['attributes'] as Map)['capabilityType'],
        'PUSH_NOTIFICATIONS');
    expect(
        ((((data['relationships'] as Map)['bundleId'] as Map)['data'])
            as Map)['id'],
        'RES1');
  });
}
