import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../config/store_info_config.dart';
import '../appstore/asc_api_client.dart';
import '../appstore/asc_api_key_file.dart';
import '../appstore/asc_jwt.dart';
import '../deploy/play_json_key.dart';
import '../doctor/checks/android_deploy_checks.dart';
import '../doctor/checks/ios_deploy_checks.dart';
import '../exceptions.dart';
import '../utils/idempotent_writer.dart';
import 'setup_step.dart';

/// Store listing management without the web UIs: reads
/// `easy_setup_store_info.yaml`, generates both fastlane metadata trees
/// from the one source, and uploads them (iOS: `deliver
/// --skip_binary_upload`, Android: `supply` metadata-only).
///
/// Review submission is NOT part of this step — that is
/// `easy_setup deploy --submit`, because a submission needs a build.
class StoreStep extends SetupStep {
  /// iOS deliver filenames per locale, in StoreLocaleInfo field order.
  static const iosFileNames = {
    'name': 'name.txt',
    'subtitle': 'subtitle.txt',
    'description': 'description.txt',
    'keywords': 'keywords.txt',
    'promotional_text': 'promotional_text.txt',
    'release_notes': 'release_notes.txt',
    'support_url': 'support_url.txt',
    'marketing_url': 'marketing_url.txt',
    'privacy_url': 'privacy_url.txt',
  };

  @override
  String get name => 'store';

  @override
  bool isConfigured(ProjectConfig config) => true;

  @override
  bool isActive(SetupContext context) => File(
          p.join(context.projectRoot, StoreInfoConfig.fileName))
      .existsSync();

  @override
  String get configurationHint =>
      '${StoreInfoConfig.fileName} next to easy_setup.yaml';

  @override
  Future<void> run(SetupContext context) async {
    final info = StoreInfoConfig.fromFile(
        p.join(context.projectRoot, StoreInfoConfig.fileName));

    final changed = _generate(context, info);
    if (!context.dryRun) {
      context.out.writeln(changed > 0
          ? '  ✓ fastlane metadata generated ($changed file(s) updated)'
          : '  ✓ fastlane metadata up to date');
    }

    await _uploadIos(context, info);
    await _uploadAndroid(context);

    // The App Privacy questionnaire has no official ASC API, and
    // fastlane's upload_app_privacy_details_to_app_store action needs an
    // Apple ID session (2FA) — rejected for the same reason as `produce`.
    // One manual web step, clearly named.
    context.out.writeln(
        '  ! App Privacy (data collection) labels: no official ASC API '
        '(the fastlane action needs an Apple ID session) — fill them once '
        'at App Store Connect > your app > App Privacy.');
  }

  /// `age_rating_override_v2` → `ageRatingOverrideV2` etc.
  static String _snakeToCamel(String snake) {
    final parts = snake.split('_');
    return parts.first +
        parts
            .skip(1)
            .map((part) => part.isEmpty
                ? ''
                : part[0].toUpperCase() + part.substring(1))
            .join();
  }

  // --- Generation ----------------------------------------------------------

