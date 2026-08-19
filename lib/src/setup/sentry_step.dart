import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import 'env_json_writer.dart';
import 'pubspec_text.dart';
import 'setup_step.dart';

/// Provisions the Sentry project and wires the app to it (V2_PLAN.md §5.5):
/// create the project when missing (idempotent), fetch the DSN, write
/// `SENTRY_DSN` into env.json / env.prod.json for --dart-define-from-file,
/// and finish the pubspec side — the `sentry_flutter` dependency plus the
/// `sentry_dart_plugin` block that uploads debug symbols on every build.
///
/// Everything but the one-time org token comes from the API, so re-pointing
/// an app at a fresh Sentry project never means opening the web UI.
class SentryStep extends SetupStep {
  static const tokenEnv = 'SENTRY_ORG_TOKEN';

  /// Env var sentry-cli (through sentry_dart_plugin) reads at build time.
  static const buildTokenEnv = 'SENTRY_AUTH_TOKEN';

  /// Self-hosted instances can override via the SENTRY_URL env var.
  static const defaultBaseUrl = 'https://sentry.io';

  @override
  String get name => 'sentry';

  @override
  bool isConfigured(ProjectConfig config) => config.sentry != null;

  @override
  Future<void> run(SetupContext context) async {
    final sentry = context.config.sentry!;
    final projectSlug = sentry.project ?? _slugify(context.config.app.name);

    if (context.dryRun) {
      context.out
        ..writeln('  [dry-run] Would ensure Sentry project '
            '"${sentry.org}/$projectSlug" exists (create when missing)')
        ..writeln('  [dry-run] Would fetch its DSN and write SENTRY_DSN '
            'into env.json and env.prod.json');
      if (sentry.sdk) {
        context.out
            .writeln('  [dry-run] Would ensure the sentry_flutter dependency');
      }
      context.out.writeln(sentry.uploadSymbols
          ? '  [dry-run] Would ensure sentry_dart_plugin and the pubspec.yaml '
              '`sentry:` block (org/project/upload_debug_symbols)'
          : '  [dry-run] Would set upload_debug_symbols: false in '
              'pubspec.yaml');
      return;
    }

    final token = context.env[tokenEnv];
    if (token == null || token.trim().isEmpty) {
      throw SetupException(
        'Sentry setup needs the $tokenEnv environment variable.\n'
        '1. Sentry > Settings > Auth Tokens: create an organization token\n'
        '   with the org:write and project:write scopes\n'
        '2. Export $tokenEnv=<token>',
      );
    }

    final baseUrl = context.env['SENTRY_URL'] ?? defaultBaseUrl;
    final headers = {'Authorization': 'Bearer $token'};

    final teamSlug =
        sentry.team ?? await _firstTeamSlug(context, baseUrl, headers);

    // Create the project — 409 means it already exists (idempotent).
    final createResponse = await context.http.post(
      Uri.parse('$baseUrl/api/0/teams/${sentry.org}/$teamSlug/projects/'),
      headers: headers,
      body: {'name': projectSlug, 'slug': projectSlug, 'platform': 'flutter'},
    );
    if (createResponse.status == 409) {
      context.out.writeln(
          '  ✓ Sentry project ${sentry.org}/$projectSlug already exists');
    } else if (createResponse.ok) {
      context.out.writeln(
          '  ✓ Created Sentry project ${sentry.org}/$projectSlug '
          '(team: $teamSlug)');
    } else {
      throw SetupException(
        'Sentry project creation failed '
        '(HTTP ${createResponse.status}): ${createResponse.body}',
      );
    }

    final dsn = await _fetchDsn(context, baseUrl, headers, sentry, projectSlug);
    for (final fileName in ['env.json', 'env.prod.json']) {
      final path = p.join(context.projectRoot, fileName);
      final changed = EnvJsonWriter.merge(path, {'SENTRY_DSN': dsn});
      context.out.writeln(changed
          ? '  ✓ Wrote SENTRY_DSN to $fileName'
          : '  ✓ $fileName already up to date');
    }
    context.out.writeln('  → Pass to builds with '
        '--dart-define-from-file=env.json (or env.prod.json)');

    await _wirePubspec(context, sentry, projectSlug, baseUrl);
  }

