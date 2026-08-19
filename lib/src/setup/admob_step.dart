import 'dart:io';

import 'package:path/path.dart' as p;

import '../admob/admob_api.dart';
import '../config/project_config.dart';
import '../exceptions.dart';
import '../utils/project_finder.dart';
import 'env_json_writer.dart';
import 'plist_text.dart';
import 'setup_step.dart';

/// Injects AdMob app IDs into the native projects and ad unit IDs into the
/// dart-define env files (V2_PLAN.md §5.4):
///
/// - AndroidManifest.xml: `com.google.android.gms.ads.APPLICATION_ID`
/// - Info.plist: `GADApplicationIdentifier` + `SKAdNetworkItems`
/// - env.json (debug → Google's official test IDs when `type` is declared)
///   and env.prod.json (real IDs), keyed `ADMOB_<NAME>_<PLATFORM>`
///
/// IDs the yaml does not declare are looked up through the AdMob API instead
/// of being copied out of the console: apps are matched per platform (by
/// store ID on Android, by name otherwise), ad units by their display name.
/// Missing ones are created when the account has creation access — that call
/// is limited access and answers 403 for most publishers, which degrades to
/// a console-creation message with the lookup still doing the ID work.
class AdmobStep extends SetupStep {
  /// Google's own SKAdNetwork identifier — the minimum required entry.
  static const googleSkAdNetworkId = 'cstr6suwn9.skadnetwork';

  /// Google's official test ad unit IDs per format.
  static const testAdUnits = {
    'android': {
      'banner': 'ca-app-pub-3940256099942544/6300978111',
      'interstitial': 'ca-app-pub-3940256099942544/1033173712',
      'rewarded': 'ca-app-pub-3940256099942544/5224354917',
      'native': 'ca-app-pub-3940256099942544/2247696110',
      'app_open': 'ca-app-pub-3940256099942544/9257395921',
    },
    'ios': {
      'banner': 'ca-app-pub-3940256099942544/2934735716',
      'interstitial': 'ca-app-pub-3940256099942544/4411468910',
      'rewarded': 'ca-app-pub-3940256099942544/1712485313',
      'native': 'ca-app-pub-3940256099942544/3986624511',
      'app_open': 'ca-app-pub-3940256099942544/5575463023',
    },
  };

  @override
  String get name => 'admob';

  @override
  bool isConfigured(ProjectConfig config) => config.admob != null;

  @override
  Future<void> run(SetupContext context) async {
    final admob = context.config.admob!;
    final ids = _AdmobIds.declared(admob);
    final platforms = _targetPlatforms(context);

    // Under --dry-run the lookup is only announced, so what it would have
    // resolved is unknown and reporting gaps would be misleading.
    var lookupDeferred = false;
    if (admob.auto && ids.hasGaps(admob, platforms)) {
      if (context.dryRun) {
        lookupDeferred = true;
        context.out.writeln(
            '  [dry-run] Would resolve the missing app / ad unit IDs through '
            'the AdMob API');
      } else {
        await _resolveThroughApi(context, admob, ids, platforms);
      }
    }

    if (ids.androidAppId != null) {
      _injectManifest(context, ids.androidAppId!);
    }
    if (ids.iosAppId != null) {
      _injectInfoPlist(context, ids.iosAppId!);
    }
    for (final platform in platforms) {
      if (ids.appId(platform) != null || lookupDeferred) continue;
      context.out.writeln(
          '  ! No $platform app ID — set admob.${platform}_app_id, or create '
          'the app once in the AdMob console (https://apps.admob.com)');
    }
    _writeAdUnits(context, admob, ids);
  }

  /// Platforms this project can actually be configured for — the native file
  /// each injection needs has to exist.
  Set<String> _targetPlatforms(SetupContext context) => {
        if (File(ProjectFinder.iosInfoPlistPath(context.projectRoot))
            .existsSync())
          'ios',
        if (File(ProjectFinder.androidManifestPath(context.projectRoot))
            .existsSync())
          'android',
      };

