import 'dart:io';

import 'package:path/path.dart' as p;

/// Utility class for locating and returning various file paths in a Flutter project.
///
/// Provides project root auto-detection, config file paths, and Android/iOS file paths.
class ProjectFinder {
  /// Traverses parent directories from [startDir] to find the Flutter project root.
  ///
  /// A directory is considered a Flutter project if its pubspec.yaml contains
  /// the 'sdk: flutter' or 'flutter:' keyword.
  /// Returns null if the root directory ('/') is reached without finding one.
  static String? findFlutterRoot([String? startDir]) {
    var dir = Directory(startDir ?? Directory.current.path);
    while (true) {
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        // Flutter projects reference the Flutter SDK in pubspec.yaml
        if (content.contains('sdk: flutter') || content.contains('  flutter:')) {
          return dir.path;
        }
      }
      final parent = dir.parent;
      // Stop searching when the root directory is reached
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Returns the full path to the easy_setup.yaml configuration file.
  static String configPath([String? projectRoot]) =>
      p.join(projectRoot ?? Directory.current.path, 'easy_setup.yaml');

  /// Returns the path to the Android app module's build.gradle(.kts).
  ///
  /// Returns the Kotlin DSL (.kts) file path if it exists,
  /// otherwise returns the Groovy DSL (.gradle) path.
  static String androidBuildGradlePath(String projectRoot) {
    final kts = p.join(projectRoot, 'android', 'app', 'build.gradle.kts');
    return File(kts).existsSync()
        ? kts
        : p.join(projectRoot, 'android', 'app', 'build.gradle');
  }

  /// Returns the directory path where iOS xcconfig files are located (ios/Flutter/).
  static String iosXcconfigDir(String projectRoot) =>
      p.join(projectRoot, 'ios', 'Flutter');

  /// Returns the path to the iOS project.pbxproj file.
  static String iosPbxprojPath(String projectRoot) =>
      p.join(projectRoot, 'ios', 'Runner.xcodeproj', 'project.pbxproj');

  /// Returns the directory path where iOS xcscheme files are located.
  static String iosSchemesDir(String projectRoot) => p.join(
        projectRoot,
        'ios',
        'Runner.xcodeproj',
        'xcshareddata',
        'xcschemes',
      );

  /// Returns the path to the iOS Info.plist file.
  static String iosInfoPlistPath(String projectRoot) =>
      p.join(projectRoot, 'ios', 'Runner', 'Info.plist');

  /// Returns the path to the main AndroidManifest.xml.
  static String androidManifestPath(String projectRoot) => p.join(
      projectRoot, 'android', 'app', 'src', 'main', 'AndroidManifest.xml');

  /// Returns the path to the iOS Podfile.
  static String iosPodfilePath(String projectRoot) =>
      p.join(projectRoot, 'ios', 'Podfile');

  /// Returns the path to the iOS Assets.xcassets directory.
  static String iosAssetCatalogDir(String projectRoot) =>
      p.join(projectRoot, 'ios', 'Runner', 'Assets.xcassets');
}
