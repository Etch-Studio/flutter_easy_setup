import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Step double that records whether it ran.
class _RecordingStep extends SetupStep {
  @override
  final String name;
  final bool configured;
  bool ran = false;

  _RecordingStep(this.name, {this.configured = true});

  @override
  bool isConfigured(ProjectConfig config) => configured;

  @override
  Future<void> run(SetupContext context) async {
    ran = true;
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('setup_command_test');
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(
        'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n');
    File(p.join(tempDir.path, 'easy_setup.yaml'))
        .writeAsStringSync('app: { name: X, bundle_id: com.x }\n');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  group('SetupCommand', () {
    test('runs configured steps and logs skipped ones', () async {
      final configured = _RecordingStep('a');
      final unconfigured = _RecordingStep('b', configured: false);
      final out = StringBuffer();
      final exitCode = await SetupCommand.run(
        projectRoot: tempDir.path,
        steps: [configured, unconfigured],
        out: out,
      );
      expect(exitCode, 0);
      expect(configured.ran, isTrue);
      expect(unconfigured.ran, isFalse);
      expect(out.toString(), contains('b: skipped'));
      expect(out.toString(), contains('Setup complete (1 step(s))'));
    });

    test('--only runs exactly that step', () async {
      final a = _RecordingStep('a');
      final b = _RecordingStep('b');
      await SetupCommand.run(
        projectRoot: tempDir.path,
        steps: [a, b],
        only: 'b',
        out: StringBuffer(),
      );
      expect(a.ran, isFalse);
      expect(b.ran, isTrue);
    });

    test('--only with an unknown step lists the available ones', () async {
      expect(
        () => SetupCommand.run(
          projectRoot: tempDir.path,
          steps: [_RecordingStep('a')],
          only: 'zzz',
          out: StringBuffer(),
        ),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('available: a'))),
      );
    });

    test('--only for an unconfigured step explains the missing section',
        () async {
      expect(
        () => SetupCommand.run(
          projectRoot: tempDir.path,
          steps: [_RecordingStep('a', configured: false)],
          only: 'a',
          out: StringBuffer(),
        ),
        throwsA(isA<SetupException>().having(
            (e) => e.message, 'message', contains('not configured'))),
      );
    });

    test('nothing configured → helpful notice', () async {
      final out = StringBuffer();
      await SetupCommand.run(
        projectRoot: tempDir.path,
        steps: [_RecordingStep('a', configured: false)],
        out: out,
      );
      expect(out.toString(), contains('Nothing to do'));
    });

    test('default steps cover all Setup Kit sections', () {
      expect(SetupCommand.defaultSteps().map((s) => s.name), [
        'sentry',
        'firebase',
        'admob',
        'ios_capabilities',
        'branding',
        'screenshots',
      ]);
    });
  });
}
