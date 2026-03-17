// easy_setup CLI entry point
//
// A CLI tool that automatically configures Flutter project setup.
//
// Commands:
//   flavor    Configure Flutter flavor environments (Android + iOS)  [default]
//   ci-cd     Generate CI/CD pipeline setup (Fastlane + GitHub Actions + Bundle ID registration)
//
// Global Options:
//   -h, --help          Show help
//   -n, --dry-run       Preview changes without modifying any files
//   -p, --project-root  Specify Flutter project root path (default: auto-detect)
import 'dart:io';

import 'package:args/args.dart';
import 'package:easy_setup/src/commands/ci_cd_command.dart';
import 'package:easy_setup/src/commands/flavor_command.dart';
import 'package:easy_setup/src/exceptions.dart';

Future<void> main(List<String> arguments) async {
  // Configure global option parser
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    )
    ..addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Preview changes without writing any files.',
    )
    ..addOption(
      'project-root',
      abbr: 'p',
      help: 'Path to Flutter project root (default: auto-detect).',
    );

  // Determine subcommand: check if the first argument is a known command
  String command = 'flavor'; // default — backward compatibility
  var commandArgs = arguments;

  if (arguments.isNotEmpty && !arguments.first.startsWith('-')) {
    final first = arguments.first;
    if (first == 'flavor' || first == 'ci-cd') {
      command = first;
      commandArgs = arguments.sublist(1);
    }
  }

  // Parse arguments
  ArgResults args;
  try {
    args = parser.parse(commandArgs);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}\n');
    _printUsage(parser);
    exit(1);
  }

  // Handle --help flag
  if (args['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final dryRun = args['dry-run'] as bool;
  final projectRoot = args['project-root'] as String?;

  // Execute subcommand
  try {
    switch (command) {
      case 'flavor':
        await FlavorCommand.run(dryRun: dryRun, projectRoot: projectRoot);
      case 'ci-cd':
        await CiCdCommand.run(dryRun: dryRun, projectRoot: projectRoot);
    }
  } on SetupException catch (e) {
    stderr.writeln('\n✗ ${e.message}');
    exit(1);
  } catch (e, st) {
    stderr.writeln('\n✗ Unexpected error: $e');
    stderr.writeln(st);
    exit(1);
  }
}

/// Prints CLI usage information and an easy_setup.yaml example.
void _printUsage(ArgParser parser) {
  print('easy_setup — Configure Flutter project setup\n');
  print('Usage: easy_setup <command> [options]\n');
  print('Commands:');
  print('  flavor    Configure Flutter flavors for Android & iOS (default)');
  print('  ci-cd     Generate CI/CD pipeline files, register Bundle IDs,');
  print('            and create register lane (Fastlane + GitHub Actions)\n');
  print(parser.usage);
  print('');
  print('Reads easy_setup.yaml in the Flutter project root.');
  print('');
  print('Example easy_setup.yaml:');
  print('');
  print('  easy_setup:');
  print('    flavors:');
  print('      dev:');
  print('        bundle_id: com.example.app.dev');
  print('        name: MyApp Dev');
  print('      prod:');
  print('        bundle_id: com.example.app');
  print('        name: MyApp');
  print('');
  print('    ci_cd:');
  print('      ios:');
  print('        storage: https://github.com/user/certs.git');
  print('        team_id: XXXXXXXXXX');
  print('        itc_team_id: YYYYYYYYYY');
  print('        api_key:');
  print('          id: KEY_ID');
  print('          issuer_id: ISSUER_ID');
  print('          key_path: ci_cd/ios/fastlane/AuthKey.p8');
}
