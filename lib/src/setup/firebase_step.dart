import 'dart:convert';

import '../config/project_config.dart';
import '../exceptions.dart';
import 'setup_step.dart';

/// Provisions Firebase and wires the Flutter app to it (V2_PLAN.md §5.6):
/// create the Firebase project when missing, then run
/// `flutterfire configure` to generate google-services.json,
/// GoogleService-Info.plist, and lib/firebase_options.dart.
class FirebaseStep extends SetupStep {
  @override
  String get name => 'firebase';

  @override
  bool isConfigured(ProjectConfig config) => config.firebase != null;

  @override
  Future<void> run(SetupContext context) async {
    final firebase = context.config.firebase!;
    final projectId = firebase.projectId;
    if (projectId == null) {
      throw SetupException(
        "Firebase setup needs 'firebase.project_id' in easy_setup.yaml — "
        'pick a globally unique ID (e.g. my-org-myapp); the project is '
        'created when it does not exist yet.',
      );
    }

    if (context.dryRun) {
      context.out
        ..writeln('  [dry-run] Would ensure Firebase project "$projectId" '
            'exists (create when missing)')
        ..writeln('  [dry-run] Would run: flutterfire configure '
            '--project=$projectId --platforms=android,ios --yes');
      if (firebase.analytics) {
        context.out.writeln(
            '  [dry-run] Would remind about the Google Analytics link');
      }
      return;
    }

    await _requireCli(context, 'firebase',
        'Install the Firebase CLI: curl -sL https://firebase.tools | bash');
    await _requireCli(context, 'flutterfire',
        'dart pub global activate flutterfire_cli');

    await _ensureProject(context, projectId);

    if (firebase.analytics) {
      // CLI-created projects are not GA-linked; the link API needs a GA
      // account choice, so it stays a one-time console step for now.
      context.out.writeln(
          '  ! Link Google Analytics once in the console (Project settings '
          '> Integrations):\n'
          '    https://console.firebase.google.com/project/$projectId/'
          'settings/integrations/analytics');
    }

    context.out.writeln('  → flutterfire configure');
    final exitCode = await context.processes.stream(
      'flutterfire',
      [
        'configure',
        '--project=$projectId',
        // Explicit platforms keep macOS/web targets from being added.
        '--platforms=android,ios',
        '--yes',
      ],
      workingDirectory: context.projectRoot,
    );
    if (exitCode != 0) {
      throw SetupException(
          'flutterfire configure failed (exit code $exitCode).');
    }
    context.out.writeln('  ✓ Firebase configured '
        '(google-services.json / GoogleService-Info.plist / '
        'lib/firebase_options.dart)');
  }

  Future<void> _requireCli(
      SetupContext context, String command, String fix) async {
    if (await context.processes.which(command) == null) {
      throw SetupException('$command CLI not found.\n$fix');
    }
  }

  Future<void> _ensureProject(SetupContext context, String projectId) async {
    final list = await context.processes.run(
      'firebase',
      ['projects:list', '--json'],
      workingDirectory: context.projectRoot,
    );
    if (list.exitCode != 0) {
      throw SetupException(
        'firebase projects:list failed — run `firebase login` first.\n'
        '${(list.stderr as String).trim()}',
      );
    }
    final exists = _projectIds(list.stdout as String).contains(projectId);
    if (exists) {
      context.out.writeln('  ✓ Firebase project "$projectId" already exists');
      return;
    }

    context.out.writeln('  → Creating Firebase project "$projectId"');
    final create = await context.processes.run(
      'firebase',
      [
        'projects:create',
        projectId,
        '--display-name',
        context.config.app.name,
        '--json',
      ],
      workingDirectory: context.projectRoot,
    );
    if (create.exitCode != 0) {
      throw SetupException(
        'firebase projects:create failed — the ID may be taken globally.\n'
        '${(create.stderr as String).trim()}',
      );
    }
    context.out.writeln('  ✓ Created Firebase project "$projectId"');
  }

  /// Parses `firebase projects:list --json` output into project IDs.
  /// Fails closed on unexpected output — an empty list here would trigger
  /// project creation, turning a parse issue into a side effect.
  List<String> _projectIds(String jsonText) {
    final Object? decoded;
    try {
      decoded = json.decode(jsonText);
    } on FormatException {
      throw SetupException(
          'Could not parse `firebase projects:list --json` output — '
          'update the Firebase CLI and retry.');
    }
    final result = decoded is Map ? decoded['result'] : null;
    if (result is! List) {
      throw SetupException(
          'Unexpected `firebase projects:list --json` output shape '
          '(no result list) — update the Firebase CLI and retry.');
    }
    return [
      for (final project in result)
        if (project is Map && project['projectId'] is String)
          project['projectId'] as String,
    ];
  }
}
