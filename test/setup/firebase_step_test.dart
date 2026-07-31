import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

class FirebaseFakeProcessRunner extends ProcessRunner {
  final Map<String, String> installed;
  final List<String> existingProjects;
  final ran = <(String, List<String>)>[];
  final streamed = <(String, List<String>)>[];
  bool createFails;

  /// When set, `projects:list` returns this raw stdout instead of JSON.
  String? listStdoutOverride;

  FirebaseFakeProcessRunner({
    this.installed = const {
      'firebase': 'firebase 14.0.0',
      'flutterfire': 'flutterfire 1.0.0',
    },
    this.existingProjects = const [],
    this.createFails = false,
    this.listStdoutOverride,
  });

  @override
  Future<String?> which(String command) async =>
      installed.containsKey(command) ? '/usr/bin/$command' : null;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    ran.add((executable, arguments));
    if (executable == 'firebase' && arguments.first == 'projects:list') {
      if (listStdoutOverride != null) {
        return ProcessResult(0, 0, listStdoutOverride!, '');
      }
      final projects =
          existingProjects.map((id) => '{"projectId": "$id"}').join(',');
      return ProcessResult(0, 0, '{"status":"success","result":[$projects]}', '');
    }
    if (executable == 'firebase' && arguments.first == 'projects:create') {
      return createFails
          ? ProcessResult(0, 1, '', 'ID already taken')
          : ProcessResult(0, 0, '{"status":"success"}', '');
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<int> stream(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    streamed.add((executable, arguments));
    return 0;
  }
}

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('firebase_step_test');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  ProjectConfig config(
          [String section = 'firebase: { project_id: my-org-myapp }']) =>
      ProjectConfig.fromYaml(loadYaml('''
app: { name: My App, bundle_id: com.x }
$section
''') as Map);

  SetupContext context({
    ProjectConfig? cfg,
    FirebaseFakeProcessRunner? processes,
    bool dryRun = false,
  }) =>
      SetupContext(
        projectRoot: tempDir.path,
        config: cfg ?? config(),
        env: const {},
        processes: processes ?? FirebaseFakeProcessRunner(),
        dryRun: dryRun,
        out: out,
      );

  group('FirebaseStep', () {
    test('creates a missing project and runs flutterfire configure',
        () async {
      final processes = FirebaseFakeProcessRunner();
      await FirebaseStep().run(context(processes: processes));

      final create =
          processes.ran.firstWhere((r) => r.$2.first == 'projects:create');
      expect(create.$2, containsAllInOrder(['projects:create', 'my-org-myapp']));
      expect(create.$2, containsAllInOrder(['--display-name', 'My App']));

      expect(processes.streamed, hasLength(1));
      final flutterfire = processes.streamed.single;
      expect(flutterfire.$1, 'flutterfire');
      expect(flutterfire.$2, contains('--project=my-org-myapp'));
      expect(flutterfire.$2, contains('--platforms=android,ios'));
      expect(flutterfire.$2, contains('--yes'));
    });

    test('skips creation when the project already exists', () async {
      final processes =
          FirebaseFakeProcessRunner(existingProjects: ['my-org-myapp']);
      await FirebaseStep().run(context(processes: processes));
      expect(processes.ran.where((r) => r.$2.first == 'projects:create'),
          isEmpty);
      expect(out.toString(), contains('already exists'));
    });

    test('analytics: true prints the console link reminder', () async {
      await FirebaseStep().run(context(
          cfg: config('firebase: { project_id: my-org-myapp, '
              'analytics: true }')));
      expect(out.toString(), contains('Link Google Analytics'));
      expect(out.toString(), contains('my-org-myapp'));
    });

    test('missing project_id fails with guidance', () async {
      await expectLater(
        () => FirebaseStep().run(context(cfg: config('firebase: {}'))),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('firebase.project_id'))),
      );
    });

    test('missing CLIs fail with install guidance', () async {
      final processes = FirebaseFakeProcessRunner(installed: const {});
      await expectLater(
        () => FirebaseStep().run(context(processes: processes)),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('firebase CLI not found'))),
      );
    });

    test('surfaces a failed create (globally taken ID)', () async {
      final processes = FirebaseFakeProcessRunner(createFails: true);
      await expectLater(
        () => FirebaseStep().run(context(processes: processes)),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('taken'))),
      );
    });

    test('unparseable projects:list output fails instead of creating',
        () async {
      final processes =
          FirebaseFakeProcessRunner(listStdoutOverride: 'not json at all');
      await expectLater(
        () => FirebaseStep().run(context(processes: processes)),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('projects:list'))),
      );
      expect(processes.ran.where((r) => r.$2.first == 'projects:create'),
          isEmpty);
    });

    test('dry-run runs no commands', () async {
      final processes = FirebaseFakeProcessRunner();
      await FirebaseStep().run(context(processes: processes, dryRun: true));
      expect(processes.ran, isEmpty);
      expect(processes.streamed, isEmpty);
      expect(out.toString(), contains('[dry-run]'));
    });
  });
}
