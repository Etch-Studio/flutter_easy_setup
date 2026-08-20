import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/fake_http_json_client.dart';

/// gcloud is either absent or hands out [token].
class _GcloudRunner extends ProcessRunner {
  final String? token;
  final int exitCode;
  final ran = <(String, List<String>)>[];

  _GcloudRunner({this.token, this.exitCode = 0});

  @override
  Future<String?> which(String command) async =>
      token == null ? null : '/usr/bin/$command';

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    ran.add((executable, arguments));
    return ProcessResult(0, exitCode, '${token ?? ''}\n', '');
  }
}

void main() {
  const account = 'accounts/pub-1234567890123456';

  AdmobApi api({
    required JsonResponse Function(String, Uri, Object?) handler,
    Map<String, String> env = const {'ADMOB_ACCESS_TOKEN': 'token'},
    ProcessRunner? processes,
  }) =>
      AdmobApi(
        http: FakeHttpJsonClient(handler),
        env: env,
        processes: processes ?? _GcloudRunner(),
      );

  group('AdmobApi credentials', () {
    test('hasEnvCredentials accepts a token or a complete refresh triple', () {
      expect(AdmobApi.hasEnvCredentials(const {}), isFalse);
      expect(
          AdmobApi.hasEnvCredentials(const {'ADMOB_ACCESS_TOKEN': 't'}), isTrue);
      // A refresh token alone cannot be exchanged.
      expect(AdmobApi.hasEnvCredentials(const {'ADMOB_REFRESH_TOKEN': 'r'}),
          isFalse);
      expect(
          AdmobApi.hasEnvCredentials(const {
            'ADMOB_REFRESH_TOKEN': 'r',
            'ADMOB_OAUTH_CLIENT_ID': 'id',
            'ADMOB_OAUTH_CLIENT_SECRET': 'secret',
          }),
          isTrue);
    });

    test('an access token in the environment is used as is', () async {
      final http = FakeHttpJsonClient((_, _, _) => JsonResponse(200, {}));
      final client = AdmobApi(
          http: http, env: const {'ADMOB_ACCESS_TOKEN': 'ya29.direct'});
      expect(await client.accessToken(), 'ya29.direct');
      expect(http.requests, isEmpty);
    });

    test('a refresh token is exchanged once and then cached', () async {
      final http = FakeHttpJsonClient((method, uri, body) =>
          uri.host == 'oauth2.googleapis.com'
              ? JsonResponse(200, {'access_token': 'ya29.fresh'})
              : JsonResponse(404, null));
      final client = AdmobApi(
        http: http,
        env: const {
          'ADMOB_REFRESH_TOKEN': 'refresh',
          'ADMOB_OAUTH_CLIENT_ID': 'client',
          'ADMOB_OAUTH_CLIENT_SECRET': 'secret',
        },
      );
      expect(await client.accessToken(), 'ya29.fresh');
      expect(await client.accessToken(), 'ya29.fresh');
      expect(http.requests, hasLength(1));
      final body = http.requests.single.$3 as Map;
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'refresh');
      expect(body['client_id'], 'client');
    });

    test('a rejected refresh token surfaces the reason and the hint',
        () async {
      final client = AdmobApi(
        http: FakeHttpJsonClient((_, _, _) => JsonResponse(400, {
              'error': 'invalid_grant',
              'error_description': 'Token has been expired or revoked.',
            })),
        env: const {
          'ADMOB_REFRESH_TOKEN': 'stale',
          'ADMOB_OAUTH_CLIENT_ID': 'client',
          'ADMOB_OAUTH_CLIENT_SECRET': 'secret',
        },
      );
      await expectLater(
        client.accessToken,
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('expired or revoked'))
            .having((e) => e.message, 'message',
                contains('gcloud auth application-default login'))),
      );
    });

    test('gcloud application-default credentials are the last resort',
        () async {
      final processes = _GcloudRunner(token: 'ya29.gcloud');
      final client = AdmobApi(
        http: FakeHttpJsonClient((_, _, _) => JsonResponse(404, null)),
        env: const {},
        processes: processes,
      );
      expect(await client.accessToken(), 'ya29.gcloud');
      expect(processes.ran.single.$2,
          ['auth', 'application-default', 'print-access-token']);
    });

    test('a gcloud that cannot mint a token is not a credential', () async {
      final client = AdmobApi(
        http: FakeHttpJsonClient((_, _, _) => JsonResponse(404, null)),
        env: const {},
        // Installed, but no application-default login has happened.
        processes: _GcloudRunner(token: 'ignored', exitCode: 1),
      );
      await expectLater(
        client.accessToken,
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            contains('AdMob API access needs OAuth user credentials'))),
      );
    });

    test('no credential at all explains every option', () async {
      final client = AdmobApi(
        http: FakeHttpJsonClient((_, _, _) => JsonResponse(404, null)),
        env: const {},
        processes: _GcloudRunner(),
      );
      await expectLater(
        client.accessToken,
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('ADMOB_ACCESS_TOKEN'))
            .having((e) => e.message, 'message',
                contains('ADMOB_REFRESH_TOKEN'))),
      );
    });
  });

  group('AdmobApi quota project', () {
    /// A CLOUDSDK_CONFIG holding an ADC file with [quotaProjectId], or none.
    Directory gcloudConfig({String? quotaProjectId}) {
      final dir = Directory.systemTemp.createTempSync('admob-adc');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'application_default_credentials.json'))
          .writeAsStringSync(jsonEncode({
        'client_id': 'gcloud.apps.googleusercontent.com',
        'type': 'authorized_user',
        'quota_project_id': ?quotaProjectId,
      }));
      return dir;
    }

    /// Header map of the accounts listing [client] performs.
    Future<Map<String, String>> headersOf(
        AdmobApi client, FakeHttpJsonClient http) async {
      await client.accountName();
      return http.sentHeaders.single;
    }

    FakeHttpJsonClient accountsHttp() => FakeHttpJsonClient((_, _, _) =>
        JsonResponse(200, {
          'account': [
            {'name': account}
          ]
        }));

    test('an ADC token carries the quota project gcloud recorded', () async {
      final http = accountsHttp();
      final client = AdmobApi(
        http: http,
        env: {'CLOUDSDK_CONFIG': gcloudConfig(quotaProjectId: 'proj-1').path},
        processes: _GcloudRunner(token: 'ya29.gcloud'),
      );
      final headers = await headersOf(client, http);
      expect(headers['Authorization'], 'Bearer ya29.gcloud');
      expect(headers['x-goog-user-project'], 'proj-1');
    });

    test('asking before the token is fetched still finds it', () async {
      // quotaProject() answers from the token's source, so a caller that
      // reaches for it first must not get — and cache — a null.
      final http = accountsHttp();
      final client = AdmobApi(
        http: http,
        env: {'CLOUDSDK_CONFIG': gcloudConfig(quotaProjectId: 'proj-1').path},
        processes: _GcloudRunner(token: 'ya29.gcloud'),
      );
      expect(await client.quotaProject(), 'proj-1');
      expect((await headersOf(client, http))['x-goog-user-project'], 'proj-1');
    });

    test('an ADC file without one sends no header', () async {
      final http = accountsHttp();
      final client = AdmobApi(
        http: http,
        env: {'CLOUDSDK_CONFIG': gcloudConfig().path},
        processes: _GcloudRunner(token: 'ya29.gcloud'),
      );
      expect(await headersOf(client, http),
          isNot(contains('x-goog-user-project')));
    });

    test('GOOGLE_CLOUD_QUOTA_PROJECT overrides the ADC file', () async {
      final http = accountsHttp();
      final client = AdmobApi(
        http: http,
        env: {
          'CLOUDSDK_CONFIG': gcloudConfig(quotaProjectId: 'from-file').path,
          'GOOGLE_CLOUD_QUOTA_PROJECT': 'from-env',
        },
        processes: _GcloudRunner(token: 'ya29.gcloud'),
      );
      expect((await headersOf(client, http))['x-goog-user-project'],
          'from-env');
    });

    test('a token of your own is not given the machine\'s ADC project',
        () async {
      final http = accountsHttp();
      // ADMOB_ACCESS_TOKEN comes from an OAuth client that already belongs to
      // a project; naming an unrelated one would break a working setup.
      final client = AdmobApi(
        http: http,
        env: {
          'ADMOB_ACCESS_TOKEN': 'token',
          'CLOUDSDK_CONFIG': gcloudConfig(quotaProjectId: 'someone-else').path,
        },
        processes: _GcloudRunner(token: 'ya29.gcloud'),
      );
      expect(await headersOf(client, http),
          isNot(contains('x-goog-user-project')));
    });

    test('an explicit quota project applies to any credential', () async {
      final http = accountsHttp();
      final client = AdmobApi(
        http: http,
        env: {
          'ADMOB_ACCESS_TOKEN': 'token',
          'GOOGLE_CLOUD_QUOTA_PROJECT': 'proj-2',
        },
        processes: _GcloudRunner(),
      );
      expect((await headersOf(client, http))['x-goog-user-project'], 'proj-2');
    });

    test('a missing or unparsable ADC file is not an error', () {
      final dir = Directory.systemTemp.createTempSync('admob-adc-bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(AdmobApi.adcQuotaProject({'CLOUDSDK_CONFIG': dir.path}), isNull);
      File(p.join(dir.path, 'application_default_credentials.json'))
          .writeAsStringSync('not json');
      expect(AdmobApi.adcQuotaProject({'CLOUDSDK_CONFIG': dir.path}), isNull);
      expect(AdmobApi.adcQuotaProject(const {}), isNull);
    });

    test('HOME is where gcloud keeps it by default', () {
      expect(AdmobApi.adcPath({'HOME': '/home/dev'}),
          '/home/dev/.config/gcloud/application_default_credentials.json');
      expect(AdmobApi.adcPath({'CLOUDSDK_CONFIG': '/custom'}),
          '/custom/application_default_credentials.json');
    });
  });

  group('AdmobApi resources', () {
    test('a declared publisher ID skips the account listing', () async {
      final http = FakeHttpJsonClient((_, _, _) => JsonResponse(404, null));
      final client = AdmobApi(
          http: http, env: const {'ADMOB_ACCESS_TOKEN': 'token'});
      expect(await client.accountName(publisherId: 'pub-1234567890123456'),
          account);
      expect(http.requests, isEmpty);
    });

    test('the first visible account is used when none is declared', () async {
      final client = api(
          handler: (_, _, _) => JsonResponse(200, {
                'account': [
                  {'name': account, 'publisherId': 'pub-1234567890123456'},
                ],
              }));
      expect(await client.accountName(), account);
    });

    test('an account-less credential says how to fix it', () async {
      final client =
          api(handler: (_, _, _) => JsonResponse(200, {'account': []}));
      await expectLater(
        client.accountName,
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('admob.publisher_id'))),
      );
    });

    test('listApps follows nextPageToken', () async {
      final client = api(handler: (method, uri, body) {
        final page = uri.queryParameters['pageToken'];
        if (page == null) {
          return JsonResponse(200, {
            'apps': [
              {'appId': 'ca-app-pub-1~1', 'platform': 'IOS'},
            ],
            'nextPageToken': 'page-2',
          });
        }
        return JsonResponse(200, {
          'apps': [
            {'appId': 'ca-app-pub-1~2', 'platform': 'ANDROID'},
          ],
        });
      });
      final apps = await client.listApps(account);
      expect(apps.map((app) => app.appId), ['ca-app-pub-1~1', 'ca-app-pub-1~2']);
    });

    test('an app carries the store ID and the display name it has', () async {
      final client = api(
          handler: (_, _, _) => JsonResponse(200, {
                'apps': [
                  {
                    'appId': 'ca-app-pub-1~1',
                    'platform': 'ANDROID',
                    'linkedAppInfo': {
                      'appStoreId': 'com.example.app',
                      'displayName': 'Store name',
                    },
                    'manualAppInfo': {'displayName': 'Manual name'},
                  },
                ],
              }));
      final app = (await client.listApps(account)).single;
      expect(app.storeId, 'com.example.app');
      // A linked app shows the store name in AdMob's own UI.
      expect(app.displayName, 'Store name');
    });

    test('a 403 on listing points at the scope and the API', () async {
      final client = api(
          handler: (_, _, _) => JsonResponse(403, {
                'error': {'message': 'Request had insufficient scopes'},
              }));
      await expectLater(
        () => client.listAdUnits(account),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('admob.readonly'))
            .having((e) => e.message, 'message',
                contains('insufficient scopes'))),
      );
    });

    test('createApp returns null on the limited-access 403', () async {
      final client = api(
          handler: (method, uri, body) => method == 'POST'
              ? JsonResponse(403, {
                  'error': {'message': 'The caller does not have permission'},
                })
              : JsonResponse(404, null));
      expect(
          await client.createApp(account,
              platform: 'IOS', displayName: 'My App'),
          isNull);
    });

    test('createAdUnit sends the format and its ad types', () async {
      final http = FakeHttpJsonClient((method, uri, body) => JsonResponse(200, {
            'adUnitId': 'ca-app-pub-1/9',
            'appId': 'ca-app-pub-1~1',
            'displayName': 'banner_main',
            'adFormat': 'BANNER',
          }));
      final client = AdmobApi(
          http: http, env: const {'ADMOB_ACCESS_TOKEN': 'token'});
      final unit = await client.createAdUnit(
        account,
        appId: 'ca-app-pub-1~1',
        displayName: 'banner_main',
        adFormat: 'BANNER',
      );
      expect(unit?.adUnitId, 'ca-app-pub-1/9');
      final body = http.requests.single.$3 as Map;
      // A banner never serves video.
      expect(body['adTypes'], ['RICH_MEDIA']);
      expect(AdmobApi.adTypesFor('REWARDED'), ['RICH_MEDIA', 'VIDEO']);
    });

    test('an unexpected failure keeps the status and the message', () async {
      final client = api(
          handler: (_, _, _) => JsonResponse(500, {
                'error': {'message': 'Backend error'},
              }));
      await expectLater(
        () => client.listApps(account),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('500'))
            .having((e) => e.message, 'message', contains('Backend error'))),
      );
    });
  });
}
