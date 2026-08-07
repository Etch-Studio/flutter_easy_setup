// easy_setup CLI entry point (v2)
//
// Commands:
//   init      Create easy_setup.yaml (v2 schema) + asset folder skeleton
//   doctor    Verify environment, keys, and secrets with fix guidance
//   setup     Apply the declared state (Setup Kit)          [planned: M4]
//   deploy    Build and upload to the stores (Deploy Kit)   [planned: M2/M3]
//   flavor    Configure Flutter flavor environments (v1 feature)
//   ci-cd     Generate CI/CD pipeline files (v1 feature, will be redesigned)
//
// Global options:
//   -n, --dry-run       Preview changes without modifying any files
//   -p, --project-root  Flutter project root path (default: auto-detect)
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:easy_setup/src/commands/ci_cd_command.dart';
import 'package:easy_setup/src/commands/deploy_command.dart';
import 'package:easy_setup/src/commands/doctor_command.dart';
import 'package:easy_setup/src/commands/flavor_command.dart';
import 'package:easy_setup/src/commands/init_command.dart';
import 'package:easy_setup/src/commands/setup_command.dart';
import 'package:easy_setup/src/exceptions.dart';
import 'package:easy_setup/src/utils/project_finder.dart';

Future<void> main(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'easy_setup',
    'Flutter project setup (Setup Kit) and deployment (Deploy Kit) '
        'automation, driven by a single easy_setup.yaml.',
  )
    ..argParser.addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Preview changes without writing any files.',
    )
    ..argParser.addOption(
      'project-root',
      abbr: 'p',
      help: 'Path to the Flutter project root (default: auto-detect).',
    )
    ..addCommand(_InitCommand())
    ..addCommand(_DoctorCommand())
    ..addCommand(_SetupCommand())
    ..addCommand(_DeployCommand())
    ..addCommand(_FlavorCommand())
    ..addCommand(_CiCdCommand());

  try {
    exit(await runner.run(arguments) ?? 0);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  } on SetupException catch (e) {
    stderr.writeln('\n✗ ${e.message}');
    exit(1);
  } catch (e, st) {
    stderr.writeln('\n✗ Unexpected error: $e');
    stderr.writeln(st);
    exit(1);
  }
}

/// Shared access to the --dry-run / --project-root options.
///
/// Both are registered globally AND per command (via [addCommonOptions]), so
/// `easy_setup -n flavor` and `easy_setup flavor -n` both work.
mixin _GlobalOptions on Command<int> {
  void addCommonOptions() {
    argParser
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Preview changes without writing any files.',
      )
      ..addOption(
        'project-root',
        abbr: 'p',
        help: 'Path to the Flutter project root (default: auto-detect).',
      );
  }

  bool get dryRun =>
      (argResults!['dry-run'] as bool) || (globalResults!['dry-run'] as bool);

  String? get projectRoot =>
      (argResults!['project-root'] as String?) ??
      globalResults!['project-root'] as String?;
}

class _InitCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'init';
  @override
  final description =
      'Create easy_setup.yaml (v2 schema) and the asset folder skeleton.';

  _InitCommand() {
    addCommonOptions();
    argParser
      ..addOption('name', help: 'App display name.')
      ..addOption('bundle-id', help: 'iOS bundle identifier.')
      ..addOption('package-name', help: 'Android application ID.')
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing easy_setup.yaml.',
      );
  }

  @override
  Future<int> run() {
    // No silent fallback to the cwd — generating the skeleton outside a
    // Flutter project (e.g. a monorepo root) scatters files in the wrong
    // place.
    final directory = projectRoot ?? ProjectFinder.findFlutterRoot();
    if (directory == null) {
      throw SetupException(
        'Could not find a Flutter project here. Run init inside the '
        'Flutter app directory, or pass --project-root <path> '
        '(in a monorepo: the app package, e.g. apps/app).',
      );
    }
    final args = argResults!;
    return InitCommand.run(
      directory: directory,
      appName: args['name'] as String?,
      bundleId: args['bundle-id'] as String?,
      packageName: args['package-name'] as String?,
      force: args['force'] as bool,
      dryRun: dryRun,
      interactive: stdin.hasTerminal,
    );
  }
}

