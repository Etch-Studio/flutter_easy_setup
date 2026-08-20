import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../admob/admob_api.dart';
import '../../config/project_config.dart';
import '../../exceptions.dart';
import '../../utils/http_json_client.dart';
import '../../utils/project_finder.dart';
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

/// Verifies release builds will actually carry the values the Setup Kit
/// writes. Runs when a step that writes dart-defines is configured.
///
/// Without the env file, `flutter build` compiles `SENTRY_DSN` and friends as
/// empty strings and every SDK no-ops — an upload that looks fine and reports
/// nothing.
class DartDefineFileCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.integrations;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'Release dart-defines';
    final config = context.config;
    if (config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    final writers = [
      if (config.sentry != null) 'sentry',
      if (config.amplitude != null) 'amplitude',
      if (config.admob != null) 'admob',
    ];
    if (writers.isEmpty) {
      return const CheckResult.skipped(title,
          detail: 'no step writes dart-defines');
    }
    final root = context.projectRoot;
    if (root == null) {
      return const CheckResult.skipped(title, detail: 'no project root');
    }
    final fileName =
        config.build?.dartDefineFile ?? BuildConfig.defaultDartDefineFile;
    final file = File(p.join(root, fileName));
    if (!file.existsSync()) {
      return CheckResult.warning(
        title,
        detail: 'missing: $fileName',
        fix: 'Run `easy_setup setup` — ${writers.join(' / ')} write into it. '
            'Release builds pass it as --dart-define-from-file; without it '
            'every value compiles as an empty string and the SDKs no-op.',
      );
    }
    final Object? decoded;
    try {
      decoded = json.decode(file.readAsStringSync());
    } on FormatException {
      return CheckResult.error(title, detail: '$fileName is not valid JSON');
    }
    if (decoded is! Map) {
      return CheckResult.error(
          title, detail: '$fileName must contain a JSON object');
    }
    // Names only — the values are keys and DSNs.
    final empty = decoded.entries
        .where((entry) => '${entry.value}'.trim().isEmpty)
        .map((entry) => '${entry.key}')
        .toList();
    if (empty.isNotEmpty) {
      return CheckResult.warning(
        title,
        detail: '$fileName has ${decoded.length} key(s), '
            'empty: ${empty.join(', ')}',
      );
    }
    return CheckResult.ok(title,
        detail: '$fileName, ${decoded.length} key(s)');
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
    // A gcloud ADC token belongs to gcloud's own OAuth client, which has no
    // project — so AdMob refuses every call, listing included, until one is
    // named. Nothing about the token says so; only the 403 does.
    if (source == gcloudCredentialSource) {
      final project = (context.env[AdmobApi.quotaProjectEnv] ?? '')
              .trim()
              .isNotEmpty
          ? context.env[AdmobApi.quotaProjectEnv]!.trim()
          : AdmobApi.adcQuotaProject(context.env);
      if (project == null) {
        return CheckResult.warning(
          title,
          detail: '$source, no quota project',
          fix: 'An ADC token carries no project of its own, so AdMob answers '
              '403 until one is named:\n'
              '  gcloud auth application-default set-quota-project '
              '<project-id>\n'
              'Any project the signed-in user can reach works, as long as '
              'admob.googleapis.com is enabled on it. '
              'export ${AdmobApi.quotaProjectEnv}=<project-id> does the same '
              'for one shell.',
        );
      }
      return CheckResult.ok(title, detail: '$source (project $project)');
    }
    return CheckResult.ok(title, detail: source);
  }
}

/// What [admobCredentialSource] calls gcloud's application-default
/// credentials — the one source that also needs a quota project.
const gcloudCredentialSource = 'gcloud application-default credentials';

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
      return gcloudCredentialSource;
    }
  }
  return null;
}

/// Verifies that the `app-ads.txt` programmatic buyers look for is actually
/// served, and that it authorizes this publisher account.
///
/// This is the one part of AdMob setup nothing can automate: crawlers read
/// the developer website out of the store listing, **drop the path**, and
/// fetch `/app-ads.txt` from the domain root — a host easy_setup never
/// writes to (on GitHub Pages, only a repo named `<owner>.github.io` serves
/// it). What can be automated is noticing the file is missing, which
/// otherwise surfaces months later as unexplained low fill rather than as an
/// error: ads keep serving, just to fewer bidders.
class AppAdsTxtCheck extends DoctorCheck {
  @override
  String get category => DoctorCategory.integrations;

  /// Both app IDs (`ca-app-pub-…~…`) and unit IDs carry the publisher.
  static final _publisherPattern = RegExp(r'ca-app-(pub-\d+)[~/]');

  /// The ad system AdMob sells through. Records naming anyone else are other
  /// networks' business — they do not authorize AdMob.
  static const _adSystem = 'google.com';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    const title = 'app-ads.txt';
    final config = context.config;
    if (config == null) {
      return const CheckResult.skipped(title,
          detail: 'no valid easy_setup.yaml');
    }
    if (config.admob == null) {
      return const CheckResult.skipped(title,
          detail: "'admob' section not configured");
    }
    final host = _host(config.site?.baseUrl);
    if (host == null) {
      return const CheckResult.skipped(title,
          detail: 'no site.base_url — no domain to serve it from');
    }
    final publisherId = _publisherId(context);
    if (publisherId == null) {
      return const CheckResult.skipped(title,
          detail: 'no publisher ID resolved yet — run setup --only admob');
    }
    final uri = Uri.https(host, '/app-ads.txt');

