import 'dart:io';

import '../models/flavor_config.dart';

/// A class that creates or modifies the iOS Podfile.
///
/// If no Podfile exists, creates a standard Flutter Podfile.
/// If one exists, adds per-flavor build mode mappings to it.
///
/// If permissions are provided, adds permission_handler macros
/// as GCC_PREPROCESSOR_DEFINITIONS in the post_install block.
class PodfileModifier {
  /// Mapping from Info.plist permission keys to permission_handler GCC macros
  static const _permissionMacroMap = <String, String>{
    'NSCameraUsageDescription': 'PERMISSION_CAMERA=1',
    'NSMicrophoneUsageDescription': 'PERMISSION_MICROPHONE=1',
    'NSPhotoLibraryUsageDescription': 'PERMISSION_PHOTOS=1',
    'NSPhotoLibraryAddUsageDescription': 'PERMISSION_PHOTOS=1',
    'NSLocationWhenInUseUsageDescription': 'PERMISSION_LOCATION_WHENINUSE=1',
    'NSLocationAlwaysAndWhenInUseUsageDescription': 'PERMISSION_LOCATION=1',
    'NSLocationAlwaysUsageDescription': 'PERMISSION_LOCATION=1',
    'NSContactsUsageDescription': 'PERMISSION_CONTACTS=1',
    'NSCalendarsUsageDescription': 'PERMISSION_EVENTS=1',
    'NSCalendarsFullAccessUsageDescription': 'PERMISSION_EVENTS_FULL_ACCESS=1',
    'NSCalendarsWriteOnlyAccessUsageDescription': 'PERMISSION_EVENTS=1',
    'NSRemindersUsageDescription': 'PERMISSION_REMINDERS=1',
    'NSRemindersFullAccessUsageDescription': 'PERMISSION_REMINDERS=1',
    'NSSpeechRecognitionUsageDescription': 'PERMISSION_SPEECH_RECOGNIZER=1',
    'NSMotionUsageDescription': 'PERMISSION_SENSORS=1',
    'NSBluetoothAlwaysUsageDescription': 'PERMISSION_BLUETOOTH=1',
    'NSBluetoothPeripheralUsageDescription': 'PERMISSION_BLUETOOTH=1',
    'NSAppleMusicUsageDescription': 'PERMISSION_MEDIA_LIBRARY=1',
    'NSUserTrackingUsageDescription': 'PERMISSION_APP_TRACKING_TRANSPARENCY=1',
    'NSFaceIDUsageDescription': 'PERMISSION_SENSORS=1',
  };

  /// Creates or modifies the Podfile.
  ///
  /// [permission]: permission map from easy_setup.yaml (keys are mapped to macros)
  /// [iosVersion]: iOS minimum deployment target (e.g., "15.0")
  static void modify(
    String podfilePath,
    Map<String, FlavorConfig> flavors, {
    Map<String, String>? permission,
    String? iosVersion,
    bool dryRun = false,
  }) {
    final version = iosVersion ?? '15.0';
    final file = File(podfilePath);

    print('  · Podfile ${file.existsSync() ? "found" : "not found — creating"}');
    if (!file.existsSync()) {
      _createPodfile(file, flavors,
          permission: permission, iosVersion: version, dryRun: dryRun);
      return;
    }

    _modifyExistingPodfile(file, flavors,
        permission: permission, iosVersion: version, dryRun: dryRun);
  }

  /// Resolves the required GCC macro list from permission keys.
  static Set<String> _resolveMacros(Map<String, String>? permission) {
    if (permission == null || permission.isEmpty) return {};
    final macros = <String>{};
    for (final key in permission.keys) {
      final macro = _permissionMacroMap[key];
      if (macro != null) {
        macros.add(macro);
      }
    }
    return macros;
  }

  /// Builds the post_install block.
  static String _buildPostInstall(Set<String> macros, String iosVersion) {
    final sb = StringBuffer();
    sb.writeln('post_install do |installer|');
    sb.writeln('  installer.pods_project.targets.each do |target|');
    sb.writeln('    flutter_additional_ios_build_settings(target)');
    sb.writeln('');
    sb.writeln('    target.build_configurations.each do |config|');

    if (macros.isNotEmpty) {
      sb.writeln(
          "      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [");
      sb.writeln("        '\$(inherited)',");
      for (final macro in macros) {
        sb.writeln("        '$macro',");
      }
      sb.writeln('      ]');
    }

    sb.writeln(
        "      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '$iosVersion'");
    sb.writeln('    end');

    sb.writeln('  end');
    sb.writeln('end');
    return sb.toString();
  }

