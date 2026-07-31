import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../exceptions.dart';
import '../utils/project_finder.dart';
import 'plist_text.dart';
import 'setup_step.dart';

/// Applies the local parts of `ios.capabilities` / `ios.background_modes`
/// (V2_PLAN.md §5.3):
///
/// - `ios/Runner/Runner.entitlements` — generated/merged from capabilities
/// - `ios/Flutter/{Debug,Release}.xcconfig` — wires CODE_SIGN_ENTITLEMENTS
/// - `Info.plist` — `UIBackgroundModes` entries
///
/// Developer Portal App ID capabilities (ASC API `bundleIdCapabilities`)
/// follow in M4c; until then the step prints where to enable them manually.
class IosCapabilitiesStep extends SetupStep {
  static const entitlementsRelativePath = 'ios/Runner/Runner.entitlements';

  /// Capabilities this step can express as entitlements today.
  static const supportedCapabilities = ['push_notifications', 'app_groups'];

  @override
  String get name => 'ios_capabilities';

  @override
  bool isConfigured(ProjectConfig config) {
    final ios = config.ios;
    return ios != null &&
        (ios.capabilities.isNotEmpty || ios.backgroundModes.isNotEmpty);
  }

  @override
  Future<void> run(SetupContext context) async {
    final ios = context.config.ios!;

    final unsupported = ios.capabilities
        .where((c) => !supportedCapabilities.contains(c.name))
        .map((c) => c.name)
        .toList();
    if (unsupported.isNotEmpty) {
      context.out.writeln(
          '  ! Unsupported capability entries (add their entitlements '
          'manually for now): ${unsupported.join(', ')}');
    }

    if (ios.capabilities.any((c) => supportedCapabilities.contains(c.name))) {
      _writeEntitlements(context, ios);
      _wireXcconfig(context);
    }
    if (ios.backgroundModes.isNotEmpty) {
      _injectBackgroundModes(context, ios);
    }

    context.out.writeln(
        '  ! Developer Portal App ID capabilities are not automated yet — '
        'enable them at developer.apple.com > Identifiers, then regenerate '
        'profiles (they are invalidated by capability changes): '
        'the next `easy_setup deploy` run or `fastlane match --force`.');
  }

  /// Creates or merges Runner.entitlements from the declared capabilities.
  void _writeEntitlements(SetupContext context, IosConfig ios) {
    final push = ios.capabilities.any((c) => c.name == 'push_notifications');
    final groups = [
      for (final capability in ios.capabilities)
        if (capability.name == 'app_groups') ...capability.parameters,
    ];

    final file =
        File(p.join(context.projectRoot, entitlementsRelativePath));
    var changed = false;

    String content;
    if (!file.existsSync()) {
      content = _freshEntitlements(push: push, groups: groups);
      changed = true;
    } else {
      content = file.readAsStringSync();
      if (push && !content.contains('<key>aps-environment</key>')) {
        content = PlistText.insertBeforeFinalDictClose(content, '''
	<key>aps-environment</key>
	<string>development</string>
''');
        changed = true;
      }
      if (groups.isNotEmpty) {
        const groupsKey = 'com.apple.security.application-groups';
        if (!content.contains('<key>$groupsKey</key>')) {
          final entries =
              groups.map((g) => '\t\t<string>$g</string>\n').join();
          content = PlistText.insertBeforeFinalDictClose(content, '''
	<key>$groupsKey</key>
	<array>
$entries	</array>
''');
          changed = true;
        } else {
          for (final group in groups) {
            // Membership is checked inside the key's own array, so an
            // identical string elsewhere in the file cannot mask it.
            final existing =
                PlistText.arrayContent(content, groupsKey) ?? '';
            if (existing.contains('<string>$group</string>')) continue;
            content = PlistText.appendToArray(
                content, groupsKey, '\t\t<string>$group</string>\n');
            changed = true;
          }
        }
      }
    }

    if (!changed) {
      context.out.writeln('  ✓ $entitlementsRelativePath up to date');
      return;
    }
    if (!context.dryRun) {
      file.createSync(recursive: true);
      file.writeAsStringSync(content);
    }
    context.out.writeln(
        '  ${context.dryRun ? '[dry-run] Would write' : '✓ Wrote'} '
        '$entitlementsRelativePath');
  }