    final JsonResponse response;
    try {
      response = await context.http.get(uri);
    } catch (e) {
      // The host is arbitrary and so is what it can do to us: offline, DNS
      // failure, TLS error, a captive portal answering with nonsense. All of
      // it is worth reporting and none of it is worth aborting the run for —
      // DoctorRunner has no per-check guard, so anything escaping here would
      // take the whole report down.
      return CheckResult.warning(title,
          detail: 'could not reach $host',
          fix: e is SetupException ? e.message : '$e');
    }
    if (!response.ok) {
      return CheckResult.warning(
        title,
        detail: 'not served at $uri (HTTP ${response.status})',
        fix: _fix(host, publisherId),
      );
    }
    final body = response.body is String ? response.body as String : '';
    if (!_authorizes(body, publisherId)) {
      return CheckResult.warning(
        title,
        detail: '$uri does not authorize $publisherId',
        fix: _fix(host, publisherId),
      );
    }
    return CheckResult.ok(title, detail: '$uri authorizes $publisherId');
  }

  /// Host of [baseUrl] — the path is dropped, exactly as a crawler drops it.
  String? _host(String? baseUrl) {
    if (baseUrl == null || baseUrl.trim().isEmpty) return null;
    final uri = Uri.tryParse(baseUrl.trim());
    return (uri == null || uri.host.isEmpty) ? null : uri.host;
  }

  /// The publisher account whose inventory this app sells: declared in the
  /// yaml, or read back out of what the admob step already wrote.
  String? _publisherId(DoctorContext context) {
    final admob = context.config!.admob!;
    final declared = admob.publisherId?.trim();
    if (declared != null && declared.isNotEmpty) return declared;
    final root = context.projectRoot;
    for (final id in [
      admob.iosAppId,
      admob.androidAppId,
      if (root != null) _nativeAppId(root),
    ]) {
      final match = id == null ? null : _publisherPattern.firstMatch(id);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// The app ID out of the native file — read from the key that holds it,
  /// never by scanning the file. A project that has carried more than one
  /// AdMob app has the old ID sitting in a comment, and the first match in
  /// the file would be that one.
  String? _nativeAppId(String projectRoot) {
    final plist = File(ProjectFinder.iosInfoPlistPath(projectRoot));
    if (plist.existsSync()) {
      final match = RegExp(r'<key>\s*GADApplicationIdentifier\s*</key>\s*'
              r'<string>([^<]*)</string>')
          .firstMatch(_withoutXmlComments(plist.readAsStringSync()));
      final id = match?.group(1)?.trim();
      if (id != null && id.isNotEmpty) return id;
    }
    final manifest = File(ProjectFinder.androidManifestPath(projectRoot));
    if (manifest.existsSync()) {
      final content = _withoutXmlComments(manifest.readAsStringSync());
      // Attributes are unordered, so the element is found first and read
      // after — the same reason admob_step parses it this way.
      for (final element in RegExp(
              r'<meta-data\b[^>]*?(?:/>|>\s*</meta-data>)',
              dotAll: true)
          .allMatches(content)) {
        final xml = element.group(0)!;
        if (!xml.contains('com.google.android.gms.ads.APPLICATION_ID')) {
          continue;
        }
        final value =
            RegExp(r'android:value\s*=\s*"([^"]*)"').firstMatch(xml);
        final id = value?.group(1)?.trim();
        if (id != null && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  static String _withoutXmlComments(String xml) =>
      xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  /// Whether any record authorizes AdMob to sell for [publisherId].
  ///
  /// One record per line, `<ad system>, <publisher id>, <relationship>[, <certification id>]`,
  /// with `#` starting a comment (ads.txt 1.1, which
  /// app-ads.txt inherits wholesale). All three of the first fields are
  /// required and all three are checked: a record naming another exchange —
  /// a mediation partner, or `google.com.example` — does not authorize
  /// AdMob, and matching the publisher alone would call such a file good.
  bool _authorizes(String body, String publisherId) {
    for (final rawLine in body.split(RegExp(r'\r\n|[\r\n]'))) {
      final hash = rawLine.indexOf('#');
      final line = hash < 0 ? rawLine : rawLine.substring(0, hash);
      final fields = [for (final field in line.split(',')) field.trim()];
      if (fields.length < 3) continue;
      if (fields[0].toLowerCase() != _adSystem) continue;
      if (fields[1].toLowerCase() != publisherId.toLowerCase()) continue;
      final relationship = fields[2].toUpperCase();
      if (relationship != 'DIRECT' && relationship != 'RESELLER') continue;
      return true;
    }
    return false;
  }

  String _fix(String host, String publisherId) =>
      'Publish this line at https://$host/app-ads.txt — the domain root, not '
      'a subpath, because the crawler drops the path:\n'
      '  google.com, $publisherId, DIRECT, f08c47fec0942fa0\n'
      'Copy the exact contents from the AdMob console (Apps > app-ads.txt) '
      'when the account has mediation partners — each one adds a record. On '
      'GitHub Pages the root is served by a repository named '
      '$host, not by the app\'s own Pages repository.\n'
      'The app\'s store listing must also carry that URL as its developer '
      'website, or the crawler never learns the domain.';
}
