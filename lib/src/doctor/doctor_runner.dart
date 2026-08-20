import 'check.dart';
import 'checks/android_deploy_checks.dart';
import 'checks/environment_checks.dart';
import 'checks/integration_checks.dart';
import 'checks/ios_deploy_checks.dart';
import 'checks/project_checks.dart';

/// Runs doctor checks and renders the report.
class DoctorRunner {
  final DoctorContext context;
  final List<DoctorCheck> checks;

  DoctorRunner(this.context, {List<DoctorCheck>? checks})
      : checks = checks ?? defaultChecks(context);

  /// The standard check list, adapted to the platform and config.
  static List<DoctorCheck> defaultChecks(DoctorContext context) {
    final firebaseConfigured = context.config?.firebase != null;
    final rendersStoreAssets = context.config?.branding != null ||
        context.config?.screenshots != null;
    return [
      // Environment
      ToolCheck(
        title: 'Flutter SDK',
        command: 'flutter',
        fix: 'Install Flutter: https://docs.flutter.dev/get-started/install',
      ),
      ToolCheck(
        title: 'Dart SDK',
        command: 'dart',
        fix: 'Dart ships with Flutter — install Flutter first.',
      ),
      ToolCheck(
        title: 'Git',
        command: 'git',
        fix: 'Install Git (macOS: xcode-select --install).',
      ),
      if (context.isMacOS) ...[
        ToolCheck(
          title: 'Xcode',
          command: 'xcodebuild',
          versionArguments: ['-version'],
          fix: 'Install Xcode from the App Store, then run:\n'
              'sudo xcode-select -s /Applications/Xcode.app',
        ),
        ToolCheck(
          title: 'CocoaPods',
          command: 'pod',
          fix: 'brew install cocoapods',
        ),
        ToolCheck(
          title: 'Fastlane',
          command: 'fastlane',
          // `fastlane --version` prints a preamble before the version line.
          versionLinePattern: RegExp(r'^fastlane \d'),
          optional: true,
          fix: 'Needed by the Deploy Kit (match/pilot/deliver):\n'
              'brew install fastlane',
        ),
      ],
      if (rendersStoreAssets) StoreAssetRendererCheck(),
      // Project
      FlutterProjectCheck(),
      ConfigFileCheck(),
      // iOS deploy
      AscApiKeyCheck(),
      TeamIdCheck(),
      MatchCheck(),
      // Android deploy
      PlayServiceAccountCheck(),
      // Integrations
      SentryTokenCheck(),
      AmplitudeKeyCheck(),
      if (firebaseConfigured) ...[
        ToolCheck(
          title: 'Firebase CLI',
          command: 'firebase',
          category: DoctorCategory.integrations,
          fix: 'curl -sL https://firebase.tools | bash\n'
              '(or: npm install -g firebase-tools)',
        ),
        ToolCheck(
          title: 'FlutterFire CLI',
          command: 'flutterfire',
          category: DoctorCategory.integrations,
          fix: 'dart pub global activate flutterfire_cli',
        ),
      ],
      AdmobApiAccessCheck(),
      AdmobAppIdCheck(),
      AppAdsTxtCheck(),
      DartDefineFileCheck(),
    ];
  }

  Future<DoctorReport> run() async {
    final results = <(String, CheckResult)>[];
    for (final check in checks) {
      results.add((check.category, await check.run(context)));
    }
    return DoctorReport(results);
  }
}

/// Collected check results, grouped by category in display order.
class DoctorReport {
  /// (category, result) pairs in execution order.
  final List<(String, CheckResult)> results;

  DoctorReport(this.results);

  int _count(CheckStatus status) =>
      results.where((entry) => entry.$2.status == status).length;

  int get okCount => _count(CheckStatus.ok);
  int get warningCount => _count(CheckStatus.warning);
  int get errorCount => _count(CheckStatus.error);
  int get skippedCount => _count(CheckStatus.skipped);

  bool get hasErrors => errorCount > 0;

  static const _symbols = {
    CheckStatus.ok: '✓',
    CheckStatus.warning: '!',
    CheckStatus.error: '✗',
    CheckStatus.skipped: '-',
  };

  /// Renders the full plain-text report.
  String render() {
    final buffer = StringBuffer();
    final categories = [
      ...DoctorCategory.ordered.where(_hasCategory),
      // Preserve any category not in the standard order (custom checks).
      ...results
          .map((entry) => entry.$1)
          .where((category) => !DoctorCategory.ordered.contains(category))
          .toSet(),
    ];
    for (final category in categories) {
      buffer.writeln(category);
      for (final (resultCategory, result) in results) {
        if (resultCategory != category) continue;
        final symbol = _symbols[result.status]!;
        final title = result.title.padRight(28);
        final detail = result.detail == null ? '' : ' ${result.detail}';
        buffer.writeln('  $symbol $title$detail');
        if (result.fix != null &&
            (result.status == CheckStatus.warning ||
                result.status == CheckStatus.error)) {
          for (final line in result.fix!.split('\n')) {
            buffer.writeln('      $line');
          }
        }
      }
      buffer.writeln();
    }
    buffer.writeln(
      'Summary: $okCount ok · $warningCount warning(s) · '
      '$errorCount error(s) · $skippedCount skipped',
    );
    return buffer.toString();
  }

  bool _hasCategory(String category) =>
      results.any((entry) => entry.$1 == category);
}
