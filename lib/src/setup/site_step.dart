import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/project_config.dart';
import '../config/store_info_config.dart';
import '../utils/idempotent_writer.dart';
import '../utils/project_finder.dart';
import 'site_templates.dart';
import 'setup_step.dart';

/// Generates the promo/support/privacy site every store listing requires
/// (support URL is mandatory, marketing and privacy URLs nearly so).
///
/// Two layers, like the screenshot pipeline:
/// ① this step writes a working, deployable draft plus `SITE_BRIEF.md`
///    (the app's facts in one place) and installs a Claude Code skill;
/// ② the AI — or you — restyles it. Pages are only ever created, never
///    overwritten, so hand edits and AI redesigns survive re-runs.
///
/// Publishing is a GitHub Actions Pages workflow at the repo root; the
/// resulting URLs are written back into easy_setup_store_info.yaml.
class SiteStep extends SetupStep {
  static const siteDirName = 'site';
  static const briefFileName = 'SITE_BRIEF.md';
  static const skillRelativePath = '.claude/skills/app-site/SKILL.md';
  static const workflowRelativePath = '.github/workflows/pages.yml';

  @override
  String get name => 'site';

  @override
  bool isConfigured(ProjectConfig config) => config.site != null;

  @override
  String get configurationHint => "a 'site' section in easy_setup.yaml";

  @override
  Future<void> run(SetupContext context) async {
    final site = context.config.site!;
    final siteDir = p.join(context.projectRoot, siteDirName);
    final storeInfoPath =
        p.join(context.projectRoot, StoreInfoConfig.fileName);
    final storeInfo = File(storeInfoPath).existsSync()
        ? StoreInfoConfig.fromFile(storeInfoPath)
        : null;

    final locale = site.locale ?? storeInfo?.locales.keys.firstOrNull ?? 'en';
    final texts = storeInfo?.locales[locale];
    final appName = texts?['name'] ?? context.config.app.name;
    final tagline = site.tagline ??
        texts?['subtitle'] ??
        texts?['short_description'] ??
        '';
    final description = texts?['description'] ?? '';
    final email = site.contactEmail ??
        storeInfo?.reviewInformation['email_address'] ??
        'TODO@example.com';

    if (context.dryRun) {
      context.out
        ..writeln('  [dry-run] Would create $siteDirName/ '
            '(index/support/privacy + style.css + $briefFileName)')
        ..writeln('  [dry-run] Would install the app-site Claude skill and '
            'the Pages workflow, then write the URLs into '
            '${StoreInfoConfig.fileName}');
      return;
    }

    var changed = 0;
    changed += _writeIfAbsent(context, p.join(siteDir, 'style.css'),
        SiteTemplates.stylesheet());
    changed += _writeIfAbsent(
      context,
      p.join(siteDir, 'index.html'),
      SiteTemplates.index(
        appName: appName,
        tagline: tagline,
        description: description,
        features: site.features,
        contactEmail: email,
        locale: locale,
        appStoreUrl: site.appStoreUrl,
        playStoreUrl: site.playStoreUrl,
      ),
    );
    changed += _writeIfAbsent(
      context,
      p.join(siteDir, 'support.html'),
      SiteTemplates.support(
          appName: appName, contactEmail: email, locale: locale),
    );
    changed += _writeIfAbsent(
      context,
      p.join(siteDir, 'privacy.html'),
      SiteTemplates.privacy(
        appName: appName,
        contactEmail: email,
        locale: locale,
        effectiveDate: site.privacyEffectiveDate ?? 'TODO',
      ),
    );
    _copyIcon(context, siteDir);

    // The brief is regenerated every run — it is derived data the AI reads.
    changed += writeBytesIfChanged(
      File(p.join(siteDir, briefFileName)),
      utf8.encode(_brief(context, site, storeInfo, appName, tagline, email)),
    );

    changed += _installSkill(context);
    changed += _installWorkflow(context);

    context.out.writeln(changed > 0
        ? '  ✓ site/ ready ($changed file(s) written)'
        : '  ✓ site/ up to date');

    final baseUrl = _resolveBaseUrl(context, site);
    if (baseUrl == null) {
      context.out.writeln(
          '  ! Could not derive the Pages URL — set site.base_url in '
          'easy_setup.yaml to write the store URLs automatically.');
    } else {
      _writeStoreUrls(context, storeInfoPath, storeInfo, baseUrl);
    }

    context.out.writeln(
        '  → Enable Pages once: repo Settings > Pages > Source: '
        'GitHub Actions. Then ask Claude: "/app-site" to restyle it.');
  }

  // --- File helpers --------------------------------------------------------

  /// Writes [content] only when the file does not exist — a hand-edited or
  /// AI-redesigned page is never clobbered.
  int _writeIfAbsent(SetupContext context, String path, String content) {
    final file = File(path);
    if (file.existsSync()) return 0;
    file.createSync(recursive: true);
    file.writeAsStringSync(content);
    return 1;
  }

