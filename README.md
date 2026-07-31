# easy_setup

A Dart CLI tool that automatically configures Flutter project flavor (build variant) environments and CI/CD pipelines **with a single command**.

Just write one `easy_setup.yaml` configuration file, and it will automatically set up complex build configurations for both Android and iOS, along with CI/CD pipelines (Fastlane + GitHub Actions).

> **⚠️ v2 rebuild in progress** (see `V2_PLAN.md`): easy_setup is being rebuilt
> as a universal **Setup Kit + Deploy Kit** toolkit. Current state (M1):
>
> | Command | Status |
> |---|---|
> | `init` | ✅ New — generates a v2 `easy_setup.yaml` template + asset folder skeleton |
> | `doctor` | ✅ New — verifies environment, keys, and secrets with issuance guidance |
> | `setup` | ✅ Sentry & Firebase provisioning · AdMob ID injection · iOS capabilities (entitlements + UIBackgroundModes; Portal API: M4c) |
> | `deploy` | ✅ iOS (match + build ipa + TestFlight) · Android (build appbundle + Play `supply`) |
> | CI | ✅ Reusable workflows `release-ios.yml` / `release-android.yml` — tag push → both stores; `init` generates the caller workflow |
> | `flavor` | v1 feature, still uses the v1 `easy_setup:` schema described below |
> | `ci-cd` | v1 feature, will be redesigned as reusable workflows |
>
> The v2 schema (`app:` / `ios:` / `sentry:` / ... top-level sections) and the
> v1 schema (`easy_setup:` root key) are different; the rest of this README
> documents v1 behavior. Running without a subcommand no longer defaults to
> `flavor`.

---

## Table of Contents

