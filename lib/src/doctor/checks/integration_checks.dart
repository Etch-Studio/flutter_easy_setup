import '../check.dart';

/// Verifies the Sentry org auth token is available.
/// Runs only when the `sentry:` section is configured.
class SentryTokenCheck extends DoctorCheck {
  static const envName = 'SENTRY_ORG_TOKEN';

  @override
  String get category => DoctorCategory.integrations;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'Sentry org token';
    if (context.config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    if (context.config!.sentry == null) {
      return const CheckResult.skipped(title,
          detail: "'sentry' section not configured");
    }
    final token = context.env[envName];
    if (token == null || token.trim().isEmpty) {
      return const CheckResult.error(
        title,
        detail: 'missing env: $envName',
        fix: '1. Sentry > Settings > Auth Tokens: create an organization '
            'token\n'
            '   with the org:write and project:write scopes\n'
            '2. Export SENTRY_ORG_TOKEN=<token>',
      );
    }
    if (!token.startsWith('sntrys_')) {
      return const CheckResult.warning(
        title,
        detail: 'set, but does not look like an org token '
            '(expected sntrys_ prefix)',
      );
    }
    return const CheckResult.ok(title, detail: 'set');
  }
}

/// Verifies the AdMob app IDs are filled in.
/// Runs only when the `admob:` section is configured.
///
/// Creating apps/ad units via the AdMob API needs limited-access approval,
/// so the default path (Plan B) is manual console creation + pasting IDs.
class AdmobAppIdCheck extends DoctorCheck {
  static final _appIdPattern = RegExp(r'^ca-app-pub-\d+~\d+$');

  @override
  String get category => DoctorCategory.integrations;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'AdMob app IDs';
    if (context.config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    final admob = context.config!.admob;
    if (admob == null) {
      return const CheckResult.skipped(title,
          detail: "'admob' section not configured");
    }
    final missing = <String>[
      if (admob.iosAppId == null) 'ios_app_id',
      if (admob.androidAppId == null) 'android_app_id',
    ];
    if (missing.isNotEmpty) {
      return CheckResult.warning(
        title,
        detail: 'missing: ${missing.join(', ')}',
        fix: 'Create the app(s) once in the AdMob console '
            '(apps.admob.com > Apps > Add app), then paste the app IDs into '
            'admob.ios_app_id / admob.android_app_id in easy_setup.yaml.',
      );
    }
    final invalid = <String>[
      if (!_appIdPattern.hasMatch(admob.iosAppId!)) 'ios_app_id',
      if (!_appIdPattern.hasMatch(admob.androidAppId!)) 'android_app_id',
    ];
    if (invalid.isNotEmpty) {
      return CheckResult.warning(
        title,
        detail: '${invalid.join(', ')} does not match '
            'ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY',
      );
    }
    return const CheckResult.ok(title, detail: 'ios + android set');
  }
}
