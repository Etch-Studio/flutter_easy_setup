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
