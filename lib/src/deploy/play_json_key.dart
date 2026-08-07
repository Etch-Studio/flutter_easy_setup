import 'dart:io';

import 'package:path/path.dart' as p;

import '../doctor/checks/android_deploy_checks.dart';

/// Resolves `PLAY_SERVICE_ACCOUNT_JSON` into a file path for fastlane's
/// `--json_key`: a path value passes through, raw JSON is materialized as
/// an ephemeral file in [workDir] (callers own the directory's lifecycle).
String resolvePlayJsonKey(Directory workDir, Map<String, String> env) {
  final value = env[PlayServiceAccountCheck.envName]!;
  if (!value.trimLeft().startsWith('{')) return value;
  final file = File(p.join(workDir.path, 'play_service_account.json'));
  file.writeAsStringSync(value);
  return file.path;
}
