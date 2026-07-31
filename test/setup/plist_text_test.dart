import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';

const _plist = '''
<plist version="1.0">
<dict>
	<key>Modes</key>
	<array>
		<string>audio</string>
	</array>
	<key>Other</key>
	<array>
		<string>fetch</string>
	</array>
	<key>Name</key>
	<string>app</string>
</dict>
</plist>
''';

void main() {
  group('PlistText.arrayContent', () {
    test('returns only the content of the key own array', () {
      final content = PlistText.arrayContent(_plist, 'Modes')!;
      expect(content, contains('audio'));
      expect(content, isNot(contains('fetch')));
    });

    test('returns null for a missing key and empty for <array/>', () {
      expect(PlistText.arrayContent(_plist, 'Nope'), isNull);
      const empty = '<dict>\n\t<key>Empty</key>\n\t<array/>\n</dict>';
      expect(PlistText.arrayContent(empty, 'Empty'), '');
    });

    test('throws when the key value is not an array', () {
      expect(
        () => PlistText.arrayContent(_plist, 'Name'),
        throwsA(isA<SetupException>()
            .having((e) => e.message, 'message', contains('not an <array>'))),
      );
    });
  });

  group('PlistText.appendToArray', () {
    test('appends into the key own array, not a later one', () {
      final updated = PlistText.appendToArray(
          _plist, 'Modes', '\t\t<string>voip</string>\n');
      expect(PlistText.arrayContent(updated, 'Modes'), contains('voip'));
      expect(PlistText.arrayContent(updated, 'Other'),
          isNot(contains('voip')));
    });

    test('expands the self-closing <array/> form', () {
      const empty = '<dict>\n\t<key>Empty</key>\n\t<array/>\n</dict>';
      final updated = PlistText.appendToArray(
          empty, 'Empty', '\t\t<string>x</string>\n');
      expect(PlistText.arrayContent(updated, 'Empty'), contains('x'));
    });

    test('throws when the value is not an array instead of corrupting',
        () {
      expect(
        () => PlistText.appendToArray(
            _plist, 'Name', '\t\t<string>x</string>\n'),
        throwsA(isA<SetupException>()),
      );
    });
  });
}