  int _generate(SetupContext context, StoreInfoConfig info) {
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would generate iOS + Android fastlane metadata for '
          '${info.locales.keys.join(', ')}');
      return 0;
    }
    var changed = 0;
    final metadataRoot = p.join(context.projectRoot, 'fastlane', 'metadata');

    // App-level (non-localized) deliver files.
    for (final (fileName, value) in [
      ('copyright.txt', info.copyright),
      ('primary_category.txt', info.primaryCategory),
      ('secondary_category.txt', info.secondaryCategory),
      for (final key in StoreInfoConfig.reviewInformationKeys)
        (p.join('review_information', '$key.txt'),
            info.reviewInformation[key]),
    ]) {
      final file = File(p.join(metadataRoot, fileName));
      if (value == null) {
        if (file.existsSync()) {
          file.deleteSync();
          changed++;
        }
      } else {
        changed += writeBytesIfChanged(file, utf8.encode('$value\n'));
      }
    }
    // Age rating questionnaire → deliver's app_rating_config_path JSON
    // (camelCase ASC attribute keys).
    final ageRatingFile = File(p.join(metadataRoot, 'age_rating.json'));
    if (info.ageRating.isEmpty) {
      if (ageRatingFile.existsSync()) {
        ageRatingFile.deleteSync();
        changed++;
      }
    } else {
      final camel = info.ageRating.map(
          (key, value) => MapEntry(_snakeToCamel(key), value));
      changed += writeBytesIfChanged(
        ageRatingFile,
        utf8.encode(
            '${const JsonEncoder.withIndent('  ').convert(camel)}\n'),
      );
    }

    if (info.reviewInformation.isEmpty) {
      context.out.writeln(
          "  ! 'review_information' is empty — the very first deliver run "
          'needs it (contact name/phone/email), or it crashes fetching the '
          "app's review detail.");
    } else {
      final phone = info.reviewInformation['phone_number'];
      if (phone == null || !phone.startsWith('+')) {
        // ASC rejects review-detail creation outright without a
        // +<country-code> phone (verified on the dream-diary pilot).
        context.out.writeln(
            "  ! 'review_information.phone_number' "
            '${phone == null ? 'is missing' : 'must start with +<country code>'}'
            ' — App Store Connect rejects the review detail without it '
            "(e.g. '+82 10-1234-5678').");
      }
    }

    info.locales.forEach((locale, texts) {
      // iOS tree — write present fields, prune managed absents.
      for (final field in StoreLocaleInfo.fields) {
        if (!field.ios) continue;
        final file =
            File(p.join(metadataRoot, locale, iosFileNames[field.name]!));
        final value = texts[field.name];
        if (value == null) {
          if (file.existsSync()) {
            file.deleteSync();
            changed++;
          }
        } else {
          changed += writeBytesIfChanged(file, utf8.encode('$value\n'));
        }
      }

      // Android tree.
      final androidDir = p.join(metadataRoot, 'android', locale);
      if (texts['short_description'] == null) {
        context.out.writeln(
            "  ! $locale: 'short_description' missing — Google Play "
            'requires it (80 chars).');
      }
      // Play release notes cap at 500 chars (iOS allows 4000) — skip the
      // android changelog instead of failing or truncating silently.
      var androidReleaseNotes = texts['release_notes'];
      if (androidReleaseNotes != null && androidReleaseNotes.length > 500) {
        context.out.writeln(
            "  ! $locale: 'release_notes' is ${androidReleaseNotes.length} "
            'characters — Google Play caps release notes at 500, so the '
            'Android changelog is not generated. Shorten it to cover both '
            'stores.');
        androidReleaseNotes = null;
      }
      for (final (fileName, value) in [
        ('title.txt', texts['name']),
        ('short_description.txt', texts['short_description']),
        ('full_description.txt', texts['description']),
        (p.join('changelogs', 'default.txt'), androidReleaseNotes),
      ]) {
        final file = File(p.join(androidDir, fileName));
        if (value == null) {
          if (file.existsSync()) {
            file.deleteSync();
            changed++;
          }
        } else {
          changed += writeBytesIfChanged(file, utf8.encode('$value\n'));
        }
      }
    });

    changed += _pruneRemovedLocales(context, metadataRoot, info);
    return changed;
  }

  /// Removes metadata trees of locales no longer in the store info file —
  /// fastlane keeps uploading whatever directories exist. Only directories
  /// containing exclusively managed filenames are deleted; anything else
  /// gets a warning instead.
  int _pruneRemovedLocales(
      SetupContext context, String metadataRoot, StoreInfoConfig info) {
    var changed = 0;
    final managedIos = iosFileNames.values.toSet();
    const managedAndroid = {
      'title.txt',
      'short_description.txt',
      'full_description.txt',
      'changelogs',
    };
    for (final (parent, managed, isAndroidTree) in [
      (metadataRoot, managedIos, false),
      (p.join(metadataRoot, 'android'), managedAndroid, true),
    ]) {
      final dir = Directory(parent);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync().whereType<Directory>()) {
        final name = p.basename(entity.path);
        if (!isAndroidTree &&
            (name == 'android' || name == 'review_information')) {
          continue;
        }
        if (info.locales.containsKey(name)) continue;
        final foreign = entity
            .listSync()
            .map((e) => p.basename(e.path))
            .where((n) => !managed.contains(n) && !n.startsWith('.'))
            .toList();
        if (foreign.isNotEmpty) {
          context.out.writeln(
              '  ! ${entity.path} is not in ${StoreInfoConfig.fileName} but '
              'contains unmanaged files (${foreign.join(', ')}) — remove it '
              'manually if the locale is gone.');
          continue;
        }
        entity.deleteSync(recursive: true);
        context.out
            .writeln('  ✓ Removed stale locale metadata: ${entity.path}');
        changed++;
      }
    }
    return changed;
  }

  // --- Upload --------------------------------------------------------------

  Future<void> _uploadIos(SetupContext context, StoreInfoConfig info) async {
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would upload metadata via fastlane deliver '
          '(--skip_binary_upload)');
      return;
    }
    if (!AscEnv.isComplete(context.env)) {
      context.out.writeln(
          '  ! ASC API key env not set — generated the metadata but '
          'skipped the App Store upload. Set ASC_KEY_ID / ASC_ISSUER_ID / '
          'ASC_KEY_P8[_PATH] and re-run.');
      return;
    }

    final screenshotsDir =
        Directory(p.join(context.projectRoot, 'fastlane', 'screenshots'));
    final workDir = Directory.systemTemp.createTempSync('easy_setup_store');
    try {
      final apiKeyPath = writeAscApiKeyJson(workDir, context.env);
      context.out.writeln('  → fastlane deliver (metadata'
          '${screenshotsDir.existsSync() ? ' + screenshots' : ''})');
      final exitCode = await context.processes.stream(
        'fastlane',
        [
          'deliver',
          '--skip_binary_upload', 'true',
          '--force', 'true',
          '--run_precheck_before_submit', 'false',
          '--api_key_path', apiKeyPath,
          '--app_identifier', context.config.app.bundleId,
          '--metadata_path', 'fastlane/metadata',
          if (File(p.join(context.projectRoot, 'fastlane', 'metadata',
                  'age_rating.json'))
              .existsSync()) ...[
            '--app_rating_config_path', 'fastlane/metadata/age_rating.json',
          ],
          if (screenshotsDir.existsSync()) ...[
            '--screenshots_path', 'fastlane/screenshots',
            // Mirror local pruning remotely — otherwise screenshots removed
            // locally stay live in App Store Connect.
            '--overwrite_screenshots', 'true',
          ] else ...[
            '--skip_screenshots', 'true',
          ],
        ],
        workingDirectory: context.projectRoot,
      );
      if (exitCode != 0) {
        throw SetupException('fastlane deliver failed (exit code $exitCode).');
      }
      context.out.writeln('  ✓ App Store listing updated');
      if (screenshotsDir.existsSync()) {
        await _reconcileScreenshots(context, screenshotsDir);
      }
    } finally {
      workDir.deleteSync(recursive: true);
    }
  }

  /// Checks what actually landed on App Store Connect, and removes the
  /// copies deliver left behind.
  ///
  /// deliver verifies its own upload by matching local files to remote
  /// ones on source checksum. When App Store Connect returns no checksum —
  /// which it routinely does — every file looks missing, so deliver
  /// retries; and the retry only deletes screenshots that did *not*
  /// complete, so everything that uploaded fine is uploaded again. Its
  /// second pass then reports success, because the check stops flagging a
  /// set once it holds ten screenshots. The listing ends up with every
  /// screenshot twice and nothing says so.
  Future<void> _reconcileScreenshots(
      SetupContext context, Directory screenshotsDir) async {
    final privateKey = AscEnv.resolveKey(context.env);
    if (privateKey == null) return; // deliver could not have run either.
    final client = AscApiClient(
      http: context.http,
      token: AscJwt.generate(
        keyId: context.env[AscEnv.keyId]!,
        issuerId: context.env[AscEnv.issuerId]!,
        privateKeyPem: privateKey,
      ),
    );

    // Only what this project just uploaded is in scope. A locale or a file
    // that is not on disk may be managed by hand, and deleting it is not
    // this step's business.
    final local = _localScreenshots(screenshotsDir);

    final List<AscScreenshotSet> sets;
    try {
      final appId = await client.findApp(context.config.app.bundleId);
      if (appId == null) return;
      final versionId = await client.editableVersion(appId);
      if (versionId == null) {
        context.out.writeln(
            '  ! Could not identify a single version open for editing, so '
            'the upload was left exactly as deliver made it.');
        return;
      }
      sets = await client.screenshotSets(versionId);
    } on SetupException catch (e) {
      context.out.writeln(
          '  ! Could not read back the uploaded screenshots, so duplicates '
          'were not checked: ${e.message}');
      return;
    }

    var removed = 0;
    for (final set in sets) {
      final localNames = local[set.locale];
      if (localNames == null) continue;
      final seen = <String>{};
      for (final screenshot in set.screenshots) {
        if (!localNames.contains(screenshot.fileName)) continue;
        if (seen.add(screenshot.fileName)) continue;
        try {
          await client.deleteScreenshot(screenshot.id);
        } on SetupException catch (e) {
          // deliver has already succeeded; a half-finished cleanup is
          // worth reporting, not worth failing the whole step over.
          context.out.writeln(
              '  ! Removed $removed duplicate(s), then could not remove '
              '${screenshot.fileName}: ${e.message}');
          return;
        }
        removed++;
      }
    }
    if (removed > 0) {
      context.out.writeln(
          '  ✓ Removed $removed duplicate screenshot(s) that deliver '
          're-uploaded');
    }

    _reportMissingScreenshots(context, local, sets, removed);
  }

  /// locale → the screenshot file names this project just uploaded.
  Map<String, Set<String>> _localScreenshots(Directory screenshotsDir) {
    final local = <String, Set<String>>{};
    for (final localeDir in screenshotsDir.listSync().whereType<Directory>()) {
      local[p.basename(localeDir.path)] = {
        for (final file in localeDir.listSync().whereType<File>())
          if (file.path.endsWith('.png')) p.basename(file.path),
      };
    }
    return local;
  }

  /// Names a local screenshot App Store Connect did not keep.
  ///
  /// deliver logs "Uploaded ..." for a file whose display type the store
  /// then rejects, so a silently absent device size looks like a success.
  void _reportMissingScreenshots(SetupContext context,
      Map<String, Set<String>> local, List<AscScreenshotSet> sets, int removed) {
    final remote = <String, Set<String>>{};
    for (final set in sets) {
      remote
          .putIfAbsent(set.locale, () => <String>{})
          .addAll(set.screenshots.map((shot) => shot.fileName));
    }
    final missing = <String>[
      for (final entry in local.entries)
        for (final name in entry.value)
          if (!(remote[entry.key]?.contains(name) ?? false))
            '${entry.key}/$name',
    ]..sort();
    if (missing.isEmpty) {
      if (removed == 0) {
        context.out.writeln('  ✓ Screenshots on App Store Connect match '
            'fastlane/screenshots');
      }
      return;
    }
    context.out.writeln(
        '  ! App Store Connect did not keep ${missing.join(', ')} — the '
        'store rejects a screenshot whose pixel size does not match a '
        'display type it accepts for this app. Check the size against '
        "Apple's specification for that device.");
  }

  Future<void> _uploadAndroid(SetupContext context) async {
    if (context.config.android == null) return;
    if (context.dryRun) {
      context.out.writeln(
          '  [dry-run] Would upload the Play listing via fastlane supply '
          '(metadata-only)');
      return;
    }
    final playKey = context.env[PlayServiceAccountCheck.envName];
    if (playKey == null || playKey.trim().isEmpty) {
      context.out.writeln(
          '  ! PLAY_SERVICE_ACCOUNT_JSON not set — generated the Play '
          'metadata but skipped the upload.');
      return;
    }

    final workDir = Directory.systemTemp.createTempSync('easy_setup_store');
    try {
      final jsonKeyPath = resolvePlayJsonKey(workDir, context.env);
      context.out.writeln('  → fastlane supply (Play listing)');
      final exitCode = await context.processes.stream(
        'fastlane',
        [
          'supply',
          '--skip_upload_aab', 'true',
          '--skip_upload_apk', 'true',
          '--skip_upload_metadata', 'false',
          '--skip_upload_changelogs', 'false',
          '--skip_upload_images', 'false',
          '--skip_upload_screenshots', 'false',
          '--package_name', context.config.app.packageName,
          '--track', context.config.android!.playTrackDefault,
          '--json_key', jsonKeyPath,
        ],
        workingDirectory: context.projectRoot,
      );
      if (exitCode != 0) {
        throw SetupException('fastlane supply failed (exit code $exitCode).');
      }
      context.out.writeln('  ✓ Play listing updated');
    } finally {
      workDir.deleteSync(recursive: true);
    }
  }
}
