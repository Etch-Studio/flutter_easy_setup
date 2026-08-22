import 'package:easy_setup/easy_setup.dart';
import 'package:test/test.dart';

void main() {
  group('YamlBlockText', () {
    const yaml = '''
app:
  name: X

admob:
  ad_units:
    banner_main:
      type: banner

branding:
  icon_src: assets/branding/icon/
''';

    test('inserts at the end of the block it belongs to', () {
      final updated = YamlBlockText.insert(yaml, const ['admob', 'ad_units'], [
        ['rewarded_hint:', '  type: rewarded'],
      ]);
      expect(updated, contains('''
    banner_main:
      type: banner
    rewarded_hint:
      type: rewarded
'''));
      // Untouched around it.
      expect(updated, contains('branding:'));
      expect(updated, contains('  name: X'));
    });

    test('creates ad_units when the section has none', () {
      final updated = YamlBlockText.insert('''
admob:
  auto: true
''', const ['admob', 'ad_units'], [
        ['banner_main:', '  type: banner'],
      ]);
      expect(updated, '''
admob:
  auto: true
  ad_units:
    banner_main:
      type: banner
''');
    });

    test('an empty inline block becomes a real one', () {
      final updated = YamlBlockText.insert('''
admob:
  ad_units: {}
''', const ['admob', 'ad_units'], [
        ['banner_main:'],
      ]);
      expect(updated, '''
admob:
  ad_units:
    banner_main:
''');
    });

    test('follows the indentation the file already uses', () {
      final updated = YamlBlockText.insert('''
admob:
    ad_units:
        banner_main:
            type: banner
''', const ['admob', 'ad_units'], [
        ['rewarded_hint:', '  type: rewarded'],
      ]);
      expect(updated, contains('''
        rewarded_hint:
          type: rewarded
'''));
    });

    test('a flow-style block is refused, never rewritten', () {
      // Not line-addressable: the caller prints the block to paste instead.
      expect(
        YamlBlockText.insert(
          'admob: { ad_units: { banner_main: {} } }\n',
          const ['admob', 'ad_units'],
          [
            ['rewarded_hint:'],
          ],
        ),
        isNull,
      );
    });

    test('a missing parent section is refused', () {
      expect(
        YamlBlockText.insert(
          'app:\n  name: X\n',
          const ['admob', 'ad_units'],
          [
            ['banner_main:'],
          ],
        ),
        isNull,
      );
    });

    test('a key that only shares a prefix is not the block', () {
      final updated = YamlBlockText.insert('''
admob_legacy:
  ad_units:
    old_banner:
admob:
  ad_units:
    banner_main:
''', const ['admob', 'ad_units'], [
        ['rewarded_hint:'],
      ]);
      expect(updated, contains('''
admob:
  ad_units:
    banner_main:
    rewarded_hint:
'''));
      expect(updated, isNot(contains('''
    old_banner:
    rewarded_hint:
''')));
    });

    test('trailing blank lines stay at the end', () {
      final updated = YamlBlockText.insert('''
admob:
  ad_units:
    banner_main:

''', const ['admob', 'ad_units'], [
        ['rewarded_hint:'],
      ]);
      expect(updated, '''
admob:
  ad_units:
    banner_main:
    rewarded_hint:

''');
    });

    test('an inline empty parent becomes a real block first', () {
      // Inserting under a line that still says `{}` would leave a file that
      // no longer parses.
      final updated = YamlBlockText.insert('''
app:
  name: X
admob: {}
''', const ['admob', 'ad_units'], [
        ['banner_main:', '  type: banner'],
      ]);
      expect(updated, '''
app:
  name: X
admob:
  ad_units:
    banner_main:
      type: banner
''');
    });

    test('a CRLF file stays a CRLF file', () {
      final updated = YamlBlockText.insert(
        'admob:\r\n  ad_units:\r\n    banner_main:\r\n',
        const ['admob', 'ad_units'],
        [
          ['rewarded_hint:'],
        ],
      );
      expect(updated,
          'admob:\r\n  ad_units:\r\n    banner_main:\r\n    rewarded_hint:\r\n');
    });

    test('a created block matches the width the file already uses', () {
      // Four-space document: the new block's children are eight, not six.
      final updated = YamlBlockText.insert('''
admob:
    auto: true
''', const ['admob', 'ad_units'], [
        ['banner_main:', '  type: banner'],
      ]);
      expect(updated, '''
admob:
    auto: true
    ad_units:
        banner_main:
          type: banner
''');
    });

    test('a file with no trailing newline keeps not having one', () {
      final updated = YamlBlockText.insert(
        'admob:\n  ad_units:\n    banner_main:',
        const ['admob', 'ad_units'],
        [
          ['rewarded_hint:'],
        ],
      );
      expect(updated, 'admob:\n  ad_units:\n    banner_main:\n'
          '    rewarded_hint:');
    });

    test('comments inside the block are left where they are', () {
      final updated = YamlBlockText.insert('''
admob:
  # the banner at the bottom of the night screen
  ad_units:
    banner_main:
      # resolved per run
      type: banner
''', const ['admob', 'ad_units'], [
        ['rewarded_hint:'],
      ]);
      expect(updated, '''
admob:
  # the banner at the bottom of the night screen
  ad_units:
    banner_main:
      # resolved per run
      type: banner
    rewarded_hint:
''');
    });

    test('scalars are quoted only when a plain one would not survive', () {
      expect(YamlBlockText.scalar('Banner (main)'), 'Banner (main)');
      expect(YamlBlockText.scalar('banner_main'), 'banner_main');
      // `#` starts a comment, `:` ends a key — both change what parses back.
      expect(YamlBlockText.scalar('Banner #1'), "'Banner #1'");
      expect(YamlBlockText.scalar('Banner: main'), "'Banner: main'");
      expect(YamlBlockText.scalar('배너'), "'배너'");
      expect(YamlBlockText.scalar("Rob's banner"), "'Rob''s banner'");
      expect(YamlBlockText.scalar('trailing '), "'trailing '");
    });

    test('nothing to insert changes nothing', () {
      expect(YamlBlockText.insert(yaml, const ['admob', 'ad_units'], []), yaml);
    });
  });
}