  void _copyIcon(SetupContext context, String siteDir) {
    final target = File(p.join(siteDir, 'icon.png'));
    if (target.existsSync()) return;
    // Prefer the branding source, fall back to the generated iOS icon.
    final candidates = [
      if (context.config.branding != null)
        p.join(context.projectRoot, context.config.branding!.iconSrc,
            'icon.png'),
      p.join(ProjectFinder.iosAssetCatalogDir(context.projectRoot),
          'AppIcon.appiconset', 'Icon-App-1024x1024@1x.png'),
    ];
    for (final candidate in candidates) {
      final source = File(candidate);
      if (!source.existsSync()) continue;
      target.createSync(recursive: true);
      source.copySync(target.path);
      return;
    }
    context.out.writeln(
        '  ! No app icon found — put one at $siteDirName/icon.png '
        '(run the branding step first, or copy it manually).');
  }

  int _installSkill(SetupContext context) {
    final gitRoot =
        ProjectFinder.findGitRoot(context.projectRoot) ?? context.projectRoot;
    return _writeIfAbsent(context, p.join(gitRoot, skillRelativePath),
        _skillDefinition(p.relative(context.projectRoot, from: gitRoot)));
  }

  int _installWorkflow(SetupContext context) {
    final gitRoot =
        ProjectFinder.findGitRoot(context.projectRoot) ?? context.projectRoot;
    final relativeSiteDir = p.join(
        p.relative(context.projectRoot, from: gitRoot), siteDirName);
    return _writeIfAbsent(
      context,
      p.join(gitRoot, workflowRelativePath),
      SiteTemplates.pagesWorkflow(
          relativeSiteDir.startsWith('./')
              ? relativeSiteDir.substring(2)
              : relativeSiteDir),
    );
  }

  // --- Generated content ---------------------------------------------------

  String _brief(
    SetupContext context,
    SiteConfig site,
    StoreInfoConfig? storeInfo,
    String appName,
    String tagline,
    String email,
  ) {
    final buffer = StringBuffer('''
# Site brief — $appName

Generated by `easy_setup setup --only site`. This file is derived from
easy_setup.yaml and ${StoreInfoConfig.fileName}; edit those, not this.

## App

- Name: $appName
- Bundle ID: ${context.config.app.bundleId}
- Tagline: ${tagline.isEmpty ? '(none — set site.tagline)' : tagline}
- Contact: $email
''');
    if (site.appStoreUrl != null) {
      buffer.writeln('- App Store: ${site.appStoreUrl}');
    }
    if (site.playStoreUrl != null) {
      buffer.writeln('- Google Play: ${site.playStoreUrl}');
    }
    if (site.features.isNotEmpty) {
      buffer
        ..writeln('\n## Features')
        ..writeln();
      for (final feature in site.features) {
        buffer.writeln('- $feature');
      }
    }
    if (site.mood != null) {
      buffer.writeln('\n## Desired mood\n\n${site.mood}');
    }
    final description = storeInfo?.locales.values.firstOrNull?['description'];
    if (description != null) {
      buffer.writeln('\n## Store description\n\n$description');
    }
    final sdks = [
      if (context.config.sentry != null) 'Sentry (crash reporting)',
      if (context.config.firebase != null) 'Firebase Analytics',
      if (context.config.admob != null) 'Google AdMob (ads)',
    ];
    buffer.writeln('''

## Data collection (for the privacy page)

${sdks.isEmpty ? 'No third-party SDKs are configured in easy_setup.yaml — verify against the app code.' : sdks.map((s) => '- $s').join('\n')}

Keep privacy.html consistent with the App Privacy answers in App Store
Connect and the Play Data safety form.
''');
    return buffer.toString();
  }

  String _skillDefinition(String projectRoot) => '''
---
name: app-site
description: Design and refine the app's promo site (site/index.html,
  support.html, privacy.html). Use when asked to build, restyle, or
  update the marketing/support/privacy pages.
---

# App promo site

The site lives in `${projectRoot == '.' ? siteDirName : p.join(projectRoot, siteDirName)}/`
and is published to GitHub Pages by `.github/workflows/pages.yml`.

## Before editing

1. Read `$siteDirName/$briefFileName` — app name, tagline, features,
   configured SDKs. It is regenerated by
   `easy_setup setup --only site`; never edit it by hand.
2. Read the existing pages. They are a plain starting point, meant to be
   replaced with something that matches the app's character.

## Rules

- **Static only.** No build step, no framework, no bundler. Plain HTML +
  one stylesheet is the whole contract — GitHub Pages serves the folder
  as-is.
- **Restyle in `style.css` first.** Every color/shape knob is a CSS
  custom property at the top; a redesign should rarely need HTML surgery.
- **Keep the three pages and their filenames.** `support.html` and
  `privacy.html` URLs are registered in the App Store / Play listings —
  renaming them breaks live store links.
- **Keep it self-contained.** Fonts via CDN links are fine; no analytics,
  no trackers, nothing that would change the privacy answers.
- **Match the app.** Pull the palette and mood from the app icon and the
  brief. A generic template page is the failure mode to avoid.
- **The privacy page is legal text.** Fill the TODOs from what the app
  actually collects (see the brief's SDK list) and keep it consistent
  with the store privacy labels. Never invent claims.

## After editing

Open the pages locally to check them, e.g.
`open $siteDirName/index.html`, and verify the header nav links still
work on all three.
''';

