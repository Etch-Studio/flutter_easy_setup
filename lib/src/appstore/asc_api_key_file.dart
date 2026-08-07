import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../doctor/checks/ios_deploy_checks.dart';

/// Writes the fastlane API key JSON (consumed via `--api_key_path` by
/// match, pilot, and deliver) from the ASC_* environment variables into
/// [workDir]. Callers own the ephemeral directory's lifecycle.
String writeAscApiKeyJson(Directory workDir, Map<String, String> env) {
  final rawKey = env[AscEnv.keyP8];
  final key = (rawKey != null && rawKey.trim().isNotEmpty)
      ? rawKey
      : File(env[AscEnv.keyP8Path]!).readAsStringSync();
  final file = File(p.join(workDir.path, 'api_key.json'));
  file.writeAsStringSync(json.encode({
    'key_id': env[AscEnv.keyId],
    'issuer_id': env[AscEnv.issuerId],
    'key': key,
    'in_house': false,
  }));
  return file.path;
}