  String _freshEntitlements({required bool push, required List<String> groups}) {
    final buffer = StringBuffer('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
''');
    if (push) {
      buffer.write('''
	<key>aps-environment</key>
	<string>development</string>
''');
    }
    if (groups.isNotEmpty) {
      buffer.write('''
	<key>com.apple.security.application-groups</key>
	<array>
${groups.map((g) => '\t\t<string>$g</string>\n').join()}	</array>
''');
    }
    buffer.write('</dict>\n</plist>\n');
    return buffer.toString();
  }

  /// Points CODE_SIGN_ENTITLEMENTS at the entitlements file via the Flutter
  /// xcconfig files — no pbxproj surgery needed.
  void _wireXcconfig(SetupContext context) {
    const value = 'Runner/Runner.entitlements';
    const line = 'CODE_SIGN_ENTITLEMENTS = $value';
    // Only an active (uncommented) assignment counts.
    final assignment = RegExp(r'^\s*CODE_SIGN_ENTITLEMENTS\s*=\s*(.+)$',
        multiLine: true);
    for (final name in [
      'Debug.xcconfig',
      'Release.xcconfig',
      // Not part of a stock Flutter project, but wired when present
      // (flavored projects have it).
      'Profile.xcconfig',
    ]) {
      final file = File(
          p.join(ProjectFinder.iosXcconfigDir(context.projectRoot), name));
      if (!file.existsSync()) {
        if (name != 'Profile.xcconfig') {
          context.out.writeln(
              '  ! ios/Flutter/$name not found — set CODE_SIGN_ENTITLEMENTS '
              'manually.');
        }
        continue;
      }
      final content = file.readAsStringSync();
      final existing = assignment.firstMatch(content);
      if (existing != null) {
        final current = existing.group(1)!.trim();
        context.out.writeln(current == value
            ? '  ✓ ios/Flutter/$name already wires CODE_SIGN_ENTITLEMENTS'
            : '  ! ios/Flutter/$name sets CODE_SIGN_ENTITLEMENTS to '
                '"$current" — merge $entitlementsRelativePath into that '
                'file manually.');
        continue;
      }
      if (!context.dryRun) {
        final separator = content.endsWith('\n') ? '' : '\n';
        file.writeAsStringSync('$content$separator$line\n');
      }
      context.out.writeln(
          '  ${context.dryRun ? '[dry-run] Would add' : '✓ Added'} '
          'CODE_SIGN_ENTITLEMENTS to ios/Flutter/$name');
    }
  }

  /// Ensures every declared background mode is in Info.plist
  /// UIBackgroundModes.
  void _injectBackgroundModes(SetupContext context, IosConfig ios) {
    if (ios.backgroundModes.contains('remote-notification') &&
        !ios.capabilities.any((c) => c.name == 'push_notifications')) {
      context.out.writeln(
          "  ! background mode 'remote-notification' needs the "
          "push_notifications capability — add it to ios.capabilities.");
    }

    final path = ProjectFinder.iosInfoPlistPath(context.projectRoot);
    final file = File(path);
    if (!file.existsSync()) {
      throw SetupException('Info.plist not found at $path.');
    }
    var content = file.readAsStringSync();
    var changed = false;

    const key = 'UIBackgroundModes';
    if (!content.contains('<key>$key</key>')) {
      final entries =
          ios.backgroundModes.map((m) => '\t\t<string>$m</string>\n').join();
      content = PlistText.insertBeforeFinalDictClose(content, '''
	<key>$key</key>
	<array>
$entries	</array>
''');
      changed = true;
    } else {
      for (final mode in ios.backgroundModes) {
        // Scoped to the UIBackgroundModes array — the same string under
        // another key does not count.
        final existing = PlistText.arrayContent(content, key) ?? '';
        if (existing.contains('<string>$mode</string>')) continue;
        content =
            PlistText.appendToArray(content, key, '\t\t<string>$mode</string>\n');
        changed = true;
      }
    }

    if (!changed) {
      context.out.writeln('  ✓ Info.plist UIBackgroundModes up to date');
      return;
    }
    if (!context.dryRun) file.writeAsStringSync(content);
    context.out.writeln(
        '  ${context.dryRun ? '[dry-run] Would write' : '✓ Wrote'} '
        'UIBackgroundModes (${ios.backgroundModes.join(', ')}) to Info.plist');
  }
}
