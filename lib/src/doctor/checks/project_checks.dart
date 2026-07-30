import '../check.dart';

/// Verifies the command is running inside (or was pointed at) a Flutter
/// project.
class FlutterProjectCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.project;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final root = context.projectRoot;
    if (root == null) {
      return const CheckResult.error(
        'Flutter project',
        detail: 'not found',
        fix: 'Run inside a Flutter project, or pass --project-root <path>.',
      );
    }
    return CheckResult.ok('Flutter project', detail: root);
  }
}

/// Verifies easy_setup.yaml exists and parses as a valid v2 config.
class ConfigFileCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.project;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (context.projectRoot == null) {
      return const CheckResult.skipped(
        'easy_setup.yaml',
        detail: 'no Flutter project',
      );
    }
    if (!context.configFileExists) {
      return const CheckResult.error(
        'easy_setup.yaml',
        detail: 'not found',
        fix: 'Run `easy_setup init` to create one.',
      );
    }
    final error = context.configError;
    if (error != null) {
      return CheckResult.error(
        'easy_setup.yaml',
        detail: 'invalid',
        fix: error.message,
      );
    }
    final config = context.config;
    if (config == null) {
      // Defensive: file exists, no error captured, but no config either.
      return const CheckResult.error('easy_setup.yaml', detail: 'not loaded');
    }
    final sections = [
      if (config.ios != null) 'ios',
      if (config.android != null) 'android',
      if (config.flavors.isNotEmpty) 'flavors',
      if (config.branding != null) 'branding',
      if (config.screenshots != null) 'screenshots',
      if (config.sentry != null) 'sentry',
      if (config.firebase != null) 'firebase',
      if (config.admob != null) 'admob',
    ];
    final summary = sections.isEmpty ? 'app only' : sections.join(', ');
    return CheckResult.ok(
      'easy_setup.yaml',
      detail: 'valid — app: ${config.app.name} ($summary)',
    );
  }
}
