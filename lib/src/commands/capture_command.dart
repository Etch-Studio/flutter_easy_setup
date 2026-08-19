import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../capture/capture_templates.dart';
import '../capture/ios_simulator.dart';
import '../config/project_config.dart';
import '../exceptions.dart';
import '../setup/screenshots_step.dart';
import '../utils/idempotent_writer.dart';
import '../utils/process_runner.dart';
import '../utils/project_finder.dart';

/// `easy_setup capture` — drives the app through its screens on a
/// simulator and saves the raw captures (V2_PLAN.md §5.2, layer ①).
///
/// Deliberately not a `setup` step: it needs a booted simulator, it takes
/// minutes, and it is not idempotent — it re-shoots whatever the tour
/// currently visits.
///
/// The work is split the same way the rest of the store pipeline is:
/// easy_setup owns the harness (simulator, status bar, watcher, output
/// convention) and the project owns the tour, because which screens matter
/// and what demo data they need can only be answered per app.
class CaptureCommand {
  /// How long to wait for a `shot()` request after the drive starts.
  static const captureTimeout = Duration(minutes: 5);

  static Future<int> run({
    String? projectRoot,
    bool dryRun = false,
    String? device,
    String? locale,
    String? simulator,
    StringSink? out,
    ProcessRunner processes = const ProcessRunner(),
  }) async {
    final root = ProjectFinder.findFlutterRoot(projectRoot);
    if (root == null) {
      throw SetupException(
        'Could not find a Flutter project root. '
        'Run inside a Flutter project, or pass --project-root <path>.',
      );
    }
    final config = ProjectConfig.fromFile(ProjectFinder.configPath(root));
    final sink = out ?? stdout;

    final shots = config.screenshots;
    if (shots == null) {
      throw SetupException(
        "Capture needs a 'screenshots' section in easy_setup.yaml "
        '(locales and devices).',
      );
    }
    final locales = _select(
        shots.locales.isEmpty ? const ['en-US'] : shots.locales, locale,
        what: 'locale');
    final devices = _select(
      (shots.devices.isEmpty
              ? ScreenshotsConfig.allowedDevices
              : shots.devices)
          .where(IosSimulator.modelCandidates.containsKey)
          .toList(),
      device,
      what: 'device',
    );
    if (devices.isEmpty) {
      throw SetupException(
        'No iOS device configured for capture. Add one of '
        '${IosSimulator.modelCandidates.keys.join(' / ')} to '
        "'screenshots.devices'. Android capture is not implemented yet — "
        'capture those by hand for now.',
      );
    }
    if (!Platform.isMacOS && !dryRun) {
      throw SetupException('Capturing on a simulator needs macOS.');
    }

    _scaffold(root, sink, dryRun: dryRun);
    if (!dryRun) _requireIntegrationTestDependency(root);

    for (final deviceKey in devices) {
      for (final localeCode in locales) {
        final outDir = p.join(root, ScreenshotsStep.rawRelativeDir,
            localeCode, deviceKey);
        if (dryRun) {
          sink.writeln(
              '  [dry-run] Would run the tour for $localeCode/$deviceKey '
              '→ ${p.relative(outDir, from: root)}/');
          continue;
        }
        await _capture(
          processes: processes,
          sink: sink,
          root: root,
          bundleId: config.app.bundleId,
          deviceKey: deviceKey,
          localeCode: localeCode,
          preferredSimulator: simulator,
          outDir: outDir,
        );
      }
    }

    if (dryRun) {
      sink.writeln('\n[dry-run] Preview complete — nothing was captured.');
      return 0;
    }
    sink.writeln(
        '\n✓ Capture complete. Frame them with '
        '`easy_setup setup --only screenshots`.');
    return 0;
  }

  /// Narrows a configured list to a single [only] value, validating it.
  static List<String> _select(List<String> all, String? only,
      {required String what}) {
    if (only == null) return all;
    if (!all.contains(only)) {
      throw SetupException(
        "Unknown $what '$only' — easy_setup.yaml configures "
        '${all.join(', ')}.',
      );
    }
    return [only];
  }

  // --- Sources -------------------------------------------------------------

