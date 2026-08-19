import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/fake_http_json_client.dart';

/// Records `flutter pub add` instead of running it. With [hasSentryDeps] the
/// pubspec is treated as already carrying both packages.
class SentryFakeProcessRunner extends ProcessRunner {
  final bool hasSentryDeps;
  final streamed = <List<String>>[];

  SentryFakeProcessRunner({this.hasSentryDeps = false});

  @override
  Future<String?> which(String command) async => '/usr/bin/$command';

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add([executable, ...arguments]);
    if (hasSentryDeps) return 0;
    // Mimic pub add by appending the package to the pubspec.
    final pubspec = File('${workingDirectory!}/pubspec.yaml');
    final package = arguments.last.replaceFirst('dev:', '');
    pubspec.writeAsStringSync(
        '${pubspec.readAsStringSync()}\n$package: any\n');
    return 0;
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
    Map<String, String> env = const {'SENTRY_API_TOKEN': 'sntryu_token'},
    HttpJsonClient? http,
    ProcessRunner? processes,
    bool dryRun = false,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        processes: processes ?? SentryFakeProcessRunner(),
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
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('SENTRY_API_TOKEN'))
            // Organization tokens cannot create projects — say what does.
            .having((e) => e.message, 'message',
                contains('Internal Integration'))),
      );
    });

    test('the legacy SENTRY_ORG_TOKEN name is still accepted', () async {
      final http = FakeHttpJsonClient(happyHandler);
      await SentryStep().run(context(
        http: http,
        env: const {'SENTRY_ORG_TOKEN': 'sntryu_token'},
      ));
      expect(http.requests.where((r) => r.$1 == 'POST'), isNotEmpty);
    });

    test('a 403 on create names both things that cause it', () async {
      final http = FakeHttpJsonClient((method, uri, body) =>
          method == 'POST' && uri.path.contains('/projects/')
              ? JsonResponse(403, {
                  'detail':
                      'Your organization has disabled this feature for members.',
                })
              : happyHandler(method, uri, body));
      await expectLater(
        () => SentryStep().run(context(http: http)),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('project:write'))
            .having((e) => e.message, 'message',
                contains('org:write or team:admin'))
            // The server's own words stay in, they are the diagnosis.
            .having((e) => e.message, 'message',
                contains('disabled this feature for members'))),
      );
    });

    test('failed project creation surfaces the HTTP status', () async {
      final http = FakeHttpJsonClient((method, uri, body) =>
          method == 'POST' && uri.path.contains('/projects/')
              ? JsonResponse(500, {'detail': 'nope'})
              : happyHandler(method, uri, body));
      await expectLater(
        () => SentryStep().run(context(http: http)),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('500'))),
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

  group('SentryStep pubspec wiring', () {
    void writePubspec([String extra = '']) =>
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(
            'name: my_app\n'
            'dependencies:\n'
            '  path: ^1.9.0\n'
            '$extra');

    String pubspec() =>
        File(p.join(tempDir.path, 'pubspec.yaml')).readAsStringSync();

    test('adds both packages and the sentry_dart_plugin block', () async {
      writePubspec();
      final processes = SentryFakeProcessRunner();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: processes,
      ));

      expect(processes.streamed, [
        ['flutter', 'pub', 'add', 'sentry_flutter'],
        ['flutter', 'pub', 'add', 'dev:sentry_dart_plugin'],
      ]);
      final block = loadYaml(pubspec())['sentry'] as Map;
      expect(block['upload_debug_symbols'], true);
      expect(block['org'], 'my-org');
      // The slug the project was created with, not the app name.
      expect(block['project'], 'my-app');
    });

    test('an existing block is updated, not duplicated', () async {
      writePubspec('sentry:\n'
          '  upload_source_maps: true\n'
          '  project: stale-project\n');
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
      ));
      expect('sentry:'.allMatches(pubspec()), hasLength(1));
      final block = loadYaml(pubspec())['sentry'] as Map;
      expect(block['project'], 'my-app');
      expect(block['upload_source_maps'], true);
    });

    test('a second run leaves the pubspec untouched', () async {
      writePubspec();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
      ));
      final first = pubspec();
      out.clear();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(hasSentryDeps: true),
      ));
      expect(pubspec(), first);
      expect(out.toString(), contains('`sentry:` block up to date'));
    });

    test('upload_symbols: false adds no plugin and writes no block',
        () async {
      writePubspec();
      final processes = SentryFakeProcessRunner();
      await SentryStep().run(context(
        cfg: config('sentry: { org: my-org, upload_symbols: false }'),
        http: FakeHttpJsonClient(happyHandler),
        processes: processes,
      ));
      expect(processes.streamed, [
        ['flutter', 'pub', 'add', 'sentry_flutter'],
      ]);
      expect(pubspec(), isNot(contains('sentry:')));
    });

    test('opting out later turns an existing upload off', () async {
      writePubspec('sentry:\n'
          '  upload_debug_symbols: true\n'
          '  org: my-org\n'
          '  project: my-app\n');
      await SentryStep().run(context(
        cfg: config('sentry: { org: my-org, upload_symbols: false }'),
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(hasSentryDeps: true),
      ));
      expect(loadYaml(pubspec())['sentry']['upload_debug_symbols'], isFalse);
      expect(out.toString(), contains('Turned off upload_debug_symbols'));
    });

    test('a self-hosted url is dropped once the config moves back', () async {
      writePubspec('sentry:\n'
          '  upload_debug_symbols: true\n'
          '  url: https://sentry.internal\n');
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(hasSentryDeps: true),
      ));
      expect((loadYaml(pubspec())['sentry'] as Map).containsKey('url'),
          isFalse);
    });

    test('sdk: false leaves the runtime dependency to the developer',
        () async {
      writePubspec();
      final processes = SentryFakeProcessRunner();
      await SentryStep().run(context(
        cfg: config('sentry: { org: my-org, sdk: false }'),
        http: FakeHttpJsonClient(happyHandler),
        processes: processes,
      ));
      expect(processes.streamed, [
        ['flutter', 'pub', 'add', 'dev:sentry_dart_plugin'],
      ]);
    });

    test('a self-hosted SENTRY_URL is carried into the block', () async {
      writePubspec();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
        env: const {
          'SENTRY_API_TOKEN': 'sntryu_token',
          'SENTRY_URL': 'https://sentry.internal',
        },
      ));
      expect(loadYaml(pubspec())['sentry']['url'], 'https://sentry.internal');
    });

    test('sentry.io is the default and needs no url key', () async {
      writePubspec();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
      ));
      expect((loadYaml(pubspec())['sentry'] as Map).containsKey('url'),
          isFalse);
    });

    test('a missing build token is called out with the fix', () async {
      writePubspec();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
      ));
      expect(out.toString(), contains('export SENTRY_AUTH_TOKEN=<token>'));
      expect(out.toString(), contains('Organization Tokens'));
      // The plugin is a post-build command, so say so.
      expect(out.toString(), contains('flutter pub run sentry_dart_plugin'));
    });

    test('a build token that is already exported is not nagged about',
        () async {
      writePubspec();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
        env: const {
          'SENTRY_API_TOKEN': 'sntryu_token',
          'SENTRY_AUTH_TOKEN': 'sntrys_token',
        },
      ));
      expect(out.toString(), isNot(contains('export SENTRY_AUTH_TOKEN')));
    });

    test('a project without a pubspec still gets its DSN', () async {
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
      ));
      expect(File(p.join(tempDir.path, 'env.json')).existsSync(), isTrue);
      expect(out.toString(), contains('No pubspec.yaml'));
    });

    test('dry-run previews the pubspec work without doing it', () async {
      writePubspec();
      final before = pubspec();
      await SentryStep().run(context(
        http: FakeHttpJsonClient(happyHandler),
        processes: SentryFakeProcessRunner(),
        dryRun: true,
      ));
      expect(pubspec(), before);
      expect(out.toString(), contains('Would ensure sentry_dart_plugin'));
    });
  });
}
