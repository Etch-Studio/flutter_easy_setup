import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';
import '../utils/process_runner.dart';

/// Resolved build identity for a deploy: `1.2.3` + build number.
class BuildVersion {
  /// Marketing version (CFBundleShortVersionString), e.g. `1.2.3`.
  final String buildName;

  /// Build number (CFBundleVersion), monotonically increasing.
  final String buildNumber;

  /// Where [buildName] came from (`git tag` or `pubspec.yaml`).
  final String source;

  BuildVersion({
    required this.buildName,
    required this.buildNumber,
    required this.source,
  });

  @override
  String toString() => '$buildName+$buildNumber ($source)';
}

/// Resolves the version to deploy.
///
/// Build name: a `v*` git tag pointing at HEAD wins (a tag push is the
/// release trigger — V2_PLAN.md §6.3), otherwise the pubspec.yaml version.
/// Build number: explicit override > `GITHUB_RUN_NUMBER` (CI) > the pubspec
/// `+N` suffix > `1`.
class VersionResolver {
  static final _tagPattern = RegExp(r'^v(\d+\.\d+\.\d+\S*)$');

  static Future<BuildVersion> resolve({
    required String projectRoot,
    Map<String, String> env = const {},
    String? buildNumberOverride,
    ProcessRunner processes = const ProcessRunner(),
  }) async {
    String? buildName;
    String? source;

    try {
      final tagResult = await processes.run(
        'git',
        ['describe', '--tags', '--exact-match'],
        workingDirectory: projectRoot,
      );
      if (tagResult.exitCode == 0) {
        final tag = (tagResult.stdout as String).trim();
        final match = _tagPattern.firstMatch(tag);
        if (match != null) {
          buildName = match.group(1);
          source = 'git tag $tag';
        }
      }
    } on ProcessException {
      // No git available — fall through to pubspec.yaml.
    }

    final pubspecVersion = _pubspecVersion(projectRoot);
    if (buildName == null) {
      if (pubspecVersion == null) {
        throw SetupException(
          'Could not resolve a version: no v* git tag at HEAD and no '
          "'version:' in pubspec.yaml.",
        );
      }
      buildName = pubspecVersion.$1;
      source = 'pubspec.yaml';
    }

    final buildNumber = buildNumberOverride ??
        env['GITHUB_RUN_NUMBER'] ??
        pubspecVersion?.$2 ??
        '1';

    return BuildVersion(
      buildName: buildName,
      buildNumber: buildNumber,
      source: source!,
    );
  }

  /// Returns (version, buildNumber?) from pubspec.yaml, or null when absent.
  static (String, String?)? _pubspecVersion(String projectRoot) {
    final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    for (final line in pubspec.readAsLinesSync()) {
      if (!line.startsWith('version:')) continue;
      final value = line.substring('version:'.length).trim();
      if (value.isEmpty) return null;
      final parts = value.split('+');
      return (parts.first, parts.length > 1 ? parts.sublist(1).join('+') : null);
    }
    return null;
  }
}
