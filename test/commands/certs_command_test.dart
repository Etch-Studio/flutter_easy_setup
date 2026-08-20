import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/fake_http_json_client.dart';

/// Records the fastlane invocations without running them.
class _CertsFakeProcessRunner extends ProcessRunner {
  final streamed = <(String, List<String>)>[];
  final int exitCode;

  _CertsFakeProcessRunner({this.exitCode = 0});

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add((executable, arguments));
    return exitCode;
  }
}

const _ascEnv = {
  'ASC_KEY_ID': 'KEY123',
  'ASC_ISSUER_ID': 'issuer-uuid',
  'ASC_KEY_P8': '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
};

/// Signing a real JWT needs a real EC key, so device listing tests use the
/// throwaway one from the shared helpers.
const _signableEnv = {
  'ASC_KEY_ID': 'KEY123',
  'ASC_ISSUER_ID': 'issuer-uuid',
  'ASC_KEY_P8': testEcPrivateKeyPem,
};

JsonResponse _devicesResponse(String method, Uri uri, Object? body) =>
    JsonResponse(200, {
      'data': [
        {
          'attributes': {
            'name': 'My iPhone',
            'udid': '00008101-001',
            'platform': 'IOS',
            'deviceClass': 'IPHONE',
            'status': 'ENABLED',
          },
        },
      ],
    });

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('certs_command_test');
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(
        'name: app\nversion: 1.0.0+1\ndependencies:\n  flutter:\n'
        '    sdk: flutter\n');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  void writeConfig([String iosSection = '''
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certs.git
''']) =>
      File(p.join(tempDir.path, 'easy_setup.yaml')).writeAsStringSync('''
app:
  name: My App
  bundle_id: com.example.app
$iosSection
''');

  Future<int> runCerts({
    String type = 'development',
    bool readonly = false,
    bool? apply,
    String? registerDeviceUdid,
    String? deviceName,
    bool listDevices = false,
    bool dryRun = false,
    Map<String, String> env = _ascEnv,
    _CertsFakeProcessRunner? processes,
    HttpJsonClient? http,
  }) =>
      CertsCommand.run(
        projectRoot: tempDir.path,
        type: type,
        readonly: readonly,
        apply: apply,
        registerDeviceUdid: registerDeviceUdid,
        deviceName: deviceName,
        listDevices: listDevices,
        dryRun: dryRun,
        env: env,
        processes: processes ?? _CertsFakeProcessRunner(),
        http: http,
        out: out,
      );

  group('CertsCommand', () {
    test('development syncs match and writes all three configurations',
        () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      expect(await runCerts(processes: processes), 0);

      expect(processes.streamed, hasLength(2));
      final match = processes.streamed[0].$2;
      expect(match.take(2), ['match', 'development']);
      expect(match, containsAllInOrder(['--app_identifier', 'com.example.app']));
      expect(match, containsAllInOrder(['--git_url', 'git@github.com:org/certs.git']));
      expect(match, containsAllInOrder(['--readonly', 'false']));
      // A device registered after the profile was stored has to force a
      // regeneration, or the profile comes back without it.
      expect(match, containsAllInOrder(['--force_for_new_devices', 'true']));

      final signing = processes.streamed[1].$2;
      expect(signing.take(2), ['run', 'update_code_signing_settings']);
      expect(signing, contains('build_configurations:Debug,Profile,Release'));
      expect(signing, contains('code_sign_identity:Apple Development'));
      expect(signing,
          contains('profile_name:match Development com.example.app'));
      expect(out.toString(), contains('Debug/Profile/Release now sign with'));
    });

    test('adhoc only fetches — its profile cannot install on a device',
        () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(type: 'adhoc', processes: processes);

      expect(processes.streamed, hasLength(1));
      expect(processes.streamed.single.$2.take(2), ['match', 'adhoc']);
      expect(out.toString(), contains('Xcode project untouched'));
      // "Adhoc" would be the wrong name — match spells it AdHoc.
      expect(out.toString(), contains('match AdHoc com.example.app'));
    });

    test('--apply writes adhoc into Release when asked', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(type: 'adhoc', apply: true, processes: processes);

      final signing = processes.streamed[1].$2;
      expect(signing, contains('build_configurations:Release'));
      expect(signing, contains('code_sign_identity:Apple Distribution'));
    });

    test('--no-apply leaves the project alone for development too', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(apply: false, processes: processes);
      expect(processes.streamed, hasLength(1));
    });

    test('--register-device runs before match, with a default name', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(
          registerDeviceUdid: '00008101-001', processes: processes);

      final register = processes.streamed.first.$2;
      expect(register.take(2), ['run', 'register_device']);
      expect(register, contains('udid:00008101-001'));
      expect(register, contains('name:Device 00008101-001'));
      expect(processes.streamed[1].$2.take(2), ['match', 'development']);
    });

    test('--device-name is used when given', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(
        registerDeviceUdid: '00008101-001',
        deviceName: 'My iPhone',
        processes: processes,
      );
      expect(processes.streamed.first.$2, contains('name:My iPhone'));
    });

    test('readonly is passed through', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(readonly: true, processes: processes);
      expect(processes.streamed.first.$2,
          containsAllInOrder(['--readonly', 'true']));
    });

    test('dry-run runs nothing and writes no key file', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(dryRun: true, processes: processes);
      expect(processes.streamed, isEmpty);
      expect(out.toString(), contains('[dry-run]'));
      expect(out.toString(), contains('<api_key.json>'));
    });

    test('a missing ios section explains what to add', () async {
      writeConfig('');
      await expectLater(
        runCerts,
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('match_git_url'))),
      );
    });

    test('a half-configured ios section is not enough', () async {
      writeConfig('ios:\n  team_id: ABCDE12345\n');
      await expectLater(
        runCerts,
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('match_git_url'))),
      );
    });

    test('missing ASC credentials name every variable', () async {
      writeConfig();
      await expectLater(
        () => runCerts(env: const {}),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('ASC_KEY_ID'))
            .having((e) => e.message, 'message', contains('ASC_KEY_P8_PATH'))),
      );
    });

    test('an unknown type lists the ones that exist', () async {
      writeConfig();
      await expectLater(
        () => runCerts(type: 'enterprise'),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            contains('development | adhoc | appstore'))),
      );
    });

    test('a failing fastlane step surfaces the exit code', () async {
      writeConfig();
      await expectLater(
        () => runCerts(processes: _CertsFakeProcessRunner(exitCode: 70)),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('exit code 70'))),
      );
    });
  });

  group('CertsCommand --list-devices', () {
    test('answers the question and stops — nothing is synced', () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      expect(
        await runCerts(
          listDevices: true,
          env: _signableEnv,
          http: FakeHttpJsonClient(_devicesResponse),
          processes: processes,
        ),
        0,
      );
      expect(processes.streamed, isEmpty);
      expect(out.toString(), contains('1 registered device(s)'));
      expect(out.toString(), contains('IPHONE IOS | ENABLED | 00008101-001'));
    });

    test('a UDID that is present is marked, and the sync still runs',
        () async {
      writeConfig();
      final processes = _CertsFakeProcessRunner();
      await runCerts(
        listDevices: true,
        registerDeviceUdid: '00008101-001',
        env: _signableEnv,
        http: FakeHttpJsonClient(_devicesResponse),
        processes: processes,
      );
      expect(out.toString(), contains('00008101-001 | My iPhone ←'));
      // A register + a match, since a UDID was given.
      expect(processes.streamed, hasLength(3));
    });

    test('a UDID that is missing is called out', () async {
      writeConfig();
      await runCerts(
        listDevices: true,
        registerDeviceUdid: 'deadbeef-999',
        env: _signableEnv,
        http: FakeHttpJsonClient(_devicesResponse),
      );
      expect(out.toString(), contains('deadbeef-999 is not registered yet'));
    });

    test('dry-run does not call the API', () async {
      writeConfig();
      final http = FakeHttpJsonClient(_devicesResponse);
      await runCerts(
          listDevices: true, dryRun: true, env: _signableEnv, http: http);
      expect(http.requests, isEmpty);
      expect(out.toString(), contains('Would list the registered devices'));
    });
  });

  group('MatchProfile', () {
    test('profile names match what match generates', () {
      expect(MatchProfile.development.profileName('com.x'),
          'match Development com.x');
      // Not "Adhoc" — this is the one that catches people.
      expect(MatchProfile.adhoc.profileName('com.x'), 'match AdHoc com.x');
      expect(MatchProfile.appstore.profileName('com.x'), 'match AppStore com.x');
    });

    test('only development writes itself into the project by default', () {
      expect(MatchProfile.development.appliesByDefault, isTrue);
      expect(MatchProfile.adhoc.appliesByDefault, isFalse);
      expect(MatchProfile.appstore.appliesByDefault, isFalse);
    });

    test('deploy and certs build the same match call', () {
      final arguments = IosSigning.matchArguments(
        profile: MatchProfile.appstore,
        bundleId: 'com.x',
        gitUrl: 'git@github.com:org/certs.git',
        teamId: 'TEAM',
        apiKeyPath: '/tmp/api_key.json',
        readonly: true,
      );
      expect(arguments.take(2), ['match', 'appstore']);
      expect(arguments, containsAllInOrder(['--readonly', 'true']));
    });
  });
}
