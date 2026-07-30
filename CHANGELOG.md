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
