import 'dart:io';

import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('firebase_configurator_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('FirebaseConfigurator', () {
    test('prints dry-run message without running flutterfire', () async {
      await FirebaseConfigurator.configure(
        tempDir.path,
        'dev',
        'my-firebase-project',
        'com.example.app.dev',
        dryRun: true,
      );

      // dry-run should not create any output files
      final androidOut = File(
        '${tempDir.path}/android/app/src/dev/google-services.json',
      );
      final iosOut = File(
        '${tempDir.path}/ios/Runner/Firebase/dev/GoogleService-Info.plist',
      );
      expect(androidOut.existsSync(), isFalse);
      expect(iosOut.existsSync(), isFalse);
    });

  });
}
