import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

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
}

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sentry_step_test');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String sentrySection = 'sentry: { org: my-org }']) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: My App, bundle_id: com.x }
$sentrySection
''') as Map);

  SetupContext context({
    ProjectConfig? cfg,
    Map<String, String> env = const {'SENTRY_ORG_TOKEN': 'sntrys_token'},
    HttpJsonClient? http,
    bool dryRun = false,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        http: http,
        dryRun: dryRun,
        out: out,
      );

  JsonResponse happyHandler(String method, Uri uri, Object? body) {
    if (uri.path.endsWith('/teams/')) {
      return JsonResponse(200, [
        {'slug': 'team-a'},
      ]);
    }
    if (method == 'POST' && uri.path.contains('/projects/')) {
      return JsonResponse(201, {'slug': 'my-app'});
    }
    if (uri.path.endsWith('/keys/')) {
      return JsonResponse(200, [
        {
          'dsn': {'public': 'https://abc@o1.ingest.sentry.io/42'},
        },
      ]);
    }
    return JsonResponse(404, null);
  }

  group('SentryStep', () {
    test('creates the project, fetches the DSN, and writes env files',
        () async {
      final http = FakeHttpJsonClient(happyHandler);
      await SentryStep().run(context(http: http));

      // Team resolved → project created under it → keys fetched.
      final posted = http.requests.firstWhere((r) => r.$1 == 'POST');
      expect(posted.$2.path, '/api/0/teams/my-org/team-a/projects/');
      // Project slug derived from the app name.
      expect((posted.$3 as Map)['slug'], 'my-app');

      for (final name in ['env.json', 'env.prod.json']) {
        final env = json.decode(
            File(p.join(tempDir.path, name)).readAsStringSync()) as Map;
        expect(env['SENTRY_DSN'], 'https://abc@o1.ingest.sentry.io/42');
      }
    });

    test('409 on create means the project already exists (idempotent)',
        () async {
      final http = FakeHttpJsonClient((method, uri, body) =>
          method == 'POST' && uri.path.contains('/projects/')
              ? JsonResponse(409, {'detail': 'exists'})
              : happyHandler(method, uri, body));
      await SentryStep().run(context(http: http));
      expect(out.toString(), contains('already exists'));
      expect(File(p.join(tempDir.path, 'env.json')).existsSync(), isTrue);
    });

    test('explicit sentry.team and sentry.project skip discovery', () async {
      final http = FakeHttpJsonClient(happyHandler);
      await SentryStep().run(context(
        cfg: config('sentry: { org: my-org, team: mobile, project: diary }'),
        http: http,
      ));
      final posted = http.requests.firstWhere((r) => r.$1 == 'POST');
      expect(posted.$2.path, '/api/0/teams/my-org/mobile/projects/');
      expect((posted.$3 as Map)['slug'], 'diary');
      // No team-listing call was needed.
      expect(http.requests.where((r) => r.$2.path.endsWith('/teams/')),
          isEmpty);
    });

    test('missing token fails with issuance guidance', () async {
      await expectLater(
        () => SentryStep().run(context(env: const {})),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('SENTRY_ORG_TOKEN'))),
      );
    });

    test('failed project creation surfaces the HTTP status', () async {
      final http = FakeHttpJsonClient((method, uri, body) =>
          method == 'POST' && uri.path.contains('/projects/')
              ? JsonResponse(403, {'detail': 'nope'})
              : happyHandler(method, uri, body));
      await expectLater(
        () => SentryStep().run(context(http: http)),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('403'))),
      );
    });

    test('dry-run makes no HTTP calls and writes nothing', () async {
      final http = FakeHttpJsonClient(happyHandler);
      await SentryStep().run(context(http: http, env: const {}, dryRun: true));
      expect(http.requests, isEmpty);
      expect(File(p.join(tempDir.path, 'env.json')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
