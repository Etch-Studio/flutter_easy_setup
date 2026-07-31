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