- [Key Features](#key-features)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration File (easy_setup.yaml)](#configuration-file-easy_setupyaml)
- [Localization](#localization)
- [App Icon Auto-Generation](#app-icon-auto-generation)
- [CI/CD Setup (ci-cd command)](#cicd-setup-ci-cd-command)
- [Auto-Modified Files](#auto-modified-files)
- [Project Structure](#project-structure)
- [Module Descriptions](#module-descriptions)
- [Design Principles](#design-principles)
- [Troubleshooting](#troubleshooting)

---

## Key Features

| Platform | Auto-Configured Items |
|----------|----------------------|
| **Android** | Add `flavorDimensions` + `productFlavors` blocks to `build.gradle` (supports both Groovy/Kotlin DSL) |
| **iOS** | Generate xcconfig files (Debug/Release/Profile per flavor) |
| **iOS** | Auto-generate XcodeGen `project.yml` → create Xcode project via `xcodegen generate` |
| **iOS** | Replace app name in `Info.plist` with xcconfig variable |
| **iOS** | Add build mode mapping to `Podfile` |
| **iOS** | Auto-generate app icons from 1024x1024 source image (per-flavor support) |
| **iOS** | Auto-generate per-locale `InfoPlist.strings` (app name + permission description localization) |
| **Firebase** | Auto-configure Firebase per flavor via FlutterFire CLI (`google-services.json` + `GoogleService-Info.plist`) |
| **CI/CD** | Auto-generate Fastlane files (.env, Gemfile, Matchfile, Appfile, Fastfile + register lane) |
| **CI/CD** | Auto-generate GitHub Actions workflow (ios-deploy.yml) |
| **CI/CD** | Auto-generate `register` lane for App Store Connect app creation (`fastlane produce`) |
| **CI/CD** | App Store Connect metadata management (promotional text, description, release notes, etc.) + auto-generate `update_metadata` lane |

---

## Installation

### Prerequisites

[XcodeGen](https://github.com/yonaskolb/XcodeGen) is required for iOS project setup:

```bash
brew install xcodegen
```

### Install from pub.dev (Recommended)

```bash
dart pub global activate easy_setup
```

After installation, you can run `easy_setup` from anywhere.

---

## Usage

### Basic Usage

Create `easy_setup.yaml` in your Flutter project root and run:

```bash
# Flavor setup (default command)
easy_setup
easy_setup flavor

# CI/CD pipeline setup
easy_setup ci-cd
```

### CLI Options

```
Usage: easy_setup <command> [options]

Commands:
  flavor    Configure Flutter flavor environments (Android + iOS)  [default]
  ci-cd     Generate CI/CD pipeline setup (Fastlane + GitHub Actions)

Options:
  -h, --help            Show help
  -n, --dry-run         Preview changes without modifying any files
  -p, --project-root    Specify Flutter project root path (default: auto-detect)
```

### Examples

```bash
# Preview flavor setup with dry-run
easy_setup --dry-run

# Preview CI/CD setup
easy_setup ci-cd --dry-run

# Specify a project path
easy_setup -p /path/to/flutter/project
easy_setup ci-cd -p /path/to/flutter/project
```

### Next Steps After Running

**After flavor command:**

```bash
flutter pub get
cd ios && pod install
flutter run --flavor dev -t lib/main.dart
```

**After ci-cd command:**

```bash
# 1. Edit ci_cd/ios/fastlane/.env with your actual values
# 2. Then:
cd ci_cd/ios/fastlane
bundle exec fastlane match init  # First time only
bundle exec fastlane register    # Create apps on App Store Connect (requires 2FA)
bundle exec fastlane update_metadata  # Upload metadata (when metadata is configured)
# Configure GitHub Secrets (see CI/CD section below)
```

---

## Configuration File (easy_setup.yaml)

Create an `easy_setup.yaml` file in your Flutter project root:

```yaml
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.app.dev
      name: MyApp Dev
      app_icon: assets/icons/dev_icon.png       # Optional: 1024x1024 source image
      localized:                                 # Optional: per-flavor localization (non-English only)
        ko:
          app_name: 마이앱 Dev
        ja:
          app_name: マイアプリ Dev
    staging:
      bundle_id: com.example.app.staging
      name: MyApp Staging
    prod:
      bundle_id: com.example.app
      name: MyApp
      app_icon: assets/icons/prod_icon.png
      localized:
        ko:
          app_name: 마이앱

  localizations: [ko, en]                          # Optional: Xcode knownRegions setting
  permission:                                              # Optional: Default iOS permission descriptions (Base.lproj)
    NSCameraUsageDescription: "Camera access is required"
    NSPhotoLibraryUsageDescription: "Photo library access is required"
  localized_permission:                                    # Optional: Per-locale iOS permission descriptions (non-English only)
    ko:
      NSCameraUsageDescription: "카메라 접근이 필요합니다"
      NSPhotoLibraryUsageDescription: "갤러리 접근이 필요합니다"
```

### Flavor Field Descriptions

| Field | Required | Description | Example |
|-------|----------|-------------|---------|
| `bundle_id` | Yes | Unique app identifier (Android applicationId / iOS PRODUCT_BUNDLE_IDENTIFIER) | `com.example.app.dev` |
| `name` | Yes | User-facing app display name (Android app_name / iOS APP_DISPLAY_NAME) | `MyApp Dev` |
| `version_code` | | App version code (integer) | `42` |
| `version_name` | | App version name (string) | `1.0.0-dev` |
| `app_icon` | | Path to 1024x1024 source image (relative to project root) | `assets/icons/dev_icon.png` |
| `localized` | | Per-flavor locale settings (see [Localization](#localization) below) | |
| `signing` | | Android signing settings (`keystore`, `alias`) | |
| `firebase` | | Firebase configuration (`project_id`) — uses FlutterFire CLI | |
| `ios` | | iOS-specific settings (`team_id`, `provisioning_profile`, `code_sign_identity`, `entitlements`) | |

---

## Localization

Localization settings are divided into three parts:

### 1. `localizations` — Xcode knownRegions

Setting the `localizations` list registers those languages in Xcode's `knownRegions`:

```yaml
easy_setup:
  localizations: [ko, en, zh-HK]
```

### 2. Per-Flavor `localized` — App Name

Add a `localized` section under each flavor to set per-locale app names. English is the base language — the `name` field is used as the English app name, so only add non-English locales here:

```yaml
easy_setup:
  flavors:
    dev:
      bundle_id: com.example.app.dev
      name: MyApp Dev                              # Used as the English (base) app name
      app_icon: assets/icons/dev_icon.png
      localized:                                   # Non-English locales only
        ko:
          app_name: 마이앱 Dev
        ja:
          app_name: マイアプリ Dev
```

| Field | Description |
|-------|-------------|
| `app_name` | Per-locale app display name. Generated as `CFBundleDisplayName` in `InfoPlist.strings` |

### 3. `permission` / `localized_permission` — iOS Permission Descriptions

Set permission descriptions at the `easy_setup` level. `permission` provides defaults in English (included in `en.lproj`), `localized_permission` provides non-English locale values:

```yaml
easy_setup:
  permission:                                      # English (base) permission descriptions
    NSCameraUsageDescription: "Camera access is required"
    NSPhotoLibraryUsageDescription: "Photo library access is required"
  localized_permission:                            # Non-English locales only
    ko:
      NSCameraUsageDescription: "카메라 접근이 필요합니다"
      NSPhotoLibraryUsageDescription: "사진 접근이 필요합니다"
```

| Field | Description |
|-------|-------------|
| `permission` | English (base) iOS permission descriptions. Included in `en.lproj/InfoPlist.strings` |
| `localized_permission` | Non-English per-locale iOS permission descriptions. Generated in each `{locale}.lproj/InfoPlist.strings` |

### Per-Flavor Localized App Name

Each flavor can define different app names per locale. Here's how it works:

English is the base language — the `name` field is used as the English display name, so you only need to add non-English locales in `localized`.

**How it works:**
1. Per-locale variables are defined in each flavor's `.xcconfig` file (Debug-{flavor}.xcconfig, etc.)
   - `APP_DISPLAY_NAME=MyApp Dev` (English, from `name` field)
   - `APP_DISPLAY_NAME_KO=마이앱 Dev` (Korean, from `localized`)

2. `InfoPlist.strings` references the xcconfig variables
   - `en.lproj/InfoPlist.strings`: uses `$(APP_DISPLAY_NAME)` (base)
   - `ko.lproj/InfoPlist.strings`: uses `$(APP_DISPLAY_NAME_KO)`

**Example:**
```yaml
flavors:
  dev:
    name: MyApp Dev              # English app name (base)
    localized:                   # Non-English only
      ko: app_name: "마이앱 Dev"
  prod:
    name: MyApp
    localized:
      ko: app_name: "마이앱"
```

With this configuration:
- `dev` flavor + English: displays "MyApp Dev" (from `name`)
- `dev` flavor + Korean: displays "마이앱 Dev" (from `localized.ko`)
- `prod` flavor + English: displays "MyApp" (from `name`)
- `prod` flavor + Korean: displays "마이앱" (from `localized.ko`)

### Generated Files

Per-flavor `app_name` and `localized_permission` are merged to generate per-locale `InfoPlist.strings` files:

```
ios/Runner/ko.lproj/InfoPlist.strings
ios/Runner/ja.lproj/InfoPlist.strings
ios/Runner/en.lproj/InfoPlist.strings
```

Example file content (`ko.lproj/InfoPlist.strings`):

```
"CFBundleDisplayName" = "마이앱 Dev";
"NSCameraUsageDescription" = "카메라 접근이 필요합니다";
"NSPhotoLibraryUsageDescription" = "사진 접근이 필요합니다";
```

---

## App Icon Auto-Generation

When you specify a 1024x1024 PNG source image path in the `app_icon` field, running `easy_setup flavor` will automatically generate iOS app icons.

### How It Works

1. Loads and validates the source image (1024x1024).
2. Resizes to 15 unique sizes and generates PNG files.
3. Generates `Contents.json` (19 entries).
4. Automatically sets `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-{flavor}` in xcconfig.

### Generated Path

```
ios/Runner/Assets.xcassets/AppIcon-{flavor}.appiconset/
  Contents.json
  Icon-App-20x20@1x.png      (20px)
  Icon-App-20x20@2x.png      (40px)
  Icon-App-20x20@3x.png      (60px)
  Icon-App-29x29@1x.png      (29px)
  Icon-App-29x29@2x.png      (58px)
  Icon-App-29x29@3x.png      (87px)
  Icon-App-40x40@1x.png      (40px)
  Icon-App-40x40@2x.png      (80px)
  Icon-App-40x40@3x.png      (120px)
  Icon-App-60x60@2x.png      (120px)
  Icon-App-60x60@3x.png      (180px)
  Icon-App-76x76@1x.png      (76px)
  Icon-App-76x76@2x.png      (152px)
  Icon-App-83.5x83.5@2x.png  (167px)
  Icon-App-1024x1024@1x.png  (1024px)
```

---

## CI/CD Setup (ci-cd command)

The `easy_setup ci-cd` command automatically generates all files needed for iOS CI/CD. No `ci_cd` section is needed in `easy_setup.yaml` — flavors are read from `easy_setup.flavors`, and sensitive credentials are configured via a `.env` file after generation.

1. Generate Fastlane files (.env, Gemfile, Matchfile, Appfile, Fastfile)
2. Run `bundle install`
3. Add `register` lane to Fastfile (for App Store Connect app creation)
4. Generate metadata files + add `update_metadata` lane (when `metadata` is configured in YAML)
5. Generate GitHub Actions workflow

### Generated Files

| File | Description |
|------|-------------|
| `ci_cd/ios/fastlane/.env` | Environment variables (Team ID, API Key, etc.) — edit this after generation |
| `ci_cd/ios/fastlane/Gemfile` | Fastlane Ruby dependencies |
| `ci_cd/ios/fastlane/Matchfile` | Match certificate/profile settings |
| `ci_cd/ios/fastlane/Appfile` | App identification info (team_id, itc_team_id) |
| `ci_cd/ios/fastlane/Fastfile` | Build + TestFlight deploy + register lanes |
| `ci_cd/ios/fastlane/metadata/{locale}/*.txt` | App Store Connect metadata (when `metadata` is configured) |
| `.github/workflows/ios-deploy.yml` | GitHub Actions workflow |

### Configuration After Generation

After running `easy_setup ci-cd`, edit `ci_cd/ios/fastlane/.env` with your actual values:

```env
TEAM_ID=YOUR_TEAM_ID
ITC_TEAM_ID=YOUR_ITC_TEAM_ID
API_KEY_ID=YOUR_KEY_ID
API_KEY_ISSUER_ID=YOUR_ISSUER_ID
CERTS_REPO_URL=YOUR_CERTS_REPO_URL
APPLE_ID=YOUR_APPLE_ID
```

### App Store Connect App Creation (register lane)

You can create apps on App Store Connect through the auto-generated `register` lane in the Fastfile.
Since app creation requires Apple ID authentication (2FA), the user must run it manually:

```bash
cd ci_cd/ios/fastlane && bundle exec fastlane register
```

### App Store Connect Metadata Management

When the `metadata` section is configured in `easy_setup.yaml`, per-locale metadata files are auto-generated and an `update_metadata` lane is added to the Fastfile.

```yaml
easy_setup:
  metadata:
    ko:
      promotional_text: "Korean promotional text"
      description: "App description"
      release_notes: "Bug fixes and improvements"
      keywords: "keyword1, keyword2"
      name: "MyApp"
      subtitle: "Subtitle"
      privacy_url: "https://example.com/privacy"
      support_url: "https://example.com/support"
      marketing_url: "https://example.com"
    en-US:
      promotional_text: "English promotional text"
      description: "App description"
```

**Generated directory structure:**

```
ci_cd/ios/fastlane/metadata/
  ko/
    promotional_text.txt
    description.txt
    release_notes.txt
    keywords.txt
    name.txt
    subtitle.txt
    privacy_url.txt
    support_url.txt
    marketing_url.txt
  en-US/
    promotional_text.txt
    description.txt
```

**Supported metadata fields:**

| Field | Filename | Description |
|-------|----------|-------------|
| `promotional_text` | `promotional_text.txt` | Promotional text |
| `description` | `description.txt` | App description |
| `release_notes` | `release_notes.txt` | Release notes (what's new) |
| `keywords` | `keywords.txt` | Search keywords (comma-separated) |
| `name` | `name.txt` | App name |
| `subtitle` | `subtitle.txt` | App subtitle |
| `privacy_url` | `privacy_url.txt` | Privacy policy URL |
| `support_url` | `support_url.txt` | Support URL |
| `marketing_url` | `marketing_url.txt` | Marketing URL |

All fields are optional; only configured fields are generated as files.

**Uploading metadata:**

```bash
cd ci_cd/ios/fastlane && bundle exec fastlane update_metadata
```

### Required GitHub Secrets

| Secret Name | Description |
|-------------|-------------|
| `MATCH_PASSWORD` | Match certificate repository encryption password |
| `MATCH_GIT_BASIC_AUTHORIZATION` | GitHub certificate repo access token (`echo -n "username:PAT" \| base64`) |
| `APP_STORE_CONNECT_API_KEY_BASE64` | .p8 key file contents (`base64 -i AuthKey.p8`) |

---

## Auto-Modified Files

### Android

**`android/app/build.gradle(.kts)`**

The following is added after the `buildTypes` block:

```groovy
// Groovy DSL
flavorDimensions "env"
productFlavors {
    dev {
        dimension "env"
        applicationId "com.example.app.dev"
        resValue "string", "app_name", "MyApp Dev"
    }
    prod {
        dimension "env"
        applicationId "com.example.app"
        resValue "string", "app_name", "MyApp"
    }
}
```

Kotlin DSL (`.kts`) is automatically detected and generates correct syntax.

### iOS

1. **xcconfig files** (`ios/Flutter/`)
   - `Debug-{flavor}.xcconfig` — includes Debug.xcconfig and sets `APP_DISPLAY_NAME`
   - `Release-{flavor}.xcconfig` — includes Release.xcconfig
   - `Profile-{flavor}.xcconfig` — includes Release.xcconfig
   - When `app_icon` is set, `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-{flavor}` is automatically added

2. **App icons** (`ios/Runner/Assets.xcassets/`) — when `app_icon` is set
   - Generates 15 size PNGs + Contents.json in `AppIcon-{flavor}.appiconset/` directory

3. **project.yml + Xcode project** (`ios/`)
   - Generates XcodeGen `project.yml` and runs `xcodegen generate` to configure the Xcode project
   - Auto-generates per-flavor build configurations (Debug/Release/Profile) and schemes

4. **Info.plist** (`ios/Runner/`)
   - Replaces `CFBundleDisplayName` value with `$(APP_DISPLAY_NAME)`

5. **InfoPlist.strings** (`ios/Runner/{locale}.lproj/`) — when `localized` is set
   - Generates per-flavor `app_name` as `CFBundleDisplayName` key
   - Generates global `permission` as corresponding permission keys
   - For the same locale, flavor's app_name and global permission are merged

6. **Podfile** (`ios/`)
   - Adds mappings like `Debug-{flavor} => :debug`, `Release-{flavor} => :release`, etc.

---

## Project Structure

```
easy_setup/
├── bin/
│   └── easy_setup.dart                    # CLI entry point (subcommand routing)
├── lib/
│   ├── easy_setup.dart                    # Library public API (re-export)
│   └── src/
│       ├── exceptions.dart                # SetupException definition
│       ├── models/
│       │   ├── flavor_config.dart         # FlavorConfig, EasySetupConfig, FlavorLocalizedConfig
│       │   └── ci_cd_config.dart          # CiCdConfig, CiCdIosConfig, etc.
│       ├── utils/
│       │   ├── project_finder.dart        # Flutter project path discovery
│       │   ├── xcodegen_runner.dart       # Run xcodegen generate
│       │   └── fastlane_runner.dart       # Gemfile management + fastlane execution
│       ├── commands/
│       │   ├── flavor_command.dart        # Flavor pipeline orchestration
│       │   └── ci_cd_command.dart         # CI/CD pipeline (file generation + Bundle ID registration + register lane)
│       ├── android/
│       │   └── build_gradle_modifier.dart # build.gradle flavor configuration
│       ├── ios/
│       │   ├── app_icon_generator.dart    # App icon auto-generation (resize + Contents.json)
│       │   ├── xcconfig_generator.dart    # xcconfig file generation
│       │   ├── xcodegen_generator.dart    # XcodeGen project.yml generation
│       │   ├── xcodegen_scripts_generator.dart  # Build phase shell script generation
│       │   ├── info_plist_modifier.dart   # Info.plist modification
│       │   ├── info_plist_strings_generator.dart  # {locale}.lproj/InfoPlist.strings generation
│       │   └── podfile_modifier.dart      # Podfile modification
│       ├── firebase/
│       │   └── firebase_copier.dart       # google-services.json / GoogleService-Info.plist copy
│       ├── fastlane/
│       │   ├── gemfile_generator.dart     # Gemfile generation
│       │   ├── matchfile_generator.dart   # Matchfile generation
│       │   ├── appfile_generator.dart     # Appfile generation
│       │   ├── fastfile_generator.dart    # Fastfile generation + lane management (addLane, addRegisterLane, addMetadataLane)
│       │   └── metadata_generator.dart    # App Store Connect metadata file generation
│       └── github/
│           └── workflow_generator.dart    # .github/workflows/*.yml generation
└── pubspec.yaml
```

---

## Module Descriptions

### `bin/easy_setup.dart` — CLI Entry Point
- Parses `--help`, `--dry-run`, `--project-root` options using the `args` package.
- Subcommand routing: `flavor` (default), `ci-cd`.
- Defaults to `flavor` when subcommand is omitted for backward compatibility.

### `FlavorCommand` — Flavor Orchestrator
- Executes the flavor setup process sequentially.
- Auto-detect project root → load YAML → Android → Firebase (FlutterFire CLI) → iOS (xcconfig → app icons → XcodeGen → plist → InfoPlist.strings → Podfile).
- Calls `AppIconGenerator` for flavors with `app_icon` set to auto-generate per-flavor icons.
- Merges per-flavor `localized` (app_name) and global `localized_permission` (permissions) to generate `.strings` files via `InfoPlistStringsGenerator`.

### `CiCdCommand` — CI/CD Orchestrator
- Executes CI/CD pipeline setup sequentially.
- Load YAML → resolve flavors from `easy_setup.flavors` → generate .env + Fastlane files → bundle install → add register lane → generate metadata → GitHub Actions workflow → print instructions.
- Credentials are configured via `.env` file (not YAML) for security.
- Adds register lane to Fastfile via `FastfileGenerator.addRegisterLane()`.
- Generates metadata files and adds `update_metadata` lane when `metadata` is configured in YAML.

### `AppIconGenerator` — iOS App Icon Generation
- Resizes 1024x1024 source PNG to 15 unique sizes per flavor (using the `image` package).
- Generates `Contents.json` (19 entries) mapping icons for iPhone/iPad/App Store.
- Safe for re-runs with overwrite mode (idempotent).

### `InfoPlistStringsGenerator` — iOS InfoPlist.strings Generation
- Merges per-flavor `localized` (app_name) and global `localized_permission` (permissions).
- Generates `ios/Runner/{locale}.lproj/InfoPlist.strings` files per locale.
- Maps `app_name` → `CFBundleDisplayName`, permission keys → corresponding permission keys.

### `FastfileGenerator` — Fastfile Generation + Lane Management
- `generate()`: Creates the base Fastfile skeleton (api_key, certificates, beta lane).
- `addLane()`: General-purpose lane insertion (marker-based idempotent strip-and-replace).
- `addRegisterLane()`: Generates register lane (`produce` invocation code).
- `addMetadataLane()`: Generates update_metadata lane (`deliver` invocation code).

### `MetadataGenerator` — App Store Connect Metadata
- Generates per-locale metadata files under `ci_cd/ios/fastlane/metadata/{locale}/`.
- Uses `LocaleMetadataConfig.toFileMap()` to convert only configured fields to files.

### `FlavorConfig` / `EasySetupConfig` — Configuration Models
- Parses `easy_setup.yaml` into `Map<String, FlavorConfig>`.
- `FlavorConfig.localized`: per-flavor locale settings (`FlavorLocalizedConfig` — app_name).
- `EasySetupConfig.localizations`: language list to register in Xcode knownRegions.
- `EasySetupConfig.permission`: default iOS permission descriptions (for Base.lproj).
- `EasySetupConfig.localizedPermission`: per-locale iOS permission descriptions.
- Provides friendly error messages for missing files or parsing errors.

### `ProjectFinder` — Path Utilities
- Walks up from the current directory checking for `pubspec.yaml` with Flutter SDK reference.
- Returns standard paths for Android and iOS configuration files (including `iosAssetCatalogDir`).

### `BuildGradleModifier` — Android Configuration
- Finds the `buildTypes` block and inserts `flavorDimensions` + `productFlavors` after it.
- Uses brace-counting to accurately detect block boundaries.

### `FirebaseConfigurator` — Firebase Configuration via FlutterFire CLI
- Runs `flutterfire configure` per flavor with the specified `project_id` and `bundle_id`.
- Downloads `google-services.json` to `android/app/src/{flavor}/` and `GoogleService-Info.plist` to `ios/Runner/Firebase/{flavor}/`.
- Requires [FlutterFire CLI](https://firebase.google.com/docs/flutter/setup) to be installed (`dart pub global activate flutterfire_cli`).

### `XcodegenGenerator` — XcodeGen project.yml Generation
- Generates `project.yml` containing per-flavor build configurations (Debug/Release/Profile).
- Runs `xcodegen generate` to auto-create the Xcode project.

### `XcconfigGenerator` — iOS xcconfig Generation
- Generates 3 xcconfig files (Debug/Release/Profile) for each flavor.
- Inherits existing Debug.xcconfig and Release.xcconfig via `#include`.
- Automatically adds `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-{flavor}` when `appIcon` is set.

### `InfoPlistModifier` — iOS Info.plist Modification
- Replaces app display name (`CFBundleDisplayName`) with xcconfig variable (`$(APP_DISPLAY_NAME)`).
- Automatically adds the key if it doesn't exist.

### `PodfileModifier` — iOS Podfile Modification
- Adds flavor entries to CocoaPods build configuration-mode mapping.
- `Debug-{flavor} → :debug`, `Profile-{flavor} → :release`, `Release-{flavor} → :release`.

---

## Design Principles

### Idempotency
All Modifiers/Generators have idempotency guards. Running the same command multiple times does not create duplicate configurations.

### XcodeGen-Based iOS Project Setup
Instead of directly modifying `project.pbxproj`, generates XcodeGen's `project.yml` and configures the Xcode project via `xcodegen generate`. Safe across different Xcode versions.

### Brace-Counting Parser
Since regex alone cannot safely parse nested brace structures, a dedicated parser (`_findBlockEnd`) that tracks depth is used.

### Two-Level Localization
- **Per-flavor `localized`**: Settings that can differ by flavor, such as app icons and app names
- **Global `localized`**: Settings common to all flavors, such as iOS permission descriptions

### Dry-Run Mode
The `--dry-run` flag lets you preview what changes will be made without actually modifying any files.

---

## Troubleshooting

### "Could not find a Flutter project root"
- Run inside a Flutter project directory, or specify the path with the `-p` option.
- Verify that `pubspec.yaml` contains `sdk: flutter`.

### "easy_setup.yaml not found"
- Create an `easy_setup.yaml` file in your project root. (See the Configuration File section above)

### "buildTypes block not found"
- Verify that a `buildTypes` block exists in `android/app/build.gradle(.kts)`.
- It exists by default in projects created with `flutter create`.

### iOS setup is skipped
- Verify that the `ios/` directory exists (iOS support must be enabled via `flutter create`).
- Verify that [XcodeGen](https://github.com/yonaskolb/XcodeGen) is installed.

### "App icon source must be 1024x1024"
- The PNG image at the `app_icon` path must be exactly 1024x1024 pixels.
- Use a PNG file, not JPEG or other formats.

### "App icon source image not found"
- Verify that the `app_icon` path is relative to the project root.
- Verify that the file exists at the specified path.

### Already configured
- `flavor` / `ci-cd`: Uses overwrite mode — removes existing settings and recreates them.
- Bundle ID registration: Existing Bundle IDs are automatically skipped.

### CI/CD Related

**App Store Connect app creation failure**
- Running `bundle exec fastlane register` requires Apple ID 2FA authentication.
- Set `APPLE_ID` in `ci_cd/ios/fastlane/.env` or use the `FASTLANE_USER` environment variable.