  static void _scaffold(String root, StringSink sink, {required bool dryRun}) {
    final tour = File(p.join(root, CaptureTemplates.tourRelativePath));
    if (dryRun) {
      if (!tour.existsSync()) {
        sink.writeln(
            '  [dry-run] Would create ${CaptureTemplates.tourRelativePath}, '
            'the harness and the drive driver');
      }
      return;
    }
    // Derived: the harness protocol has to match the watcher below, and
    // the driver is boilerplate.
    writeIfChanged(File(p.join(root, CaptureTemplates.harnessRelativePath)),
        CaptureTemplates.harness());
    writeIfChanged(File(p.join(root, CaptureTemplates.driverRelativePath)),
        CaptureTemplates.driver());

    if (writeIfAbsent(tour, CaptureTemplates.tour(_packageName(root))) > 0) {
      sink.writeln(
          '  ✓ Created ${CaptureTemplates.tourRelativePath} — write the '
          'tour there, or ask Claude: "/store-screenshots"');
      return;
    }
    _checkTourSpeaksTheProtocol(tour, sink);
  }

  /// Warns when an existing tour cannot be answered by the watcher.
  ///
  /// A tour written before the harness existed — or one that drifted from
  /// it — puts its markers somewhere the watcher never looks, and every
  /// `shot()` then times out. Left undetected that costs a full build plus
  /// the timeout to discover, so it is worth a cheap string check here.
  static void _checkTourSpeaksTheProtocol(File tour, StringSink sink) {
    final source = tour.readAsStringSync();
    final harness = p.basename(CaptureTemplates.harnessRelativePath);
    if (source.contains(harness) ||
        source.contains(CaptureTemplates.requestFileName)) {
      return;
    }
    sink.writeln(
        '  ! ${CaptureTemplates.tourRelativePath} does not use $harness — '
        'its captures will never be answered. Import it and take shots '
        'with shot(tester, name).');
  }

  /// The tour imports `package:integration_test`, which has to be a dev
  /// dependency of the app. Adding it here would mean rewriting someone
  /// else's pubspec, so it is reported instead.
  static void _requireIntegrationTestDependency(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return;
    if (pubspec.readAsStringSync().contains('integration_test:')) return;
    throw SetupException(
      'The tour needs the integration_test package. Add it to '
      'pubspec.yaml and run `flutter pub get`:\n\n'
      '  dev_dependencies:\n'
      '    integration_test:\n'
      '      sdk: flutter\n',
    );
  }

  static String _packageName(String root) {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return 'my_app';
    for (final line in pubspec.readAsLinesSync()) {
      final match = RegExp(r'^name:\s*(\S+)').firstMatch(line);
      if (match != null) return match.group(1)!;
    }
    return 'my_app';
  }

  // --- One tour run --------------------------------------------------------

  static Future<void> _capture({
    required ProcessRunner processes,
    required StringSink sink,
    required String root,
    required String bundleId,
    required String deviceKey,
    required String localeCode,
    required String? preferredSimulator,
    required String outDir,
  }) async {
    final simulator = await IosSimulator.resolve(processes,
        deviceKey: deviceKey, preferred: preferredSimulator);
    sink.writeln('\n--- $localeCode / $deviceKey ---');
    sink.writeln('  → ${simulator.name}');

    await simulator.boot();
    await simulator.overrideStatusBar();
    // A reinstall can move the data container, which would strand the
    // watcher on a path the app no longer writes to.
    await simulator.uninstall(bundleId);
    Directory(outDir).createSync(recursive: true);

    var running = true;
    Object? watcherError;
    // Errors are captured rather than thrown so draining the watcher in
    // the finally below can never mask why the tour actually failed.
    final watcher = _watch(
      simulator: simulator,
      bundleId: bundleId,
      outDir: outDir,
      sink: sink,
      isRunning: () => running,
    ).onError<Object>((error, _) {
      watcherError = error;
      return const {};
    });

    var exitCode = 0;
    Set<String> captured = const {};
    try {
      exitCode = await processes.stream(
        'flutter',
        [
          'drive',
          '--driver=${CaptureTemplates.driverRelativePath}',
          '--target=${CaptureTemplates.tourRelativePath}',
          '--dart-define=SCREENSHOT_MODE=true',
          '--dart-define=SCREENSHOT_LOCALE=$localeCode',
          '-d',
          simulator.udid,
        ],
        workingDirectory: root,
      );
    } finally {
      running = false;
      captured = await watcher;
      // Always restored: an overridden status bar outlives this process.
      await simulator.clearStatusBar();
    }

    if (watcherError != null) {
      throw SetupException('The capture watcher failed: $watcherError');
    }
    if (exitCode != 0) {
      throw SetupException(
        'The tour failed (flutter drive exited $exitCode). The captures '
        'taken before the failure are in '
        '${p.relative(outDir, from: root)}/.',
      );
    }
    _reportExtras(outDir, captured, sink);
  }

