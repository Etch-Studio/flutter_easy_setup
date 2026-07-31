import 'dart:io';

import 'package:path/path.dart' as p;

import '../appstore/asc_api_client.dart';
import '../appstore/asc_jwt.dart';
import '../config/project_config.dart';
import '../doctor/checks/ios_deploy_checks.dart';
import '../exceptions.dart';
import '../utils/project_finder.dart';
import 'plist_text.dart';
import 'setup_step.dart';

/// Applies `ios.capabilities` / `ios.background_modes` across all three
/// locations (V2_PLAN.md §5.3):
///
/// - `ios/Runner/Runner.entitlements` — generated/merged from capabilities
/// - `ios/Flutter/{Debug,Release}.xcconfig` — wires CODE_SIGN_ENTITLEMENTS
/// - `Info.plist` — `UIBackgroundModes` entries
/// - Developer Portal (ASC API): registers the bundle ID when missing and
///   enables the declared capability types — automated when the ASC API
///   key env vars are set, manual guidance otherwise
class IosCapabilitiesStep extends SetupStep {
  static const entitlementsRelativePath = 'ios/Runner/Runner.entitlements';

  /// Capabilities this step can express as entitlements today.
  static const supportedCapabilities = ['push_notifications', 'app_groups'];

  /// Capability name → ASC API capability type.
  static const portalCapabilityTypes = {
    'push_notifications': 'PUSH_NOTIFICATIONS',
    'app_groups': 'APP_GROUPS',
  };

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

    await _syncPortal(context, ios);
  }

  /// Registers the bundle ID and enables the declared capability types on
  /// the Developer Portal via the ASC API.
  Future<void> _syncPortal(SetupContext context, IosConfig ios) async {
    final desiredTypes = [
      for (final capability in ios.capabilities)
        if (portalCapabilityTypes.containsKey(capability.name))
          portalCapabilityTypes[capability.name]!,
    ];
    if (desiredTypes.isEmpty) return;

    if (!AscEnv.isComplete(context.env)) {
      context.out.writeln(
          '  ! ASC API key not set (ASC_KEY_ID / ASC_ISSUER_ID / '
          'ASC_KEY_P8[_PATH]) — enable the App ID capabilities manually at '
          'developer.apple.com > Identifiers, then regenerate profiles '
          '(capability changes invalidate them): the next '
          '`easy_setup deploy` run or `fastlane match --force`.');
      return;
    }

    final bundleId = context.config.app.bundleId;
    if (context.dryRun) {
      context.out
        ..writeln('  [dry-run] Would ensure bundle ID $bundleId is '
            'registered on the Developer Portal')
        ..writeln('  [dry-run] Would enable missing capabilities: '
            '${desiredTypes.join(', ')}');
      return;
    }

    final privateKey = AscEnv.resolveKey(context.env);
    if (privateKey == null) {
      throw SetupException(
          'ASC_KEY_P8_PATH points to a missing file — run '
          '`easy_setup doctor`.');
    }
    final client = AscApiClient(
      http: context.http,
      token: AscJwt.generate(
        keyId: context.env[AscEnv.keyId]!,
        issuerId: context.env[AscEnv.issuerId]!,
        privateKeyPem: privateKey,
      ),
    );

    var resourceId = await client.findBundleId(bundleId);
    if (resourceId == null) {
      resourceId = await client.registerBundleId(
          bundleId, context.config.app.name);
      context.out
          .writeln('  ✓ Registered bundle ID $bundleId on the portal');
    } else {
      context.out.writeln('  ✓ Bundle ID $bundleId already registered');
    }

    final existing = await client.capabilityTypes(resourceId);
    var enabledAny = false;
    for (final type in desiredTypes) {
      if (existing.contains(type)) continue;
      await client.enableCapability(resourceId, type);
      context.out.writeln('  ✓ Enabled $type on the App ID');
      enabledAny = true;
    }
    if (!enabledAny) {
      context.out.writeln('  ✓ Portal capabilities up to date');
    } else {
      context.out.writeln(
          '  ! Capability changes invalidate existing provisioning '
          'profiles — regenerate them with the next `easy_setup deploy` '
          'run or `fastlane match --force`.');
    }

    // Enabling APP_GROUPS is not the same as associating the concrete
    // group IDs — the public ASC API does not expose that assignment.
    final groups = [
      for (final capability in ios.capabilities)
        if (capability.name == 'app_groups') ...capability.parameters,
    ];
    if (groups.isNotEmpty) {
      context.out.writeln(
          '  ! Assigning the specific app groups (${groups.join(', ')}) to '
          'the App ID is not exposed by the public ASC API — assign them '
          'once at developer.apple.com > Identifiers > $bundleId > '
          'App Groups, or let Xcode automatic signing manage them.');
    }
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