class _DoctorCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'doctor';
  @override
  final description =
      'Verify environment, keys, and secrets — with guidance for anything '
      'that is missing.';

  _DoctorCommand() {
    addCommonOptions();
  }

  @override
  Future<int> run() => DoctorCommand.run(projectRoot: projectRoot);
}

class _SetupCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'setup';
  @override
  final description =
      'Apply the state declared in easy_setup.yaml (Setup Kit): Sentry & '
      'Firebase provisioning, AdMob ID injection, iOS capabilities, '
      'app icons, store screenshots.';

  _SetupCommand() {
    addCommonOptions();
    argParser.addOption(
      'only',
      help: 'Run a single setup step '
          '(sentry, firebase, admob, ios_capabilities, branding, '
          'screenshots, store).',
    );
  }

  @override
  Future<int> run() => SetupCommand.run(
        projectRoot: projectRoot,
        dryRun: dryRun,
        only: argResults!['only'] as String?,
      );
}

class _DeployCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'deploy';
  @override
  final description =
      'Build and upload to the stores (Deploy Kit). iOS: match + build ipa + '
      'TestFlight. Android: build appbundle + Play upload.';

  _DeployCommand() {
    addCommonOptions();
    argParser
      ..addOption(
        'platform',
        allowed: ['ios', 'android'],
        help: 'Deploy a single platform (default: all configured).',
      )
      ..addOption(
        'build-number',
        help: 'Build number override (default: GITHUB_RUN_NUMBER, then the '
            'pubspec +N suffix).',
      )
      ..addOption(
        'track',
        allowed: ['internal', 'alpha', 'beta', 'production'],
        help: 'Play track override '
            '(default: android.play_track_default, internal).',
      )
      ..addFlag(
        'match-readonly',
        defaultsTo: null,
        help: 'Run fastlane match read-only (default: read-only in CI, '
            'write mode locally).',
      )
      ..addFlag(
        'submit',
        negatable: false,
        help: 'iOS: submit the uploaded build for App Store review '
            '(metadata is managed by `setup --only store`).',
      )
      ..addFlag(
        'if-configured',
        negatable: false,
        help: 'Skip (exit 0) instead of failing when the requested '
            "--platform has no section in easy_setup.yaml. Used by CI "
            'workflows that run both platform jobs unconditionally.',
      );
  }

  @override
  Future<int> run() => DeployCommand.run(
        projectRoot: projectRoot,
        dryRun: dryRun,
        platform: argResults!['platform'] as String?,
        buildNumber: argResults!['build-number'] as String?,
        track: argResults!['track'] as String?,
        submit: argResults!['submit'] as bool,
        ifConfigured: argResults!['if-configured'] as bool,
        matchReadonly: argResults!.wasParsed('match-readonly')
            ? argResults!['match-readonly'] as bool
            : null,
      );
}

class _FlavorCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'flavor';
  @override
  final description =
      'Configure Flutter flavor environments for Android & iOS (v1 feature, '
      'uses the v1 `easy_setup:` schema).';

  _FlavorCommand() {
    addCommonOptions();
  }

  @override
  Future<int> run() async {
    await FlavorCommand.run(dryRun: dryRun, projectRoot: projectRoot);
    return 0;
  }
}

class _CiCdCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'ci-cd';
  @override
  final description =
      'Generate CI/CD pipeline files (v1 feature, uses the v1 `easy_setup:` '
      'schema — will be redesigned as reusable workflows).';

  _CiCdCommand() {
    addCommonOptions();
  }

  @override
  Future<int> run() async {
    await CiCdCommand.run(dryRun: dryRun, projectRoot: projectRoot);
    return 0;
  }
}
