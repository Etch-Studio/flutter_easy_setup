import 'dart:convert';
import 'dart:io';

import '../check.dart';

/// Verifies the Google Play service account credentials are available.
///
/// `PLAY_SERVICE_ACCOUNT_JSON` accepts either raw JSON or a path to a JSON
/// file. Missing credentials are an error when the `android:` section is
/// configured, otherwise a warning (the project may not deploy to Play yet).
class PlayServiceAccountCheck extends DoctorCheck {
  static const envName = 'PLAY_SERVICE_ACCOUNT_JSON';

  static const _issueFix = '''
1. Google Cloud Console > IAM & Admin > Service Accounts: create a service
   account and download its JSON key
2. Play Console > Users and permissions: invite the service account email
   with release permission
3. Export PLAY_SERVICE_ACCOUNT_JSON (path to the JSON file, or the raw JSON)''';

  @override
  String get category => DoctorCategory.androidDeploy;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'Play service account';
    final config = context.config;
    if (config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    final required = config.android != null;
    final value = context.env[envName];

    if (value == null || value.trim().isEmpty) {
      const detail = 'missing env: $envName';
      return required
          ? const CheckResult.error(title, detail: detail, fix: _issueFix)
          : const CheckResult.warning(title, detail: detail, fix: _issueFix);
    }

    String jsonText = value;
    if (!value.trimLeft().startsWith('{')) {
      final file = File(value);
      if (!file.existsSync()) {
        return CheckResult.error(
          title,
          detail: '$envName points to a missing file: $value',
          fix: _issueFix,
        );
      }
      jsonText = file.readAsStringSync();
    }

    try {
      final decoded = json.decode(jsonText);
      final email = decoded is Map ? decoded['client_email'] : null;
      if (email is! String || email.isEmpty) {
        return const CheckResult.error(
          title,
          detail: 'JSON has no client_email — not a service account key',
          fix: _issueFix,
        );
      }
      return CheckResult.ok(title, detail: email);
    } on FormatException {
      return const CheckResult.error(
        title,
        detail: '$envName is not valid JSON',
        fix: _issueFix,
      );
    }
  }
}
