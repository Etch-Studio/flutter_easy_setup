import '../../admob/admob_api.dart';
import '../../setup/sentry_step.dart';
import '../check.dart';

/// Verifies a Sentry API token that can actually create the project is
/// available. Runs only when the `sentry:` section is configured.
class SentryTokenCheck extends DoctorCheck {
  static const envName = SentryStep.tokenEnv;
  static const legacyEnvName = SentryStep.legacyTokenEnv;

  /// Prefix Sentry gives organization tokens — the one kind that cannot
  /// create a project.
  static const _orgTokenPrefix = 'sntrys_';

  @override
  String get category => DoctorCategory.integrations;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'Sentry API token';
    if (context.config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    if (context.config!.sentry == null) {
      return const CheckResult.skipped(title,
          detail: "'sentry' section not configured");
    }
    final token = context.env[envName] ?? context.env[legacyEnvName];
    if (token == null || token.trim().isEmpty) {
      return const CheckResult.error(
        title,
        detail: 'missing env: $envName',
        fix: SentryStep.tokenHint,
      );
    }
    if (token.startsWith(_orgTokenPrefix)) {
      return const CheckResult.warning(
        title,
        detail: 'set, but this is an organization token '
            '($_orgTokenPrefix…) — those cannot create projects',
        fix: SentryStep.tokenHint,
      );
    }
    return CheckResult.ok(title,
        detail: context.env[envName] != null
            ? 'set'
            : 'set via the legacy $legacyEnvName');
  }
}

/// Verifies the AdMob app IDs are known — declared in easy_setup.yaml, or
/// resolvable through the AdMob API. Runs only when `admob:` is configured.
///
/// Creating apps/ad units through the API needs limited-access approval, but
/// listing them does not, so a credential is enough to avoid pasting IDs.
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
    // Malformed declared IDs come first: setup injects them as they are, so
    // they are wrong whether or not the API could fill the other platform in.
    final invalid = <String>[
      for (final (field, id) in [
        ('ios_app_id', admob.iosAppId),
        ('android_app_id', admob.androidAppId),
      ])
        if (id != null && !_appIdPattern.hasMatch(id)) field,
    ];
    if (invalid.isNotEmpty) {
      return CheckResult.warning(
        title,
        detail: '${invalid.join(', ')} does not match '
            'ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY',
      );
    }
    final missing = <String>[
      if (admob.iosAppId == null) 'ios_app_id',
      if (admob.androidAppId == null) 'android_app_id',
    ];
    if (missing.isNotEmpty) {
      // Undeclared IDs are fine when setup can look them up.
      final source =
          admob.auto ? await admobCredentialSource(context) : null;
      if (source != null) {
        return CheckResult.ok(
          title,
          detail: 'missing: ${missing.join(', ')} — looked up through the '
              'AdMob API ($source)',
        );
      }
      return CheckResult.warning(
        title,
        detail: 'missing: ${missing.join(', ')}',
        fix: 'Either give the AdMob API a credential (see the AdMob API '
            'credential check) so setup can look the IDs up, or create the '
            'app(s) once in the AdMob console (apps.admob.com > Apps > Add '
            'app) and paste the IDs into admob.ios_app_id / '
            'admob.android_app_id.',
      );
    }
    return const CheckResult.ok(title, detail: 'ios + android set');
  }
}

/// Verifies the Amplitude API key is exported.
/// Runs only when the `amplitude:` section is configured.
///
/// Amplitude has no project-creation API, so creating the project is a
/// one-time console step; from there the key travels through the environment
/// and never lands in a tracked file.
class AmplitudeKeyCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.integrations;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'Amplitude API key';
    if (context.config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    final amplitude = context.config!.amplitude;
    if (amplitude == null) {
      return const CheckResult.skipped(title,
          detail: "'amplitude' section not configured");
    }
    final key = (context.env[amplitude.apiKeyEnv] ?? '').trim();
    if (key.isEmpty) {
      return CheckResult.error(
        title,
        detail: 'missing env: ${amplitude.apiKeyEnv}',
        fix: '1. Create the project once in Amplitude (Settings > '
            'Organization settings > Projects)\n'
            '2. Copy its API key from the project\'s General settings\n'
            '3. Export ${amplitude.apiKeyEnv}=<key>',
      );
    }
    final devKey = (context.env[amplitude.devApiKeyEnv] ?? '').trim();
    if (devKey.isEmpty) {
      return CheckResult.warning(
        title,
        detail: '${amplitude.apiKeyEnv} set, '
            '${amplitude.devApiKeyEnv} missing',
        fix: 'Debug builds get an empty key (the SDK no-ops). Export '
            '${amplitude.devApiKeyEnv}=<key> to send development events to a '
            'separate Amplitude project.',
      );
    }
    return const CheckResult.ok(title, detail: 'prod + dev keys set');
  }
}

/// Reports which AdMob API credential is available, since that decides
/// whether missing app / ad unit IDs can be resolved without the console.
/// Runs only when `admob:` is configured with `auto` left on.
class AdmobApiAccessCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.integrations;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'AdMob API credential';
    final admob = context.config?.admob;
    if (context.config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    if (admob == null) {
      return const CheckResult.skipped(title,
          detail: "'admob' section not configured");
    }
    if (!admob.auto) {
      return const CheckResult.skipped(title,
          detail: 'admob.auto is off — IDs come from easy_setup.yaml');
    }
    // Every ID pinned in the yaml → setup never calls the API, so a missing
    // credential is not worth a warning.
    final everythingDeclared = admob.iosAppId != null &&
        admob.androidAppId != null &&
        admob.adUnits.values
            .every((unit) => unit.ios != null && unit.android != null);
    if (everythingDeclared) {
      return const CheckResult.skipped(title,
          detail: 'every ID is declared — nothing to look up');
    }
    final source = await admobCredentialSource(context);
    if (source == null) {
      return CheckResult.warning(
        title,
        detail: 'none found',
        fix: AdmobApi.credentialsHint,
      );
    }
    return CheckResult.ok(title, detail: source);
  }
}

/// Names the credential source `setup` would use for the AdMob API, or null
/// when there is none.
Future<String?> admobCredentialSource(DoctorContext context) async {
  if ((context.env[AdmobApi.accessTokenEnv] ?? '').trim().isNotEmpty) {
    return AdmobApi.accessTokenEnv;
  }
  if (AdmobApi.hasEnvCredentials(context.env)) {
    return '${AdmobApi.refreshTokenEnv} + OAuth client';
  }
  if (await context.processes.which('gcloud') != null) {
    // Installed is not logged in — mint a token to find out.
    final result = await context.processes.run(
      'gcloud',
      ['auth', 'application-default', 'print-access-token'],
    );
    if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) {
      return 'gcloud application-default credentials';
    }
  }
  return null;
}