  /// The pubspec side: the SDK dependency and the sentry_dart_plugin config
  /// that points symbol upload at this org/project. Both are idempotent, and
  /// keys the developer added to the `sentry:` block are left alone.
  Future<void> _wirePubspec(
    SetupContext context,
    SentryConfig sentry,
    String projectSlug,
    String baseUrl,
  ) async {
    if (sentry.sdk) {
      await ensurePubDependency(context, 'sentry_flutter');
    }
    if (sentry.uploadSymbols) {
      await ensurePubDependency(context, 'sentry_dart_plugin', dev: true);
    }

    final file = File(p.join(context.projectRoot, 'pubspec.yaml'));
    if (!file.existsSync()) return;
    final text = file.readAsStringSync();
    // Opting out converges too: an earlier run's `upload_debug_symbols: true`
    // is turned off rather than left uploading (the plugin defaults to
    // uploading, so the key has to say false rather than disappear). The
    // dependency stays — removing a package the app may use elsewhere is not
    // this step's call. With no block at all there is nothing uploading, so
    // opting out writes nothing.
    if (!sentry.uploadSymbols &&
        !PubspecText.hasTopLevelBlock(text, 'sentry')) {
      return;
    }
    final updated = PubspecText.ensureTopLevelBlock(text, 'sentry', {
      'upload_debug_symbols': sentry.uploadSymbols,
      if (sentry.uploadSymbols) ...{
        'org': sentry.org,
        'project': projectSlug,
        // sentry-cli defaults to sentry.io, so a self-hosted instance has to
        // be named for the build as well as for the API calls above — and
        // dropped again when the config moves back to the hosted service.
        'url': baseUrl != defaultBaseUrl ? baseUrl : null,
      },
    });
    if (updated == text) {
      context.out.writeln('  ✓ pubspec.yaml `sentry:` block up to date');
    } else {
      file.writeAsStringSync(updated);
      context.out.writeln(sentry.uploadSymbols
          ? '  ✓ Wrote the pubspec.yaml `sentry:` block '
              '(org: ${sentry.org}, project: $projectSlug)'
          : '  ✓ Turned off upload_debug_symbols in pubspec.yaml');
    }
    if (!sentry.uploadSymbols) return;

    // The plugin is a post-build command, not part of `flutter build`.
    context.out.writeln('  → Upload symbols after a build with: '
        'flutter pub run sentry_dart_plugin');
    final buildToken = context.env[buildTokenEnv];
    if (buildToken == null || buildToken.trim().isEmpty) {
      context.out.writeln(
          '  ! It reads \$$buildTokenEnv — the org token works:\n'
          '    export $buildTokenEnv=\$$tokenEnv '
          '(and add it as a CI secret)');
    }
  }

  Future<String> _firstTeamSlug(
    SetupContext context,
    String baseUrl,
    Map<String, String> headers,
  ) async {
    final org = context.config.sentry!.org;
    final response = await context.http.get(
      Uri.parse('$baseUrl/api/0/organizations/$org/teams/'),
      headers: headers,
    );
    if (!response.ok || response.body is! List) {
      throw SetupException(
        'Could not list Sentry teams for org "$org" '
        '(HTTP ${response.status}). Set sentry.team in easy_setup.yaml, or '
        'check the token scopes.',
      );
    }
    final teams = response.body as List;
    final slug = teams.isEmpty ? null : (teams.first as Map)['slug'];
    if (slug is! String || slug.isEmpty) {
      throw SetupException(
        'Sentry org "$org" has no teams — create one in Sentry or set '
        'sentry.team in easy_setup.yaml.',
      );
    }
    return slug;
  }

  Future<String> _fetchDsn(
    SetupContext context,
    String baseUrl,
    Map<String, String> headers,
    SentryConfig sentry,
    String projectSlug,
  ) async {
    final response = await context.http.get(
      Uri.parse('$baseUrl/api/0/projects/${sentry.org}/$projectSlug/keys/'),
      headers: headers,
    );
    if (!response.ok || response.body is! List) {
      throw SetupException(
        'Could not fetch Sentry client keys for '
        '${sentry.org}/$projectSlug (HTTP ${response.status}).',
      );
    }
    final keys = response.body as List;
    final dsn = keys.isEmpty
        ? null
        : (((keys.first as Map)['dsn'] as Map?)?['public']);
    if (dsn is! String || dsn.isEmpty) {
      throw SetupException(
        'Sentry project ${sentry.org}/$projectSlug has no client keys — '
        'create one in Sentry (Settings > Client Keys).',
      );
    }
    return dsn;
  }

  static String _slugify(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}
