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

/// Shared access to the global --dry-run / --project-root options.
mixin _GlobalOptions on Command<int> {
  bool get dryRun => globalResults!['dry-run'] as bool;
  String? get projectRoot => globalResults!['project-root'] as String?;
}

class _InitCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'init';
  @override
  final description =
      'Create easy_setup.yaml (v2 schema) and the asset folder skeleton.';

  _InitCommand() {
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
    final directory = projectRoot ??
        ProjectFinder.findFlutterRoot() ??
        Directory.current.path;
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

  @override
  Future<int> run() => DoctorCommand.run(projectRoot: projectRoot);
}

class _SetupCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'setup';
  @override
  final description =
      'Apply the state declared in easy_setup.yaml (Setup Kit). '
      '[planned: M4]';

  _SetupCommand() {
    argParser.addOption(
      'only',
      help: 'Run a single setup step (e.g. sentry, firebase, admob).',
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
      'Build and upload to the stores (Deploy Kit). [planned: M2/M3]';

  _DeployCommand() {
    argParser.addOption(
      'platform',
      allowed: ['ios', 'android'],
      help: 'Deploy a single platform (default: all configured).',
    );
  }

  @override
  Future<int> run() => DeployCommand.run(
        projectRoot: projectRoot,
        dryRun: dryRun,
        platform: argResults!['platform'] as String?,
      );
}

class _FlavorCommand extends Command<int> with _GlobalOptions {
  @override
  final name = 'flavor';
  @override
  final description =
      'Configure Flutter flavor environments for Android & iOS (v1 feature, '
      'uses the v1 `easy_setup:` schema).';

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

  @override
  Future<int> run() async {
    await CiCdCommand.run(dryRun: dryRun, projectRoot: projectRoot);
    return 0;
  }
}