  /// Fills the gaps in [ids] from the AdMob API. Every failure here is a
  /// warning, not an error: the declared IDs still get injected, and doctor
  /// reports what is still unresolved.
  Future<void> _resolveThroughApi(
    SetupContext context,
    AdmobConfig admob,
    _AdmobIds ids,
    Set<String> platforms,
  ) async {
    final api = AdmobApi(
      http: context.http,
      env: context.env,
      processes: context.processes,
    );
    try {
      final account = await api.accountName(publisherId: admob.publisherId);
      final apps = await api.listApps(account);
      for (final platform in platforms) {
        if (ids.appId(platform) != null) continue;
        await _resolveApp(context, api, account, apps, ids, platform);
      }
      await _resolveAdUnits(context, api, account, admob, ids, platforms);
    } on SetupException catch (e) {
      context.out
          .writeln('  ! AdMob lookup skipped:\n${_indent(e.message)}');
    }
  }

  Future<void> _resolveApp(
    SetupContext context,
    AdmobApi api,
    String account,
    List<AdmobApp> apps,
    _AdmobIds ids,
    String platform,
  ) async {
    final appName = context.config.app.name;
    final expectedStoreId =
        platform == 'android' ? context.config.app.packageName : null;
    final onPlatform =
        apps.where((app) => app.platform == platform.toUpperCase());
    // The store link is an identity; a name is a coincidence waiting to
    // happen, so it only decides when no linked app matches.
    final byStoreId = expectedStoreId == null
        ? const <AdmobApp>[]
        : onPlatform.where((app) => app.storeId == expectedStoreId).toList();
    final matches = byStoreId.isNotEmpty
        ? byStoreId
        : onPlatform
            .where((app) =>
                app.displayName?.toLowerCase() == appName.toLowerCase())
            .toList();
    if (matches.length > 1) {
      context.out.writeln(
          '  ! ${matches.length} AdMob $platform apps match "$appName" — '
          'using ${matches.first.appId}; set admob.${platform}_app_id to pin '
          'one');
    }
    if (matches.isNotEmpty) {
      ids.setAppId(platform, matches.first.appId);
      context.out.writeln(
          '  ✓ Matched AdMob $platform app ${matches.first.appId}');
      return;
    }
    final created = await api.createApp(
      account,
      platform: platform.toUpperCase(),
      displayName: appName,
    );
    if (created == null) {
      context.out.writeln(
          '  ! AdMob refused to create the $platform app (403 — app creation '
          'is limited access)');
      return;
    }
    ids.setAppId(platform, created.appId);
    context.out
        .writeln('  ✓ Created AdMob $platform app ${created.appId}');
  }

  Future<void> _resolveAdUnits(
    SetupContext context,
    AdmobApi api,
    String account,
    AdmobConfig admob,
    _AdmobIds ids,
    Set<String> platforms,
  ) async {
    final wanted = [
      for (final entry in admob.adUnits.entries)
        for (final platform in platforms)
          if (ids.appId(platform) != null &&
              ids.adUnitId(platform, entry.key) == null)
            (entry.key, entry.value, platform),
    ];
    if (wanted.isEmpty) return;

    final existing = await api.listAdUnits(account);
    for (final (name, unit, platform) in wanted) {
      final appId = ids.appId(platform)!;
      final displayName = unit.displayName ?? name;
      final adFormat = AdmobApi.adFormats[unit.type];
      final match = existing
          .where((candidate) =>
              candidate.appId == appId &&
              candidate.displayName?.toLowerCase() ==
                  displayName.toLowerCase())
          .firstOrNull;
      if (match != null) {
        // Adopting a unit of the wrong format would ship, say, a banner ID
        // in a rewarded placement — and env.json would carry the test ID of
        // the declared format, hiding it in debug.
        if (adFormat != null &&
            match.adFormat != null &&
            match.adFormat != adFormat) {
          // Rejecting it also means dropping whatever a previous run wrote:
          // that ID belongs to the unit this check just refused.
          ids.reject(platform, name);
          context.out.writeln(
              '  ! $platform ad unit "$displayName" is a ${match.adFormat} '
              'unit, but admob.ad_units.$name.type says ${unit.type} — '
              'rename one of them, or fix the type');
          continue;
        }
        ids.setAdUnitId(platform, name, match.adUnitId);
        context.out.writeln(
            '  ✓ Matched $platform ad unit "$displayName" '
            '(${match.adUnitId})');
        continue;
      }
      if (adFormat == null) {
        context.out.writeln(
            '  ! No $platform ad unit named "$displayName" — declare '
            "admob.ad_units.$name.type to let easy_setup create it");
        continue;
      }
      final created = await api.createAdUnit(
        account,
        appId: appId,
        displayName: displayName,
        adFormat: adFormat,
      );
      if (created == null) {
        context.out.writeln(
            '  ! AdMob refused to create the $platform ad unit '
            '"$displayName" (403 — ad unit creation is limited access)');
        continue;
      }
      ids.setAdUnitId(platform, name, created.adUnitId);
      context.out.writeln('  ✓ Created $platform ad unit "$displayName" '
          '(${created.adUnitId})');
    }
  }

