## 0.1.0-dev.10

Store listings without the web UIs.

- New **store** setup step, activated by an `easy_setup_store_info.yaml`
  next to easy_setup.yaml: app-level fields (copyright, categories) and
  per-locale listing texts (name, subtitle, description, keywords,
  promotional text, release notes, short_description, URLs) in one file
- One source generates both fastlane trees (`fastlane/metadata/{locale}`
  for deliver, `fastlane/metadata/android/{locale}` for supply) with
  store character limits enforced at parse time and convergent pruning
  of removed fields
- `setup --only store` uploads immediately: iOS via
  `deliver --skip_binary_upload` (screenshots included when the M5
  pipeline produced them), Android via metadata-only `supply` when the
  `android` section is configured. Missing credentials degrade to
  generate-only with a warning
- New `deploy --submit` (iOS): submits the just-uploaded build for App
  Store review via deliver (metadata untouched — that is the store
  step's job). Opt-in, never the default
- `review_information` section (App Review contact / demo account) —
  generated into deliver's review_information files. Providing it also
  avoids deliver's first-version "No data" crash
  (fastlane/fastlane#20538), and the missing/invalid phone number that
  App Store Connect hard-requires is warned about up front. Verified
  end-to-end on the dream-diary pilot
- `age_rating` section (questionnaire answers, snake_case keys) →
  generated as deliver's `app_rating_config_path` JSON (camelCase ASC
  attributes) and wired into the upload; removed section prunes the JSON
- Manual by design (no official ASC API — same policy as app record
  creation): App Privacy data-collection labels (the step names the
  one-time web location), pricing
- New **site** step (`site:` section): generates the promo/support/
  privacy pages every store listing needs, a `SITE_BRIEF.md` with the
  app's facts, an `app-site` Claude Code skill, and a GitHub Pages
  workflow. Pages are created but never overwritten, so hand edits and
  AI redesigns survive; the derived Pages URLs are written into
  `easy_setup_store_info.yaml` (existing URLs win) so the store step
  uploads them

## 0.1.0-dev.9

Monorepo-aware `init` (from the dream-diary pilot):

- The caller workflow is now generated at the **git repository root**
  (the only place GitHub Actions reads workflows from), and when the
  Flutter app lives in a subdirectory the `project-root` input is wired
  into both jobs automatically — no manual configuration needed
- **BREAKING**: `init` outside a Flutter project no longer falls back to
  the current directory (which scattered the skeleton at a monorepo
  root); it now fails with guidance to run inside the app or pass
  `--project-root`

## 0.1.0-dev.8

v2 rebuild, milestone M5b (see V2_PLAN.md §5.2): screenshot composition.

- New **screenshots** setup step — the marketing-composition layer of
  the two-layer pipeline. Raw captures under
  `assets/store/screenshots/raw/{locale}/{device}/*.png` are composed
  onto store-spec canvases and written where fastlane deliver/supply
  upload from:
  - iOS: `fastlane/screenshots/{locale}/` — iPhone 6.9" 1320×2868 and
    iPad 13" 2064×2752 (the two sizes Apple auto-scales the rest from)
  - Android: `fastlane/metadata/android/{locale}/images/
    phoneScreenshots/` (1080×1920) + `featureGraphic.png`
    (1024×500, validated)
- captions.yaml (`screenshots.captions`): background/text colors and
  per-locale captions per screen; captions render with a user-supplied
  BMFont zip (`font:`) — required for non-Latin text, warned when
  captions exist without one
- Guards: Play's 2-screenshot minimum warns, missing raw directories
  warn with the expected path, byte-level idempotent outputs
- Raw-capture automation (simulator/emulator matrix) starts local-only
  per the §10.3 decision and is not part of this step

## 0.1.0-dev.7

v2 rebuild, milestone M5a (see V2_PLAN.md §5.1): app icon pipeline.

- New **branding** setup step (in-house implementation kept per the
  §10.2 decision): only source assets live in git
  (`branding.icon_src`: icon.png, optional fg/bg/mono.png), everything
  else is regenerated from them
- iOS: default `AppIcon.appiconset` (15 sizes + Contents.json) via the
  proven v1 generator
- Android: legacy `mipmap-*/ic_launcher.png` (5 densities), adaptive
  icon layers (fg/bg, 108dp base) with `mipmap-anydpi-v26/
  ic_launcher.xml`, and the Android 13+ themed monochrome layer when
  mono.png exists
- Validations that block store rejections early: icon.png must be
  1024×1024 with **no transparency** (App Store rule); fg.png content
  outside the central 66% adaptive safe area warns
- Byte-level idempotency — unchanged outputs are not rewritten

## 0.1.0-dev.6

v2 rebuild, milestone M4c (see V2_PLAN.md): Developer Portal automation.

- The ios_capabilities step now syncs the Developer Portal via the
  official ASC API when the ASC key env vars are set: registers the
  bundle ID when missing (POST /v1/bundleIds) and enables declared
  capability types (POST /v1/bundleIdCapabilities —
  push_notifications → PUSH_NOTIFICATIONS, app_groups → APP_GROUPS).
  Idempotent: existing registrations/capabilities are left untouched.
  A portal change prints the profile-invalidation warning
  (`match --force` / next deploy). Without the ASC key it falls back to
  the manual guidance
- `AscJwt` (ES256, 20-minute validity) + `AscApiClient` ported from the
  verified v1 implementation, rebuilt on the injectable HttpJsonClient.
  `dart_jsonwebtoken` dependency restored
- Bundle ID lookup compares identifiers exactly (the ASC filter matches
  substrings — com.x.dev must not shadow com.x)

## 0.1.0-dev.5

v2 rebuild, milestone M4b (see V2_PLAN.md): Setup Kit — firebase +
ios_capabilities.

- **firebase** step (§5.6): creates the Firebase project when missing
  (`firebase projects:create`), then `flutterfire configure
  --platforms=android,ios --yes` generates google-services.json,
  GoogleService-Info.plist, and lib/firebase_options.dart.
  `firebase.project_id` is required; `analytics: true` prints the
  one-time console link (the GA link API needs a GA account choice)
- **ios_capabilities** step (§5.3, local parts): generates/merges
  `ios/Runner/Runner.entitlements` from `ios.capabilities`
  (push_notifications → aps-environment, app_groups → application-groups),
  wires `CODE_SIGN_ENTITLEMENTS` via the Flutter xcconfig files (no
  pbxproj surgery), and injects `UIBackgroundModes` into Info.plist.
  Warns when `remote-notification` lacks the push capability, and points
  at the manual Developer Portal step (ASC API automation lands in M4c —
  capability changes invalidate provisioning profiles; regenerate via
  deploy or `match --force`)
- Shared plist text helpers extracted (`PlistText`), reused by the admob
  step

## 0.1.0-dev.4

v2 rebuild, milestone M4a (see V2_PLAN.md): Setup Kit — sentry + admob.

- `setup` is now implemented: idempotent steps driven by the sections in
  easy_setup.yaml, `--only <step>` to run one, `--dry-run` to preview
- **sentry** step (§5.5, fully API-automated): creates the Sentry project
  when missing (409 = already exists), resolves the team (`sentry.team`,
  default: the org's first team), fetches the DSN, and writes
  `SENTRY_DSN` into env.json / env.prod.json for
  `--dart-define-from-file`. Requires `SENTRY_ORG_TOKEN`
- **admob** step (§5.4, Plan B): injects the Android APPLICATION_ID
  meta-data, iOS `GADApplicationIdentifier` + `SKAdNetworkItems`, and
  ad unit IDs as `ADMOB_<NAME>_<PLATFORM>` env keys — env.json gets
  Google's official test ID when `ad_units.<name>.type` is declared
  (banner | interstitial | rewarded | native | app_open),
  env.prod.json the real IDs
- New schema fields: `sentry.team`, `admob.ad_units.<name>.type`
- Remaining M4 scope (firebase, ios capabilities) lands as M4b

## 0.1.0-dev.3

v2 rebuild, milestone M3 (see V2_PLAN.md): Deploy Kit Android + reusable
CI workflows.

- `deploy` now deploys Android to Google Play:
  preflight (doctor checks incl. the Play service account) →
  `flutter build appbundle` → `fastlane supply` (metadata/screenshot
  upload skipped — that is the M5 pipeline's job)
- Play track from `android.play_track_default`, overridable per run with
  `--track internal|alpha|beta|production`
- `PLAY_SERVICE_ACCOUNT_JSON` accepts a file path or raw JSON (raw JSON
  is materialized as an ephemeral file for fastlane)
- Deploying with both `ios` and `android` configured runs both platforms
  in one command
- Reusable GitHub Actions workflows shipped in this repo
  (`release-ios.yml`, `release-android.yml`, `workflow_call`): tag push →
  both stores, secrets inherited from the org/repo
- `init` now also generates the 5-line caller workflow
  (`.github/workflows/release.yml`), kept untouched when it already exists

## 0.1.0-dev.2

v2 rebuild, milestone M2 (see V2_PLAN.md): Deploy Kit iOS.

- `deploy` now deploys iOS to TestFlight in one command:
  preflight (doctor checks) → `fastlane match appstore` →
  `flutter build ipa` (manual signing via a generated ExportOptions.plist
  pointing at the match App Store profile) → `fastlane pilot upload`
- Version resolution: a `v*` git tag at HEAD wins, else the pubspec
  version; build number from `--build-number` > `GITHUB_RUN_NUMBER` >
  the pubspec `+N` suffix (tag push = release trigger, same code path
  locally and in CI)
- ASC API key (`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_P8[_PATH]`) is
  materialized as an ephemeral fastlane api_key.json for match and pilot,
  deleted when the deploy finishes
- `--dry-run` previews the exact commands without executing anything
- Android deploy fails fast pointing at milestone M3

## 0.1.0-dev.1

v2 rebuild, milestone M1 (see V2_PLAN.md): CLI skeleton + v2 schema + doctor.

- **BREAKING**: New v2 `easy_setup.yaml` schema (`app` / `ios` / `android` /
  `flavors` / `branding` / `screenshots` / `sentry` / `firebase` / `admob`
  top-level sections). The v1 `easy_setup:` root key is detected and reported
  with migration guidance. `flavor` and `ci-cd` still read the v1 schema
  until they are ported.
- **BREAKING**: Running without a subcommand now prints usage instead of
  defaulting to `flavor`.
- New `init` command — generates a v2 easy_setup.yaml template (interactive
  prompts on a terminal) and the asset folder skeleton
  (`assets/branding/icon/`, `assets/store/screenshots/`)
- New `doctor` command — verifies environment tooling (Flutter, Xcode,
  CocoaPods, Fastlane, ...), project config, and deploy keys/secrets
  (`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_P8[_PATH]`, `MATCH_PASSWORD`,
  `PLAY_SERVICE_ACCOUNT_JSON`, `SENTRY_ORG_TOKEN`), with step-by-step
  issuance guidance for anything missing
- New `setup` / `deploy` commands registered as stubs (planned: M4 / M2-M3)
- CLI rewritten on `CommandRunner` with per-command help

## 0.0.2

- Remove unused `app_store` module (JwtGenerator, AppStoreConnectClient) and `dart_jsonwebtoken` dependency
- Remove unused `subtype` parameter and `_buildConfigIterationBlock` method
- Translate all code comments, README, and docs to English
- Clarify that `localized` / `localized_permission` are for non-English locales only (English is the base language)
- CI/CD credentials are now configured via `.env` file instead of YAML
- Add `repository` URL to pubspec.yaml
- **Firebase**: Replace file-path copy with FlutterFire CLI (`flutterfire configure`) — specify `firebase.project_id` per flavor instead of file paths

## 0.0.1

### Flavor Command (default)

- **Android**: Auto-configure `build.gradle` / `build.gradle.kts` with `flavorDimensions` and `productFlavors` (brace-counting parser for nested Groovy/Kotlin DSL)
- **iOS (XcodeGen-based)**: Generate `project.yml` and run `xcodegen generate` to configure Xcode project
  - Generate per-flavor xcconfig files (Debug/Release/Profile)
  - Modify `Info.plist` for flavor-aware display names
  - Generate/modify `Podfile` with flavor build mode mappings and `ios_version` support
  - Auto-add `permission_handler` GCC macros to Podfile
- **App Icon**: Auto-generate all required icon sizes from a single 1024x1024 source image per flavor, with automatic cleanup of unused icons
- **Localization**: Flavor-specific localized app names via `InfoPlist.strings` and xcconfig variables
- **Firebase**: Configure Firebase per flavor via FlutterFire CLI
- **Idempotency**: All modifiers/generators are idempotent — safe to run multiple times
- **Auto-cleanup**: Unused xcconfig files, schemes, and app icons are removed when flavors change

### CI/CD Command

- **Fastlane**: Generate `.env`, `Gemfile`, `Matchfile`, `Appfile`, and `Fastfile` with `sync_certs`, `build`, `deploy`, and `register` lanes
- **GitHub Actions**: Generate `.github/workflows/ios-deploy.yml` workflow
- **App Store Metadata**: Generate metadata directory structure for App Store Connect
- Credentials configured via `.env` file (no sensitive data in YAML)

### General

- `--dry-run` / `-n` flag to preview changes without writing files
- `--project-root` / `-p` flag to specify Flutter project root
- Subcommand omission defaults to `flavor` for backward compatibility
- User-friendly error messages via `SetupException`
