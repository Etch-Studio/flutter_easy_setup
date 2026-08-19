import 'dart:convert';
import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// simctl/flutter stand-in: records the commands and answers `simctl list`.
class _FakeProcesses implements ProcessRunner {
  final List<List<String>> calls = [];
  final List<({String udid, String name})> simulators;

  /// Screen names the fake tour requests, in order.
  final List<String>? requestOnDrive;
  String? containerPath;

  /// Every path `simctl io screenshot` was asked to write.
  final List<String> shots = [];

  _FakeProcesses({
    this.simulators = const [(udid: 'UDID-1', name: 'iPhone 16 Pro Max')],
    this.requestOnDrive,
  });

  List<String> get commandLine =>
      calls.map((call) => call.join(' ')).toList();

  bool ran(String fragment) =>
      commandLine.any((line) => line.contains(fragment));

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    calls.add([executable, ...arguments]);
    if (arguments.take(3).join(' ') == 'simctl list devices') {
      return ProcessResult(
          0,
          0,
          jsonEncode({
            'devices': {
              'com.apple.CoreSimulator.SimRuntime.iOS-18-0': [
                for (final simulator in simulators)
                  {
                    'udid': simulator.udid,
                    'name': simulator.name,
                    'isAvailable': true,
                    'state': 'Shutdown',
                  }
              ],
            },
          }),
          '');
    }
    if (arguments.contains('get_app_container')) {
      return containerPath == null
          ? ProcessResult(0, 2, '', 'No such app')
          : ProcessResult(0, 0, '$containerPath\n', '');
    }
    if (arguments.contains('screenshot')) {
      shots.add(arguments.last);
      File(arguments.last)
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47]);
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<int> stream(String executable, List<String> arguments,
      {String? workingDirectory, Map<String, String>? environment}) async {
    calls.add([executable, ...arguments]);
    // Stand in for the app installing and the tour asking for captures,
    // in exactly the order the generated harness does it.
    if (requestOnDrive != null && containerPath != null) {
      final tmp = Directory(p.join(containerPath!, 'tmp'))
        ..createSync(recursive: true);
      final done = File(p.join(tmp.path, CaptureTemplates.doneFileName));
      for (final name in requestOnDrive!) {
        if (done.existsSync()) done.deleteSync();
        File(p.join(tmp.path, CaptureTemplates.requestFileName))
            .writeAsStringSync(name);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          if (done.existsSync() && done.readAsStringSync().trim() == name) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    }
    return 0;
  }

  @override
  Future<String?> which(String command) async => '/usr/bin/$command';

  @override
  Future<String?> versionOf(String command,
          {List<String> arguments = const ['--version'],
          Pattern? linePattern}) async =>
      '1.0.0';
}