  /// Indents a multi-line hint under a step's output bullet.
  static String _indent(String text) =>
      text.split('\n').map((line) => '    $line').join('\n');

  /// Adds/updates the APPLICATION_ID meta-data inside `<application>`.
  void _injectManifest(SetupContext context, String appId) {
    final path = ProjectFinder.androidManifestPath(context.projectRoot);
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException('AndroidManifest.xml not found at $path.');
    }
    final content = file.readAsStringSync();
    const metaName = 'com.google.android.gms.ads.APPLICATION_ID';

    String updated;
    if (content.contains(metaName)) {
      // Locate the whole <meta-data> element — XML attributes are unordered,
      // so android:value may come before android:name.
      final element = RegExp(r'<meta-data\b[^>]*?(?:/>|>\s*</meta-data>)',
              dotAll: true)
          .allMatches(content)
          .where((match) => match.group(0)!.contains(metaName))
          .firstOrNull;
      if (element == null) {
        throw SetupException(
          'Found $metaName in AndroidManifest.xml but could not parse its '
          '<meta-data> element — fix it manually.',
        );
      }
      var newElement = element.group(0)!.replaceFirstMapped(
            RegExp(r'android:value\s*=\s*"[^"]*"'),
            (match) => 'android:value="$appId"',
          );
      if (!newElement.contains('android:value="$appId"')) {
        // No value attribute at all — rewrite the element canonically.
        newElement =
            '<meta-data android:name="$metaName" android:value="$appId" />';
      }
      updated =
          content.replaceRange(element.start, element.end, newElement);
      if (updated == content) {
        context.out
            .writeln('  ✓ AndroidManifest.xml APPLICATION_ID up to date');
        return;
      }
    } else {
      final closeTag = content.indexOf('</application>');
      if (closeTag < 0) {
        throw SetupException(
            'No </application> tag found in AndroidManifest.xml.');
      }
      final metaData = '''
        <meta-data
            android:name="$metaName"
            android:value="$appId" />
''';
      updated =
          content.substring(0, closeTag) + metaData + content.substring(closeTag);
    }
    if (!context.dryRun) file.writeAsStringSync(updated);
    context.out.writeln(
        '  ${context.dryRun ? '[dry-run] Would write' : '✓ Wrote'} '
        'APPLICATION_ID to AndroidManifest.xml');
  }

  /// Adds/updates GADApplicationIdentifier and ensures SKAdNetworkItems.
  void _injectInfoPlist(SetupContext context, String appId) {
    final path = ProjectFinder.iosInfoPlistPath(context.projectRoot);
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException('Info.plist not found at $path.');
    }
    var content = file.readAsStringSync();
    var changed = false;

    if (content.contains('<key>GADApplicationIdentifier</key>')) {
      final updated = content.replaceFirstMapped(
        RegExp('(<key>GADApplicationIdentifier</key>\\s*<string>)[^<]*'
            '(</string>)'),
        (match) => '${match.group(1)}$appId${match.group(2)}',
      );
      changed = updated != content;
      content = updated;
    } else {
      content = PlistText.insertBeforeFinalDictClose(content, '''
	<key>GADApplicationIdentifier</key>
	<string>$appId</string>
''');
      changed = true;
    }

    const skAdNetworkKey = '<key>SKAdNetworkItems</key>';
    const googleEntry = '''
		<dict>
			<key>SKAdNetworkIdentifier</key>
			<string>$googleSkAdNetworkId</string>
		</dict>
''';
    if (!content.contains(skAdNetworkKey)) {
      content = PlistText.insertBeforeFinalDictClose(content, '''
	$skAdNetworkKey
	<array>
$googleEntry	</array>
''');
      changed = true;
    } else if (!(PlistText.arrayContent(content, 'SKAdNetworkItems') ?? '')
        .contains(googleSkAdNetworkId)) {
      // The app already lists other ad networks — append Google's required
      // identifier to the existing array.
      content =
          PlistText.appendToArray(content, 'SKAdNetworkItems', googleEntry);
      changed = true;
    }

    if (!changed) {
      context.out.writeln('  ✓ Info.plist AdMob entries up to date');
      return;
    }
    if (!context.dryRun) file.writeAsStringSync(content);
    context.out.writeln(
        '  ${context.dryRun ? '[dry-run] Would write' : '✓ Wrote'} '
        'GADApplicationIdentifier + SKAdNetworkItems to Info.plist');
  }

  /// env.json gets test IDs (when the ad format is declared), env.prod.json
  /// the real IDs — both keyed `ADMOB_<NAME>_<PLATFORM>`. Keys under the
  /// ADMOB_ prefix converge: entries removed from the YAML disappear.
  void _writeAdUnits(
      SetupContext context, AdmobConfig admob, _AdmobIds ids) {
    // Keys of units the yaml still declares. With the lookup on they are
    // never pruned — after a failed lookup the value already in the file is
    // the only one the project has. With `auto: false` there is nothing to
    // resolve, so the yaml is the whole truth and stale keys must go.
    final declaredKeys = <String>{
      for (final name in admob.adUnits.keys)
        for (final platform in ['ios', 'android'])
          if (!ids.isRejected(platform, name))
            'ADMOB_${name.toUpperCase()}_${platform.toUpperCase()}',
    };
    final debugValues = <String, String>{};
    final prodValues = <String, String>{};
    for (final entry in admob.adUnits.entries) {
      final key = 'ADMOB_${entry.key.toUpperCase()}';
      final unit = entry.value;
      for (final platform in ['ios', 'android']) {
        final id = ids.adUnitId(platform, entry.key);
        if (id == null) continue;
        final envKey = '${key}_${platform.toUpperCase()}';
        prodValues[envKey] = id;
        debugValues[envKey] =
            unit.type != null ? testAdUnits[platform]![unit.type]! : id;
      }
    }
    for (final (fileName, values) in [
      ('env.json', debugValues),
      ('env.prod.json', prodValues),
    ]) {
      final path = p.join(context.projectRoot, fileName);
      // Nothing declared and no file to clean up → nothing to do.
      if (values.isEmpty && !File(path).existsSync()) continue;
      final changed = EnvJsonWriter.merge(
        path,
        values,
        dryRun: context.dryRun,
        prunes: (key) =>
            key.startsWith('ADMOB_') &&
            (!admob.auto || !declaredKeys.contains(key)),
      );
      context.out.writeln(changed
          ? '  ${context.dryRun ? '[dry-run] Would write' : '✓ Wrote'} '
              '${values.length} ad unit ID(s) to $fileName'
          : '  ✓ $fileName ad unit IDs up to date');
    }
  }
}

