import 'dart:convert';

import '../exceptions.dart';
import '../utils/process_runner.dart';

/// One iOS simulator, driven through `xcrun simctl`.
///
/// Capture goes through simctl rather than
/// `IntegrationTestWidgetsFlutterBinding.takeScreenshot` on purpose: the
/// binding reads back the Flutter surface, which is unreliable under
/// Impeller/Metal (whole runs come back as the splash screen), while
/// simctl grabs the compositor output — always exactly what is on screen,
/// status bar included.
class IosSimulator {
  /// Simulator model names per device key, in preference order. The first
  /// entry captures at the store's own pixel size, so nothing is rescaled.
  static const modelCandidates = {
    // The capture is scaled into the frame, so a simulator only has to be
    // at least as detailed as the canvas — the roomiest Pro Max serves
    // both iPhone tiers.
    'iphone_6_5': [
      'iPhone 16 Pro Max',
      'iPhone 17 Pro Max',
      'iPhone 15 Pro Max',
      'iPhone 11 Pro Max',
    ],
    'iphone_6_9': [
      'iPhone 16 Pro Max', // 1320×2868 — the 6.9" canvas exactly
      'iPhone 17 Pro Max',
      'iPhone 16 Plus',
      'iPhone 15 Pro Max',
    ],
    'ipad_13': [
      'iPad Pro 13-inch (M4)', // 2064×2752 — the 13" canvas exactly
      'iPad Pro (12.9-inch) (6th generation)',
      'iPad Pro 12.9-inch (M2)',
    ],
  };

  final ProcessRunner processes;
  final String udid;
  final String name;

  IosSimulator({
    required this.processes,
    required this.udid,
    required this.name,
  });

  /// Picks a simulator for [deviceKey], or the one named/identified by
  /// [preferred] when given.
  static Future<IosSimulator> resolve(
    ProcessRunner processes, {
    required String deviceKey,
    String? preferred,
  }) async {
    final available = await _list(processes);
    if (available.isEmpty) {
      throw SetupException(
        'No iOS simulators are available. Open Xcode > Settings > '
        'Components and install a simulator runtime.',
      );
    }

    if (preferred != null) {
      for (final device in available) {
        if (device.udid == preferred ||
            device.name.toLowerCase() == preferred.toLowerCase()) {
          return IosSimulator(
              processes: processes, udid: device.udid, name: device.name);
        }
      }
      throw SetupException(
        "No available simulator matches '$preferred'. Available: "
        '${available.map((d) => d.name).toSet().join(', ')}.',
      );
    }

    final candidates = modelCandidates[deviceKey];
    if (candidates == null) {
      throw SetupException(
        "'$deviceKey' is not an iOS device key — capture supports "
        '${modelCandidates.keys.join(' and ')}.',
      );
    }
    for (final candidate in candidates) {
      for (final device in available) {
        if (device.name == candidate) {
          return IosSimulator(
              processes: processes, udid: device.udid, name: device.name);
        }
      }
    }
    throw SetupException(
      'No simulator for $deviceKey. Install one of '
      '${candidates.join(', ')} in Xcode > Settings > Components, or pass '
      '--simulator with a model you have: '
      '${available.map((d) => d.name).toSet().join(', ')}.',
    );
  }

  static Future<List<({String udid, String name})>> _list(
      ProcessRunner processes) async {
    final result =
        await processes.run('xcrun', ['simctl', 'list', 'devices', '-j']);
    if (result.exitCode != 0) {
      throw SetupException(
        'Could not list iOS simulators (xcrun simctl exited '
        '${result.exitCode}). Is Xcode installed and selected?\n'
        '${result.stderr}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } on FormatException catch (e) {
      throw SetupException('Could not parse `simctl list` output: $e');
    }
    final runtimes =
        (decoded is Map ? decoded['devices'] : null) as Map<String, Object?>?;
    if (runtimes == null) return const [];
    return [
      for (final devices in runtimes.values)
        if (devices is List)
          for (final device in devices)
            if (device is Map && device['isAvailable'] == true)
              (udid: '${device['udid']}', name: '${device['name']}'),
    ];
  }

  /// Boots the simulator and waits for it to finish booting.
  Future<void> boot() async {
    // Already-booted is not an error worth surfacing.
    await processes.run('xcrun', ['simctl', 'boot', udid]);
    final result =
        await processes.run('xcrun', ['simctl', 'bootstatus', udid, '-b']);
    if (result.exitCode != 0) {
      throw SetupException(
        'Simulator $name ($udid) did not finish booting.\n${result.stderr}',
      );
    }
  }

  /// Freezes the status bar to what Apple shows in its own screenshots.
  Future<void> overrideStatusBar() => processes.run('xcrun', [
        'simctl', 'status_bar', udid, 'override',
        '--time', '9:41',
        '--dataNetwork', 'wifi',
        '--wifiMode', 'active',
        '--wifiBars', '3',
        '--cellularMode', 'active',
        '--cellularBars', '4',
        '--batteryState', 'charged',
        '--batteryLevel', '100',
      ]);

  Future<void> clearStatusBar() =>
      processes.run('xcrun', ['simctl', 'status_bar', udid, 'clear']);

  /// Removes the app so the next install gets a fresh data container —
  /// a reinstall can move the container, which would strand the watcher.
  Future<void> uninstall(String bundleId) =>
      processes.run('xcrun', ['simctl', 'uninstall', udid, bundleId]);

  /// The app's data container, or null while the app is not installed.
  Future<String?> dataContainer(String bundleId) async {
    final result = await processes
        .run('xcrun', ['simctl', 'get_app_container', udid, bundleId, 'data']);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  }

  Future<void> screenshot(String outputPath) async {
    final result = await processes
        .run('xcrun', ['simctl', 'io', udid, 'screenshot', outputPath]);
    if (result.exitCode != 0) {
      throw SetupException(
        'simctl could not capture the screen.\n${result.stderr}',
      );
    }
  }
}