  /// Creates a standard Flutter Podfile.
  static void _createPodfile(
    File file,
    Map<String, FlavorConfig> flavors, {
    Map<String, String>? permission,
    required String iosVersion,
    required bool dryRun,
  }) {
    final configBlock = _buildConfigBlock(flavors);
    final macros = _resolveMacros(permission);
    final postInstall = _buildPostInstall(macros, iosVersion);

    final content = '''# Uncomment this line to define a global platform for your project
platform :ios, '$iosVersion'

# CocoaPods analytics sends network stats synchronously affecting flutter build latency.
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
$configBlock
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. If you're running pod install manually, make sure flutter pub get is executed first"
  end

  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. Try deleting Generated.xcconfig, then run flutter pub get"
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end

$postInstall''';

    if (dryRun) {
      print('  · [dry-run] Would create Podfile');
      return;
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    print('  ✓ Podfile created');
  }

  /// Adds per-flavor build mode mappings and permission macros to an existing Podfile.
  static void _modifyExistingPodfile(
    File file,
    Map<String, FlavorConfig> flavors, {
    Map<String, String>? permission,
    required String iosVersion,
    required bool dryRun,
  }) {
    var content = file.readAsStringSync();

    // 1. Update platform :ios version
    content = _applyPlatformVersion(content, iosVersion);

    // 2. Apply flavor mappings
    content = _applyFlavorMappings(content, flavors);

    // 3. Apply permission macros + IPHONEOS_DEPLOYMENT_TARGET
    final macros = _resolveMacros(permission);
    content = _applyPostInstallConfig(content, macros, iosVersion);

    if (dryRun) {
      print('  · [dry-run] Would update Podfile');
      return;
    }

    file.writeAsStringSync(content);
    print('  ✓ Podfile updated');
  }

  /// Updates the platform :ios version.
  static String _applyPlatformVersion(String content, String iosVersion) {
    final pattern = RegExp(r"platform\s*:ios\s*,\s*'[^']*'");
    if (pattern.hasMatch(content)) {
      print('  · platform :ios → $iosVersion');
      return content.replaceFirst(pattern, "platform :ios, '$iosVersion'");
    }
    return content;
  }

  /// Replaces the entire project 'Runner' block.
  static String _applyFlavorMappings(
      String content, Map<String, FlavorConfig> flavors) {
    final projectBlock = RegExp(
      r"project\s+'Runner'\s*,\s*\{[^}]*\}",
      dotAll: true,
    );

    final newBlock = "project 'Runner', {\n${_buildConfigBlock(flavors)}\n}";

    if (projectBlock.hasMatch(content)) {
      print("  · project 'Runner' block found — inserting");
      return content.replaceFirst(projectBlock, newBlock);
    }

    // If no project block exists, add it after the platform line
    print("  · project 'Runner' block not found — inserting");
    final platformPattern = RegExp(r"platform\s*:ios\s*,\s*'[^']*'");
    if (platformPattern.hasMatch(content)) {
      return content.replaceFirstMapped(platformPattern, (match) {
        return '${match.group(0)}\n\n$newBlock';
      });
    }

    return content;
  }

  /// Replaces the entire post_install block.
  static String _applyPostInstallConfig(
      String content, Set<String> macros, String iosVersion) {
    // Find and replace the entire post_install block
    final postInstallBlock = RegExp(
      r'post_install do \|installer\|[\s\S]*?^end\n?',
      multiLine: true,
    );

    final newPostInstall = _buildPostInstall(macros, iosVersion);

    if (postInstallBlock.hasMatch(content)) {
      print('  · post_install block found — replacing');
      return content.replaceFirst(postInstallBlock, newPostInstall);
    }

    // If no post_install exists, append to the end
    print('  · post_install block not found — appending');
    return '$content\n$newPostInstall';
  }

  /// Builds the content of the project 'Runner' block.
  static String _buildConfigBlock(Map<String, FlavorConfig> flavors) {
    final sb = StringBuffer();
    for (final flavor in flavors.keys) {
      sb.writeln("  'Debug-$flavor' => :debug,");
      sb.writeln("  'Profile-$flavor' => :release,");
      sb.writeln("  'Release-$flavor' => :release,");
    }
    return sb.toString().trimRight();
  }
}
