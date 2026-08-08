import 'dart:io';
import 'dart:typed_data';

import 'package:easy_setup/easy_setup.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A renderer that finds no browser, so the missing-Chrome path can be
/// exercised on machines that do have one installed.
class _BrowserlessRenderer extends ChromeRenderer {
  @override
  Future<String?> findExecutable() async => null;
}

void main() {
  late Directory tempDir;

  setUp(() =>
      tempDir = Directory.systemTemp.createTempSync('html_renderer_test'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  group('ChromeRenderer.findExecutable', () {
    test('CHROME_PATH wins over the bundled candidates', () async {
      final fake = File(p.join(tempDir.path, 'my-browser'))
        ..writeAsStringSync('');
      final renderer = ChromeRenderer(
          env: {ChromeRenderer.executableEnvVar: fake.path});
      expect(await renderer.findExecutable(), fake.path);
    });

    test('CHROME_PATH pointing nowhere fails loudly', () {
      final renderer = ChromeRenderer(
          env: {ChromeRenderer.executableEnvVar: '/nope/chrome'});
      expect(
        renderer.findExecutable,
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('/nope/chrome'))),
      );
    });

    test('rendering without a browser explains how to install one', () {
      expect(
        () => _BrowserlessRenderer()
            .render(html: '<p>hi</p>', width: 10, height: 10),
        throwsA(isA<SetupException>().having((e) => e.message, 'message',
            allOf(contains('No Chrome/Chromium found'),
                contains(ChromeRenderer.executableEnvVar)))),
      );
    });
  });

  group('ChromeRenderer.isCompletePng', () {
    Uint8List png() => Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 2, numChannels: 3)));

    test('accepts a PNG terminated by IEND', () {
      expect(ChromeRenderer.isCompletePng(png()), isTrue);
    });

    test('rejects a half-written capture', () {
      final bytes = png();
      expect(ChromeRenderer.isCompletePng(bytes.sublist(0, bytes.length - 4)),
          isFalse);
      expect(ChromeRenderer.isCompletePng(Uint8List(0)), isFalse);
      // Right length, wrong signature.
      expect(ChromeRenderer.isCompletePng(Uint8List(bytes.length)), isFalse);
    });
  });

  group('fillTemplate', () {
    test('replaces known placeholders and leaves the rest alone', () {
      const template = '<p>{{TITLE}} / {{C_BG}} / {{MISSING}} / {{lower}}</p>';
      final filled =
          fillTemplate(template, {'TITLE': 'Hi', 'C_BG': '#fff'});
      expect(filled, contains('Hi / #fff / {{MISSING}}'));
      // Lowercase tokens are not placeholders at all.
      expect(filled, contains('{{lower}}'));
      expect(placeholderNames(template), ['C_BG', 'MISSING', 'TITLE']);
    });

    test('a substituted value is never rescanned', () {
      // Copy that happens to look like a placeholder stays literal.
      expect(fillTemplate('{{A}}|{{B}}', {'A': '{{B}}', 'B': 'x'}),
          '{{B}}|x');
    });
  });

  group('contentHash', () {
    test('is stable and sensitive to every chunk', () {
      expect(contentHash(['a', 'b']), contentHash(['a', 'b']));
      expect(contentHash(['a', 'b']), isNot(contentHash(['a', 'c'])));
      // Length-delimited: the split between chunks matters.
      expect(contentHash(['ab', 'c']), isNot(contentHash(['a', 'bc'])));
      expect(contentHash([
        Uint8List.fromList([1, 2])
      ]), hasLength(16));
    });
  });
}