  // --- Store URL wiring ----------------------------------------------------

  String? _resolveBaseUrl(SetupContext context, SiteConfig site) {
    if (site.baseUrl != null) {
      return site.baseUrl!.endsWith('/')
          ? site.baseUrl!.substring(0, site.baseUrl!.length - 1)
          : site.baseUrl;
    }
    // Derive the default Pages URL from the git remote.
    final gitRoot = ProjectFinder.findGitRoot(context.projectRoot);
    if (gitRoot == null) return null;
    final config = File(p.join(gitRoot, '.git', 'config'));
    if (!config.existsSync()) return null;
    // Repo names may contain dots (my.app) — capture to end-of-token and
    // strip only a trailing `.git`.
    final match = RegExp(r'github\.com[:/]([^/\s]+)/(\S+?)(?:\.git)?\s')
        .firstMatch('${config.readAsStringSync()}\n');
    if (match == null) return null;
    final owner = match.group(1)!;
    final repo = match.group(2)!;
    // `owner.github.io` is a user/org Pages repo served at the root.
    return repo.toLowerCase() == '${owner.toLowerCase()}.github.io'
        ? 'https://$repo'
        : 'https://$owner.github.io/$repo';
  }

  /// Adds the generated URLs to every store locale, preserving existing
  /// values — the user's own URLs always win. Missing URLs in any locale
  /// would leave an incomplete listing, so all of them are filled.
  void _writeStoreUrls(SetupContext context, String storeInfoPath,
      StoreInfoConfig? storeInfo, String baseUrl) {
    context.out.writeln('  ✓ Site URL: $baseUrl/');
    if (storeInfo == null) {
      context.out.writeln(
          '  ! ${StoreInfoConfig.fileName} not found — add support_url: '
          '$baseUrl/support.html to it when you create it.');
      return;
    }
    final wanted = {
      'support_url': '$baseUrl/support.html',
      'marketing_url': '$baseUrl/',
      'privacy_url': '$baseUrl/privacy.html',
    };

    final file = File(storeInfoPath);
    var lines = file.readAsLinesSync();
    final written = <String>[];
    final manual = <String>[];

    for (final locale in storeInfo.locales.keys) {
      final existing = storeInfo.locales[locale];
      final missing = wanted.entries
          .where((entry) => existing?[entry.key] == null)
          .toList();
      if (missing.isEmpty) continue;

      final localeIndex = _localeLineIndex(lines, locale);
      if (localeIndex < 0) {
        // Inline/flow YAML is not line-addressable — never rewrite blindly.
        manual.add('    $locale:\n'
            '${missing.map((e) => '      ${e.key}: ${e.value}').join('\n')}');
        continue;
      }
      // Insert at the end of that locale's block.
      var insertAt = lines.length;
      for (var i = localeIndex + 1; i < lines.length; i++) {
        final line = lines[i];
        if (line.trim().isEmpty) continue;
        if (!line.startsWith('    ')) {
          insertAt = i;
          break;
        }
      }
      lines = [...lines]..insertAll(
          insertAt, missing.map((e) => '    ${e.key}: ${e.value}'));
      written.add(locale);
    }

    if (written.isNotEmpty) {
      file.writeAsStringSync('${lines.join('\n')}\n');
      context.out.writeln(
          '  ✓ Wrote store URLs to ${StoreInfoConfig.fileName} '
          '(${written.join(', ')})');
    }
    if (manual.isNotEmpty) {
      context.out.writeln(
          '  ! Some locale blocks are not in block form — add these '
          'manually:\n${manual.join('\n')}');
    }
    if (written.isEmpty && manual.isEmpty) {
      context.out.writeln('  ✓ Store URLs already set');
    }
  }

  /// Finds the `  <locale>:` line inside the top-level `locales:` block.
  /// Scoped and literal so a same-named key elsewhere (or a regex
  /// metacharacter in the locale) cannot mistarget the insertion.
  int _localeLineIndex(List<String> lines, String locale) {
    final localesIndex =
        lines.indexWhere((line) => line.trimRight() == 'locales:');
    if (localesIndex < 0) return -1;
    for (var i = localesIndex + 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      // Left the locales block.
      if (!line.startsWith('  ')) return -1;
      if (line.startsWith('  ') &&
          !line.startsWith('   ') &&
          line.trimRight() == '  $locale:') {
        return i;
      }
    }
    return -1;
  }
}
