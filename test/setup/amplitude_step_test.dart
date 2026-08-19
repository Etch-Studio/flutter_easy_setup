import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../helpers/fake_http_json_client.dart';

/// Records `flutter pub add` without running it.
class _PubProcessRunner extends ProcessRunner {
  final streamed = <List<String>>[];

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
    return 0;
  }
}

/// Stands in for a network that is down.
class _OfflineHttpClient implements HttpJsonClient {
  @override
  Future<JsonResponse> get(Uri uri, {Map<String, String> headers = const {}}) =>
      throw SetupException('Could not reach ${uri.host}: no route to host');

  @override
  Future<JsonResponse> post(Uri uri,
          {Map<String, String> headers = const {}, Object? body}) =>
      throw SetupException('Could not reach ${uri.host}: no route to host');

  @override
  Future<JsonResponse> postForm(Uri uri,
          {Map<String, String> headers = const {},
          Map<String, String> fields = const {}}) =>
      throw SetupException('Could not reach ${uri.host}: no route to host');

  @override
  Future<JsonResponse> delete(Uri uri,
          {Map<String, String> headers = const {}}) =>
      throw SetupException('Could not reach ${uri.host}: no route to host');
}

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('amplitude_step_test');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config([String section = 'amplitude:']) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: My App, bundle_id: com.x }
$section
''') as Map);

  SetupContext context({
    ProjectConfig? cfg,
    Map<String, String> env = const {'AMPLITUDE_API_KEY': 'prod-key'},
    HttpJsonClient? http,
    ProcessRunner? processes,
    bool dryRun = false,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: env,
        processes: processes ?? _PubProcessRunner(),
        http: http,
        dryRun: dryRun,
        out: out,
      );

  /// Amplitude checks the key before the batch, so an accepted key answers
  /// 200 with nothing ingested and a rejected one names itself.
  JsonResponse ingestion(String method, Uri uri, Object? body) {
    final key = (body as Map)['api_key'];
    if (key == 'bad-key') {
      return JsonResponse(400, {'code': 400, 'error': 'Invalid API key: $key'});
    }
    return JsonResponse(200, {'code': 200, 'events_ingested': 0});
  }

  Map<String, Object?> envJson(String name) =>
      json.decode(File(p.join(tempDir.path, name)).readAsStringSync())
          as Map<String, Object?>;

  group('AmplitudeStep', () {
    test('verifies the key and writes it to the prod env file only', () async {
      final http = FakeHttpJsonClient(ingestion);
      await AmplitudeStep().run(context(http: http));

      expect(http.requests.single.$2.toString(),
          'https://api2.amplitude.com/2/httpapi');
      // The probe carries no events, so verification cannot pollute data.
      expect((http.requests.single.$3 as Map)['events'], isEmpty);
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'prod-key');
      // No dev key → debug builds get an empty one, which no-ops the SDK.
      expect(envJson('env.json')['AMPLITUDE_API_KEY'], '');
      expect(out.toString(), contains('accepted by Amplitude'));
      expect(out.toString(), contains('AMPLITUDE_DEV_API_KEY is not set'));
    });

    test('a dev key goes to env.json and is verified too', () async {
      final http = FakeHttpJsonClient(ingestion);
      await AmplitudeStep().run(context(
        http: http,
        env: const {
          'AMPLITUDE_API_KEY': 'prod-key',
          'AMPLITUDE_DEV_API_KEY': 'dev-key',
        },
      ));
      expect(envJson('env.json')['AMPLITUDE_API_KEY'], 'dev-key');
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'prod-key');
      expect(http.requests, hasLength(2));
    });

    test('a custom api_key_env is read instead of the default', () async {
      await AmplitudeStep().run(context(
        cfg: config('amplitude:\n  api_key_env: DIARY_AMPLITUDE_KEY'),
        http: FakeHttpJsonClient(ingestion),
        env: const {'DIARY_AMPLITUDE_KEY': 'other-key'},
      ));
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'other-key');
    });

    test('a missing key explains the one console step', () async {
      await expectLater(
        () => AmplitudeStep().run(context(env: const {})),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('AMPLITUDE_API_KEY'))
            .having((e) => e.message, 'message',
                contains('no project-creation API'))),
      );
    });

    test('a key Amplitude rejects fails before anything is written', () async {
      await expectLater(
        () => AmplitudeStep().run(context(
          http: FakeHttpJsonClient(ingestion),
          env: const {'AMPLITUDE_API_KEY': 'bad-key'},
        )),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('Invalid API key'))),
      );
      expect(File(p.join(tempDir.path, 'env.prod.json')).existsSync(), isFalse);
    });

    test('a network problem is a warning, not a wrong key', () async {
      await AmplitudeStep().run(context(http: _OfflineHttpClient()));
      expect(out.toString(), contains('Could not verify AMPLITUDE_API_KEY'));
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'prod-key');
    });

    test('a 5xx probe is inconclusive, never an approval', () async {
      await AmplitudeStep().run(context(
        http: FakeHttpJsonClient(
            (_, _, _) => JsonResponse(503, {'error': 'service unavailable'})),
      ));
      expect(out.toString(), contains('Could not verify AMPLITUDE_API_KEY'));
      expect(out.toString(), isNot(contains('accepted by Amplitude')));
      // The key itself may well be fine, so the run still converges.
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'prod-key');
    });

    test('verify: false skips the probe entirely', () async {
      final http = FakeHttpJsonClient(ingestion);
      await AmplitudeStep().run(context(
        cfg: config('amplitude:\n  verify: false'),
        http: http,
      ));
      expect(http.requests, isEmpty);
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'prod-key');
    });

    test('region: eu probes the EU host and records the server zone',
        () async {
      final http = FakeHttpJsonClient(ingestion);
      await AmplitudeStep().run(context(
        cfg: config('amplitude:\n  region: eu'),
        http: http,
      ));
      expect(http.requests.single.$2.host, 'api.eu.amplitude.com');
      expect(envJson('env.prod.json')['AMPLITUDE_SERVER_ZONE'], 'EU');
    });

    test('back to region us prunes the stale server zone', () async {
      await AmplitudeStep().run(context(
        cfg: config('amplitude:\n  region: eu'),
        http: FakeHttpJsonClient(ingestion),
      ));
      await AmplitudeStep().run(context(http: FakeHttpJsonClient(ingestion)));
      expect(envJson('env.prod.json').containsKey('AMPLITUDE_SERVER_ZONE'),
          isFalse);
    });

    test('keys the step does not own are preserved', () async {
      File(p.join(tempDir.path, 'env.prod.json'))
          .writeAsStringSync('{"SENTRY_DSN": "https://x@o1.ingest/1"}');
      await AmplitudeStep().run(context(http: FakeHttpJsonClient(ingestion)));
      expect(envJson('env.prod.json')['SENTRY_DSN'],
          'https://x@o1.ingest/1');
    });

    test('an unrelated AMPLITUDE_* key the developer added survives',
        () async {
      File(p.join(tempDir.path, 'env.prod.json')).writeAsStringSync(
          '{"AMPLITUDE_SESSION_TIMEOUT": "1800"}');
      await AmplitudeStep().run(context(http: FakeHttpJsonClient(ingestion)));
      expect(envJson('env.prod.json')['AMPLITUDE_SESSION_TIMEOUT'], '1800');
      expect(envJson('env.prod.json')['AMPLITUDE_API_KEY'], 'prod-key');
    });

    test('is idempotent — a second run rewrites nothing', () async {
      await AmplitudeStep().run(context(http: FakeHttpJsonClient(ingestion)));
      final first = File(p.join(tempDir.path, 'env.prod.json'))
          .readAsStringSync();
      out.clear();
      await AmplitudeStep().run(context(http: FakeHttpJsonClient(ingestion)));
      expect(File(p.join(tempDir.path, 'env.prod.json')).readAsStringSync(),
          first);
      expect(out.toString(), contains('already up to date'));
    });

    test('the amplitude_flutter dependency is added once', () async {
      File(p.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: my_app\ndependencies:\n  path: ^1.9.0\n');
      final processes = _PubProcessRunner();
      await AmplitudeStep().run(context(
        http: FakeHttpJsonClient(ingestion),
        processes: processes,
      ));
      expect(processes.streamed.single,
          ['flutter', 'pub', 'add', 'amplitude_flutter']);
    });

    test('sdk: false leaves the pubspec alone', () async {
      File(p.join(tempDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: my_app\ndependencies:\n  path: ^1.9.0\n');
      final processes = _PubProcessRunner();
      await AmplitudeStep().run(context(
        cfg: config('amplitude:\n  sdk: false'),
        http: FakeHttpJsonClient(ingestion),
        processes: processes,
      ));
      expect(processes.streamed, isEmpty);
    });

    test('dry-run touches neither the network nor the files', () async {
      final http = FakeHttpJsonClient(ingestion);
      await AmplitudeStep()
          .run(context(http: http, env: const {}, dryRun: true));
      expect(http.requests, isEmpty);
      expect(File(p.join(tempDir.path, 'env.prod.json')).existsSync(), isFalse);
      expect(out.toString(), contains('[dry-run]'));
    });

    test('an invalid region is rejected at parse time', () {
      expect(
        () => config('amplitude:\n  region: apac'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('us | eu'))),
      );
    });
  });
}
