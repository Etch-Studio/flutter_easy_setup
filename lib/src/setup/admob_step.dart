import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../utils/project_finder.dart';
import 'env_json_writer.dart';
import 'setup_step.dart';

/// Injects AdMob app IDs into the native projects and ad unit IDs into the
/// dart-define env files (V2_PLAN.md §5.4, Plan B — IDs are created once in
/// the AdMob console and declared in easy_setup.yaml):
///
/// - AndroidManifest.xml: `com.google.android.gms.ads.APPLICATION_ID`
/// - Info.plist: `GADApplicationIdentifier` + `SKAdNetworkItems`
/// - env.json (debug → Google's official test IDs when `type` is declared)
///   and env.prod.json (real IDs), keyed `ADMOB_<NAME>_<PLATFORM>`
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
    if (admob.androidAppId != null) {
      _injectManifest(context, admob.androidAppId!);
    }
    if (admob.iosAppId != null) {
      _injectInfoPlist(context, admob.iosAppId!);
    }
    if (admob.androidAppId == null || admob.iosAppId == null) {
      context.out.writeln(
          '  ! Missing app ID(s) — create the app(s) once in the AdMob '
          'console and fill in admob.ios_app_id / admob.android_app_id.');
    }
    _writeAdUnits(context, admob);
  }

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
      content = _insertBeforeFinalDictClose(content, '''
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
      content = _insertBeforeFinalDictClose(content, '''
	$skAdNetworkKey
	<array>
$googleEntry	</array>
''');
      changed = true;
    } else if (!content.contains(googleSkAdNetworkId)) {
      // The app already lists other ad networks — append Google's required
      // identifier to the existing array.
      final keyIndex = content.indexOf(skAdNetworkKey);
      final emptyArray = RegExp(r'<array\s*/>');
      final emptyMatch = emptyArray.firstMatch(content.substring(keyIndex));
      final openIndex = content.indexOf('<array>', keyIndex);
      if (emptyMatch != null &&
          (openIndex < 0 || keyIndex + emptyMatch.start < openIndex)) {
        content = content.replaceRange(
          keyIndex + emptyMatch.start,
          keyIndex + emptyMatch.end,
          '<array>\n$googleEntry\t</array>',
        );
      } else if (openIndex >= 0) {
        final insertAt = openIndex + '<array>'.length;
        content = content.replaceRange(
            insertAt, insertAt, '\n$googleEntry\t');
      } else {
        throw SetupException(
          'Info.plist has SKAdNetworkItems but no parsable <array> — '
          'add $googleSkAdNetworkId manually.',
        );
      }
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

  String _insertBeforeFinalDictClose(String plist, String block) {
    final closeIndex = plist.lastIndexOf('</dict>');
    if (closeIndex < 0) {
      throw SetupException('Info.plist has no closing </dict> tag.');
    }
    return plist.substring(0, closeIndex) + block + plist.substring(closeIndex);
  }

  /// env.json gets test IDs (when the ad format is declared), env.prod.json
  /// the real IDs — both keyed `ADMOB_<NAME>_<PLATFORM>`. Keys under the
  /// ADMOB_ prefix converge: entries removed from the YAML disappear.
  void _writeAdUnits(SetupContext context, AdmobConfig admob) {
    final debugValues = <String, String>{};
    final prodValues = <String, String>{};
    for (final entry in admob.adUnits.entries) {
      final key = 'ADMOB_${entry.key.toUpperCase()}';
      final unit = entry.value;
      for (final (platform, id) in [
        ('ios', unit.ios),
        ('android', unit.android),
      ]) {
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
        ownedPrefix: 'ADMOB_',
      );
      context.out.writeln(changed
          ? '  ${context.dryRun ? '[dry-run] Would write' : '✓ Wrote'} '
              '${values.length} ad unit ID(s) to $fileName'
          : '  ✓ $fileName ad unit IDs up to date');
    }
  }
}