void main() {
  late Directory tempDir;
  late StringBuffer out;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('capture_command_test');
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_app
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  integration_test:
    sdk: flutter
''');
    File(p.join(tempDir.path, 'easy_setup.yaml')).writeAsStringSync('''
app: { name: My App, bundle_id: com.example.app }
screenshots:
  locales: [ko]
  devices: [iphone_6_9, android_phone]
''');
    out = StringBuffer();
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<int> capture(
    _FakeProcesses processes, {
    bool dryRun = false,
    String? device,
    String? locale,
    String? simulator,
  }) =>
      CaptureCommand.run(
        projectRoot: tempDir.path,
        dryRun: dryRun,
        device: device,
        locale: locale,
        simulator: simulator,
        processes: processes,
        out: out,
      );

  String read(String relative) =>
      File(p.join(tempDir.path, relative)).readAsStringSync();

  group('CaptureCommand scaffolding', () {
    test('seeds the tour once and keeps the harness in step', () async {
      final processes = _FakeProcesses();
      await capture(processes);

      expect(read(CaptureTemplates.tourRelativePath),
          contains('package:my_app/main.dart'));
      expect(read(CaptureTemplates.harnessRelativePath),
          contains(CaptureTemplates.requestFileName));
      expect(read(CaptureTemplates.driverRelativePath),
          contains('integrationDriver'));

      // The tour is the project's; the harness is easy_setup's.
      File(p.join(tempDir.path, CaptureTemplates.tourRelativePath))
          .writeAsStringSync('// my tour');
      File(p.join(tempDir.path, CaptureTemplates.harnessRelativePath))
          .writeAsStringSync('// tampered');
      await capture(_FakeProcesses());
      expect(read(CaptureTemplates.tourRelativePath), '// my tour');
      expect(read(CaptureTemplates.harnessRelativePath),
          contains(CaptureTemplates.requestFileName));
    });

    test('a tour that predates the harness is called out', () async {
      // The trap a project with an existing tour falls into: its markers
      // go somewhere the watcher never looks, and every shot times out
      // after a full build.
      File(p.join(tempDir.path, CaptureTemplates.tourRelativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
void main() {
  // writes its own marker into Documents/, the watcher polls tmp/
}
''');
      await capture(_FakeProcesses());
      expect(out.toString(), contains('does not use store_screenshot_harness'));
    });

    test('the generated tour is not called out', () async {
      await capture(_FakeProcesses()); // seeds the tour
      out.clear();
      await capture(_FakeProcesses()); // second run checks it
      expect(out.toString(), isNot(contains('does not use')));
    });

    test('a tour that speaks the protocol without the import is accepted',
        () async {
      File(p.join(tempDir.path, CaptureTemplates.tourRelativePath))
        ..createSync(recursive: true)
        ..writeAsStringSync(
            "void main() { File('\$dir/${CaptureTemplates.requestFileName}'); }");
      await capture(_FakeProcesses());
      expect(out.toString(), isNot(contains('does not use')));
    });

    test('a missing integration_test dependency stops with the exact lines',
        () async {
      File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync(
          'name: my_app\ndependencies:\n  flutter:\n    sdk: flutter\n');
      await expectLater(
        () => capture(_FakeProcesses()),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            allOf(contains('integration_test:'), contains('sdk: flutter')))),
      );
    });
  });

  group('CaptureCommand run', () {
    test('boots, freezes the status bar, drives, and restores it', () async {
      final processes = _FakeProcesses();
      await capture(processes);

      expect(processes.ran('simctl boot UDID-1'), isTrue);
      expect(processes.ran('simctl bootstatus UDID-1'), isTrue);
      expect(processes.ran('status_bar UDID-1 override'), isTrue);
      expect(processes.ran('--time 9:41'), isTrue);
      // A stale data container would strand the watcher.
      expect(processes.ran('simctl uninstall UDID-1 com.example.app'), isTrue);
      expect(processes.ran('flutter drive'), isTrue);
      expect(processes.ran('--dart-define=SCREENSHOT_LOCALE=ko'), isTrue);
      expect(processes.ran('-d UDID-1'), isTrue);
      // Restored even though nothing failed.
      expect(processes.ran('status_bar UDID-1 clear'), isTrue);
    });

    // Also covers the race that matters most: the tour writes its first
    // request while the watcher is still resolving the app container, so
    // the watcher must not clear markers it finds when it gets there.
    test('answers each request exactly once, in order', () async {
      final processes =
          _FakeProcesses(requestOnDrive: ['01_home', '02_detail', '03_stats'])
            ..containerPath = p.join(tempDir.path, 'container');
      await capture(processes);

      final rawDir = p.join(tempDir.path, ScreenshotsStep.rawRelativeDir,
          'ko', 'iphone_6_9');
      expect(processes.shots, [
        p.join(rawDir, '01_home.png'),
        p.join(rawDir, '02_detail.png'),
        p.join(rawDir, '03_stats.png'),
      ]);
      expect(out.toString(), contains('✓ 01_home.png'));
    });

    test('an answered request is consumed, not captured again', () async {
      // The next shot() clears the done marker before writing its request.
      // If the answered request were still on disk the watcher would
      // re-capture it — against the screen that has already moved on.
      final processes = _FakeProcesses(requestOnDrive: ['01_home', '02_detail'])
        ..containerPath = p.join(tempDir.path, 'container');
      await capture(processes);
      expect(processes.shots.where((path) => path.endsWith('01_home.png')),
          hasLength(1));
      expect(
          File(p.join(processes.containerPath!, 'tmp',
                  CaptureTemplates.requestFileName))
              .existsSync(),
          isFalse);
    });

    test('a PNG the tour did not take is reported, not deleted', () async {
      final stale = File(p.join(tempDir.path,
          ScreenshotsStep.rawRelativeDir, 'ko', 'iphone_6_9', '09_old.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hand-made');
      final processes = _FakeProcesses(requestOnDrive: ['01_home'])
        ..containerPath = p.join(tempDir.path, 'container');
      await capture(processes);

      // raw/ is an input directory — a hand-captured screen lives here too.
      expect(stale.existsSync(), isTrue);
      expect(out.toString(), contains('09_old.png'));
      expect(out.toString(), contains('not taken by this tour'));
    });

    test('the status bar is restored when the tour fails', () async {
      final processes = _FailingDrive();
      await expectLater(
        () => CaptureCommand.run(
            projectRoot: tempDir.path, processes: processes, out: out),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('tour failed'))),
      );
      expect(processes.ran('status_bar UDID-1 clear'), isTrue);
    });

    test('android_phone is skipped — capture is iOS only for now', () async {
      final processes = _FakeProcesses();
      await capture(processes);
      expect(processes.ran('android_phone'), isFalse);
      expect(
          Directory(p.join(tempDir.path, ScreenshotsStep.rawRelativeDir, 'ko',
                  'android_phone'))
              .existsSync(),
          isFalse);
    });

    test('a config with no iOS device explains the gap', () async {
      File(p.join(tempDir.path, 'easy_setup.yaml')).writeAsStringSync('''
app: { name: My App, bundle_id: com.example.app }
screenshots:
  locales: [ko]
  devices: [android_phone]
''');
      await expectLater(
        () => capture(_FakeProcesses()),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            contains('Android capture is not implemented yet'))),
      );
    });

    test('--locale and --device must exist in the config', () async {
      await expectLater(
        () => capture(_FakeProcesses(), locale: 'ja'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains("locale 'ja'"))),
      );
    });

    test('--simulator overrides the model chosen for the device key',
        () async {
      final processes = _FakeProcesses(simulators: [
        (udid: 'UDID-1', name: 'iPhone 16 Pro Max'),
        (udid: 'UDID-2', name: 'iPhone 16'),
      ]);
      await capture(processes, simulator: 'iPhone 16');
      expect(processes.ran('simctl boot UDID-2'), isTrue);
      expect(processes.ran('simctl boot UDID-1'), isFalse);
    });

    test('no matching simulator lists what is installed', () async {
      final processes = _FakeProcesses(
          simulators: [(udid: 'UDID-9', name: 'iPhone SE (3rd generation)')]);
      await expectLater(
        () => capture(processes),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            allOf(contains('iPhone 16 Pro Max'), contains('iPhone SE')))),
      );
    });

    test('dry-run touches neither the simulator nor the project', () async {
      final processes = _FakeProcesses();
      await capture(processes, dryRun: true);
      expect(processes.calls, isEmpty);
      expect(
          File(p.join(tempDir.path, CaptureTemplates.tourRelativePath))
              .existsSync(),
          isFalse);
      expect(out.toString(), contains('[dry-run] Would run the tour'));
    });

    test('a project without a screenshots section says so', () async {
      File(p.join(tempDir.path, 'easy_setup.yaml')).writeAsStringSync(
          'app: { name: My App, bundle_id: com.example.app }\n');
      await expectLater(
        () => capture(_FakeProcesses()),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains("'screenshots'"))),
      );
    });
  });

  group('IosSimulator', () {
    test('prefers the model whose native size is the store canvas', () {
      expect(IosSimulator.modelCandidates['iphone_6_9']!.first,
          'iPhone 16 Pro Max'); // 1320x2868
      expect(IosSimulator.modelCandidates['ipad_13']!.first,
          'iPad Pro 13-inch (M4)'); // 2064x2752
    });
  });
}

/// Drives once and fails, to check the status bar is still restored.
class _FailingDrive extends _FakeProcesses {
  @override
  Future<int> stream(String executable, List<String> arguments,
      {String? workingDirectory, Map<String, String>? environment}) async {
    calls.add([executable, ...arguments]);
    return 1;
  }
}
