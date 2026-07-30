import 'dart:io';

import 'package:path/path.dart' as p;

import '../exceptions.dart';

/// `easy_setup init` — creates a v2 easy_setup.yaml template and the asset
/// folder skeleton (branding icon sources, store screenshots).
class InitCommand {
  /// Asset directories created relative to the project root.
  static const assetDirectories = [
    'assets/branding/icon',
    'assets/store/screenshots',
  ];

  /// Creates easy_setup.yaml and the asset skeleton in [directory].
  ///
  /// Missing values are prompted for when [interactive] is true (only when
  /// running on a terminal), otherwise placeholder defaults are used.
  /// Refuses to overwrite an existing easy_setup.yaml unless [force] is set.
  static Future<int> run({
    required String directory,
    String? appName,
    String? bundleId,
    String? packageName,
    bool force = false,
    bool dryRun = false,
    bool interactive = false,
    StringSink? out,
  }) async {
    final sink = out ?? stdout;
    final configPath = p.join(directory, 'easy_setup.yaml');
    if (File(configPath).existsSync() && !force) {
      throw SetupException(
        'easy_setup.yaml already exists at $configPath.\n'
        'Use --force to overwrite it.',
      );
    }

    String ask(String label, String? provided, String fallback) {
      final value = provided?.trim();
      if (value != null && value.isNotEmpty) return value;
      if (interactive) {
        sink.write('$label [$fallback]: ');
        final input = stdin.readLineSync()?.trim();
        if (input != null && input.isNotEmpty) return input;
      }
      return fallback;
    }

    final name = ask('App display name', appName, 'MyApp');
    final bundle = ask('iOS bundle ID', bundleId, 'com.example.myapp');
    final package = ask('Android package name', packageName, bundle);

    final prefix = dryRun ? '[dry-run] would create' : 'Created';

    if (!dryRun) {
      File(configPath).writeAsStringSync(template(
        appName: name,
        bundleId: bundle,
        packageName: package,
      ));
    }
    sink.writeln('$prefix $configPath');

    for (final relative in assetDirectories) {
      final dir = Directory(p.join(directory, relative));
      if (!dryRun) {
        dir.createSync(recursive: true);
        final gitkeep = File(p.join(dir.path, '.gitkeep'));
        if (!gitkeep.existsSync()) gitkeep.writeAsStringSync('');
      }
      sink.writeln('$prefix ${dir.path}/');
    }

    sink.writeln();
    sink.writeln('Next steps:');
    sink.writeln('  1. Uncomment the sections you need in easy_setup.yaml');
    sink.writeln('  2. Run `easy_setup doctor` to verify keys and tooling');
    return 0;
  }

  /// Quotes [value] as a single-quoted YAML scalar so user input containing
  /// YAML syntax (`:`, `#`, quotes, ...) cannot break the generated file.
  static String _yamlQuote(String value) => "'${value.replaceAll("'", "''")}'";

  /// The generated easy_setup.yaml contents (v2 schema).
  ///
  /// Only the required `app:` section is active; everything else ships as
  /// commented-out examples the user opts into.
  static String template({
    required String appName,
    required String bundleId,
    required String packageName,
  }) =>
      '''
# easy_setup configuration (v2 schema)
#
# One file drives the Setup Kit (provisioning, native config, assets) and
# the Deploy Kit (code signing, builds, store uploads).
# Uncomment the sections you need, then run:
#   easy_setup doctor   — verify environment, keys, and secrets
#   easy_setup setup    — apply the declared state (idempotent)

app:
  name: ${_yamlQuote(appName)}
  bundle_id: ${_yamlQuote(bundleId)}          # iOS bundle identifier
  package_name: ${_yamlQuote(packageName)}    # Android application ID

# ios:
#   team_id: XXXXXXXXXX                 # Apple Developer Team ID
#   match_git_url: git@github.com:my-org/certificates.git
#   capabilities:
#     - push_notifications
#     - app_groups: [group.$bundleId]
#   background_modes: [audio, fetch]    # Info.plist UIBackgroundModes

# android:
#   play_track_default: internal        # internal | alpha | beta | production

# flavors:
#   dev: { suffix: .dev, name: ${_yamlQuote('$appName DEV')} }
#   prod: {}

# branding:
#   icon_src: assets/branding/icon/     # icon.png (1024, no alpha) + fg/bg/mono.png

# screenshots:
#   locales: [en-US]
#   devices: [iphone_6_9, ipad_13, android_phone]
#   captions: assets/store/screenshots/captions.yaml

# sentry:
#   org: my-org
#   project: myapp                      # created automatically when missing

# firebase:
#   project_id: my-org-myapp            # created automatically when missing
#   analytics: true

# admob:
#   ios_app_id: ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY
#   android_app_id: ca-app-pub-XXXXXXXXXXXXXXXX~ZZZZZZZZZZ
#   ad_units:
#     banner_main:
#       ios: ca-app-pub-XXXXXXXXXXXXXXXX/YYYYYYYYYY
#       android: ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ
''';
}