  /// Names a run leaves behind that its tour did not produce.
  ///
  /// Reported, not deleted: raw/ is an input directory, and a screen that
  /// cannot be reached from a test is legitimately captured by hand into
  /// it. Silently shipping a screenshot of a screen the app no longer has
  /// is the real risk, so it is worth saying out loud.
  static void _reportExtras(
      String outDir, Set<String> captured, StringSink sink) {
    final extras = Directory(outDir)
        .listSync()
        .whereType<File>()
        .map((file) => p.basename(file.path))
        .where((name) => name.endsWith('.png'))
        .where((name) => !captured.contains(p.withoutExtension(name)))
        .toList()
      ..sort();
    if (extras.isEmpty) return;
    sink.writeln(
        '  ! ${extras.join(', ')} — in the folder but not taken by this '
        'tour. Delete them if they are stale.');
  }

  /// Answers capture requests from the running tour.
  ///
  /// The tour writes the screen name into the app's tmp directory; this
  /// captures through simctl and writes back a done marker, which lets the
  /// tour continue. Polling a file is what keeps the two processes — a
  /// Dart test on the simulator and this CLI on the host — in step without
  /// a socket between them.
  static Future<Set<String>> _watch({
    required IosSimulator simulator,
    required String bundleId,
    required String outDir,
    required StringSink sink,
    required bool Function() isRunning,
  }) async {
    // Only armed once the app is installed — a cold `flutter drive` build
    // can easily outlast the capture timeout on its own.
    DateTime? deadline;
    String? tmpDir;
    final captured = <String>{};

    while (isRunning() &&
        (deadline == null || DateTime.now().isBefore(deadline))) {
      if (tmpDir == null) {
        final container = await simulator.dataContainer(bundleId);
        if (container == null) {
          // The app is not installed yet — the drive is still building.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        deadline = DateTime.now().add(captureTimeout);
        // No stale-marker cleanup here on purpose. The container is only
        // resolvable once the app is installed, by which point the tour
        // may already have written its first request — deleting it would
        // drop that screenshot and hang the tour. The uninstall before the
        // drive is what guarantees the container starts empty.
        tmpDir = p.join(container, 'tmp');
      }

      final request = File(p.join(tmpDir, CaptureTemplates.requestFileName));
      if (request.existsSync()) {
        final name = request.readAsStringSync().trim();
        if (name.isEmpty) {
          request.deleteSync();
          continue;
        }
        // Let the frame that triggered the request finish painting. The
        // tour is blocked on the done marker meanwhile, so the screen
        // cannot move on under us.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await simulator.screenshot(p.join(outDir, '$name.png'));
        // Consume the request before answering. Leaving it in place would
        // let the next shot() — which clears the done marker first — see
        // this request again and re-capture it against the *next* screen,
        // silently overwriting a good screenshot with the wrong one.
        request.deleteSync();
        File(p.join(tmpDir, CaptureTemplates.doneFileName))
            .writeAsStringSync(name);
        captured.add(name);
        sink.writeln('  ✓ $name.png');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    if (captured.isEmpty && isRunning()) {
      sink.writeln(
          '  ! No capture request in ${captureTimeout.inMinutes} minutes — '
          'does the tour call shot()?');
    }
    return captured;
  }
}
