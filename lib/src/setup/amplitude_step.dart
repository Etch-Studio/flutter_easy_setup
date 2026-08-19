import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../utils/http_json_client.dart';
import 'env_json_writer.dart';
import 'pubspec_text.dart';
import 'setup_step.dart';

/// Wires Amplitude product analytics without a console visit after the
/// project exists (V2_PLAN.md §5.5b):
///
/// - takes the API key from an environment variable, never a tracked file
/// - verifies it against the ingestion API (an empty event batch, so the
///   probe cannot pollute the project)
/// - writes `AMPLITUDE_API_KEY` into env.json (dev key, or empty so the SDK
///   no-ops) and env.prod.json (production key)
/// - adds the `amplitude_flutter` dependency
///
/// Amplitude has no project-creation API — only ingestion, query, Experiment
/// and SCIM APIs — so creating the project itself stays a one-time console
/// step, which `doctor` spells out.
class AmplitudeStep extends SetupStep {
  /// Amplitude's own wording for a key it does not recognize.
  static const _invalidKeyMarker = 'invalid api key';

  @override
  String get name => 'amplitude';

  @override
  bool isConfigured(ProjectConfig config) => config.amplitude != null;

  @override
  Future<void> run(SetupContext context) async {
    final amplitude = context.config.amplitude!;

    if (context.dryRun) {
      context.out
        ..writeln('  [dry-run] Would read the API key from '
            '\$${amplitude.apiKeyEnv} and verify it against '
            '${amplitude.ingestionUrl}')
        ..writeln('  [dry-run] Would write ${AmplitudeConfig.envKey} into '
            'env.json and env.prod.json');
      if (amplitude.sdk) {
        context.out
            .writeln('  [dry-run] Would ensure the amplitude_flutter '
                'dependency');
      }
      return;
    }

    final prodKey = _key(context, amplitude.apiKeyEnv);
    if (prodKey == null) {
      throw SetupException(
        'Amplitude setup needs the ${amplitude.apiKeyEnv} environment '
        'variable.\n'
        '1. Create the project once in Amplitude (Settings > Organization '
        'settings\n'
        '   > Projects) — Amplitude has no project-creation API, so this is '
        'the\n'
        '   only console step\n'
        '2. Copy its API key from the project\'s General settings\n'
        '3. Export ${amplitude.apiKeyEnv}=<key>',
      );
    }
    final devKey = _key(context, amplitude.devApiKeyEnv);

    if (amplitude.verify) {
      await _verify(context, amplitude, prodKey, amplitude.apiKeyEnv);
      if (devKey != null) {
        await _verify(context, amplitude, devKey, amplitude.devApiKeyEnv);
      }
    }

    if (devKey == null) {
      context.out.writeln(
          '  ! ${amplitude.devApiKeyEnv} is not set — debug builds get an '
          'empty key, which makes the SDK a no-op');
    }

    final serverZone = amplitude.region == 'eu' ? 'EU' : null;
    for (final (fileName, key) in [
      ('env.json', devKey ?? ''),
      ('env.prod.json', prodKey),
    ]) {
      final changed = EnvJsonWriter.merge(
        p.join(context.projectRoot, fileName),
        {
          AmplitudeConfig.envKey: key,
          'AMPLITUDE_SERVER_ZONE': ?serverZone,
        },
        // Only these two keys belong to the step — an AMPLITUDE_* key the
        // developer added for something else is not ours to delete.
        prunes: (key) => key == 'AMPLITUDE_SERVER_ZONE',
      );
      context.out.writeln(changed
          ? '  ✓ Wrote ${AmplitudeConfig.envKey} to $fileName'
          : '  ✓ $fileName already up to date');
    }

    if (amplitude.sdk) {
      await ensurePubDependency(context, 'amplitude_flutter');
    }
    context.out.writeln('  → Pass to builds with '
        '--dart-define-from-file=env.json (or env.prod.json)');
  }

  String? _key(SetupContext context, String envName) {
    final value = context.env[envName]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Posts an empty event batch: Amplitude checks the key before it looks at
  /// the batch, so an accepted key ingests nothing and a wrong one is named
  /// in the error.
  Future<void> _verify(
    SetupContext context,
    AmplitudeConfig amplitude,
    String key,
    String envName,
  ) async {
    final JsonResponse response;
    try {
      response = await context.http.post(
        Uri.parse(amplitude.ingestionUrl),
        body: {'api_key': key, 'events': const <Object>[]},
      );
    } on SetupException catch (e) {
      // A network problem is not a wrong key — say so and keep going.
      context.out.writeln('  ! Could not verify $envName '
          '(${e.message.split('\n').first})');
      return;
    }
    final body = response.body;
    final error = body is Map ? body['error'] : null;
    if (error is String && error.toLowerCase().contains(_invalidKeyMarker)) {
      throw SetupException(
        'Amplitude rejected the key in $envName'
        '${amplitude.project == null ? '' : ' for project '
            '"${amplitude.project}"'}: $error\n'
        'Copy the API key from the project\'s General settings and re-export '
        '$envName.',
      );
    }
    if (!response.ok) {
      // A 5xx or a rate limit says nothing about the key — it must not read
      // as approval, and it must not fail the run either.
      context.out.writeln('  ! Could not verify $envName '
          '(HTTP ${response.status}'
          '${error is String ? ': $error' : ''})');
      return;
    }
    context.out.writeln('  ✓ $envName accepted by Amplitude '
        '(${amplitude.region.toUpperCase()} ingestion)');
  }
}