/// The IDs one run works with: what easy_setup.yaml declared, plus whatever
/// the AdMob API resolved on top of it. Declared IDs always win, so pinning
/// an ID in the yaml keeps the API out of the way.
class _AdmobIds {
  String? iosAppId;
  String? androidAppId;

  /// (platform, ad unit name) → ad unit ID.
  final Map<(String, String), String> adUnits = {};

  /// Units the lookup refused — a same-named unit of another format. Their
  /// env keys are stale by definition, so they lose their pruning exemption.
  final Set<(String, String)> _rejected = {};

  _AdmobIds({this.iosAppId, this.androidAppId});

  factory _AdmobIds.declared(AdmobConfig admob) {
    final ids = _AdmobIds(
      iosAppId: admob.iosAppId,
      androidAppId: admob.androidAppId,
    );
    admob.adUnits.forEach((name, unit) {
      final ios = unit.ios;
      final android = unit.android;
      if (ios != null) ids.adUnits[('ios', name)] = ios;
      if (android != null) ids.adUnits[('android', name)] = android;
    });
    return ids;
  }

  String? appId(String platform) =>
      platform == 'ios' ? iosAppId : androidAppId;

  void setAppId(String platform, String id) {
    if (platform == 'ios') {
      iosAppId = id;
    } else {
      androidAppId = id;
    }
  }

  String? adUnitId(String platform, String name) => adUnits[(platform, name)];

  void reject(String platform, String name) =>
      _rejected.add((platform, name));

  bool isRejected(String platform, String name) =>
      _rejected.contains((platform, name));

  void setAdUnitId(String platform, String name, String id) =>
      adUnits[(platform, name)] = id;

  /// Whether anything the project targets is still unresolved.
  bool hasGaps(AdmobConfig admob, Set<String> platforms) => platforms.any(
        (platform) =>
            appId(platform) == null ||
            admob.adUnits.keys
                .any((name) => adUnitId(platform, name) == null),
      );
}
