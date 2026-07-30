# Easy Setup - Feature Status

> Version: 0.0.2

A CLI tool that configures Flutter project flavors and CI/CD pipelines from a single `easy_setup.yaml` file.

---

## Usage

```bash
easy_setup flavor              # Flavor setup (default command, can be omitted)
easy_setup ci-cd               # CI/CD pipeline generation
easy_setup flavor --dry-run    # Preview changes without modifying files
easy_setup flavor -p ./myapp   # Specify project path directly
```

---

## Implemented Features

### 1. Android Flavor Setup

Automatically modifies `build.gradle` / `build.gradle.kts` based on flavor definitions in YAML.

- Inserts `flavorDimensions` + `productFlavors` blocks
- Sets per-flavor `applicationId`, `versionCode`, `versionName`
- Configures `signingConfigs` (when keystore/alias are specified)
- Auto-inserts `com.google.gms.google-services` plugin into `build.gradle` + `settings.gradle` when Firebase is configured
- Supports both Groovy DSL and Kotlin DSL
- Idempotent (skips if already configured)

```yaml
flavors:
  dev:
    bundle_id: com.example.app.dev
    name: MyApp Dev
    version_code: 1
    version_name: "1.0.0"
    signing:
      keystore: path/to/keystore.jks
      alias: key-alias
```

---

### 2. iOS Flavor Setup (XcodeGen-based)

Generates an XcodeGen `project.yml` and runs `xcodegen generate` to automatically configure the Xcode project.

- Creates per-flavor Build Configurations (Debug-dev, Release-dev, Profile-dev, ...)
- Auto-generates per-flavor Schemes
- Generates per-flavor xcconfig files (APP_DISPLAY_NAME, DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY, etc.)
- Auto-adds per-flavor build mode mappings to Podfile
- Configures iOS deployment target (`ios_version`)

```yaml
flavors:
  dev:
    bundle_id: com.example.app.dev
    name: MyApp Dev
    ios:
      team_id: XXXXXXXXXX
      provisioning_profile: "profile-name"
      code_sign_identity: "Apple Distribution"
      entitlements: path/to/entitlements.plist

ios_version: "13.0"
```

---

### 3. iOS App Icon Auto-Generation

Automatically resizes a single 1024x1024 source image into all 15 required iOS icon sizes.

- Independent icon sets per flavor (`AppIcon-{flavor}.appiconset`)
- Auto-generates `Contents.json`
- Automatically cleans up unused icon directories

```yaml
flavors:
  dev:
    app_icon: resources/icons/icon_dev.png
  prod:
    app_icon: resources/icons/icon_prod.png
```

---

### 4. Localized App Display Names

Auto-generates per-flavor, per-locale `InfoPlist.strings` for app display names.

- Converts `CFBundleDisplayName` in `Info.plist` to an xcconfig variable reference
- Generates `ios/Flavors/{flavor}/{locale}.lproj/InfoPlist.strings` per flavor
- Includes a build script that copies the correct flavor's strings at build time

```yaml
flavors:
  dev:
    name: MyApp Dev        # Default display name
    localized:
      ko:
        app_name: MyApp Dev (Korean)
      ja:
        app_name: MyApp Dev (Japanese)

localizations: [ko, en, ja]
```

---

### 5. Localized iOS Permission Descriptions

Configures localized permission request descriptions for iOS. Also auto-maps `permission_handler` GCC macros in the Podfile.

- Base permission descriptions (en.lproj)
- Per-locale permission descriptions
- Supports 20 permission keys (camera, microphone, photos, location, contacts, calendars, bluetooth, tracking, etc.)

```yaml
permission:
  NSCameraUsageDescription: "Camera access required"
  NSPhotoLibraryUsageDescription: "Photo access required"

localized_permission:
  ko:
    NSCameraUsageDescription: "Camera access is required (Korean)"
  ja:
    NSCameraUsageDescription: "Camera access is required (Japanese)"
```

---

### 6. Firebase Integration

Automatically connects per-flavor Firebase projects. Runs `flutterfire configure` to download config files and generates a unified router.

- Android: downloads `android/app/src/{flavor}/google-services.json`
- iOS: downloads `ios/Runner/Firebase/{flavor}/GoogleService-Info.plist`
- Generates per-flavor `lib/firebase_options_{flavor}.dart`
- Generates unified `lib/firebase_options.dart` (auto-routes by flavor)
- Includes a build script that copies the correct flavor's plist at build time (exact flavor suffix matching)
- Automatically restores previous config files if `flutterfire configure` fails (backup/restore)

```yaml
flavors:
  dev:
    firebase:
      project_id: my-firebase-dev
  prod:
    firebase:
      project_id: my-firebase-prod
```

---

### 7. iOS CI/CD Pipeline Generation

Auto-generates Fastlane files and GitHub Actions workflows.

**Generated Fastlane configuration:**
- `.env` - Environment variables (TEAM_ID, API_KEY_ID, etc.)
- `Gemfile` - Ruby dependencies
- `Appfile` - App Store Connect credentials
- `Matchfile` - Certificate/provisioning profile management
- `Fastfile` - Build and deploy lanes

**Available Fastlane Lanes:**
| Lane | Description |
|------|-------------|
| `sync_certs` | Sync certificates + provisioning profiles |
| `refresh_profiles` | Regenerate provisioning profiles only |
| `beta` | Flutter build + TestFlight upload |
| `register` | Register app on App Store Connect (supports 2FA) |
| `increment_build_number_in_pubspec` | Auto-increment version in pubspec.yaml |

**GitHub Actions Workflow (`ios-deploy.yml`):**
- Manual trigger via workflow_dispatch with flavor selection
- Auto-installs Flutter SDK / Ruby / Fastlane
- Match certificate sync, build, and TestFlight upload

```yaml
# No separate ci_cd section needed in easy_setup.yaml
# Flavor info is automatically used for generation
```

---

### 8. App Store Metadata Management

Manages per-locale app information for App Store upload.

- Generates text files under `ci_cd/ios/fastlane/metadata/{locale}/`
- Uploads to App Store Connect via the `update_metadata` lane
- Supported fields: name, description, subtitle, keywords, promotional_text, release_notes, privacy_url, support_url, marketing_url

```yaml
metadata:
  ko:
    name: My App (Korean)
    description: "App description in Korean"
    keywords: "keyword1,keyword2"
  en-US:
    name: My App
    description: "App description"
```

---

### 9. Dry-Run Mode

All features support the `--dry-run` flag. Preview what changes will be made without modifying any files.

---

### 10. Idempotency

All setup operations are safe to run multiple times. If a configuration is already applied, it is skipped, ensuring identical results on repeated runs.

---

## Platform Feature Support Matrix

| Feature | Android | iOS |
|---------|:-------:|:---:|
| Flavor setup (build config) | O | O |
| App icon auto-generation | - | O |
| Localized app names | - | O |
| Localized permission descriptions | - | O |
| Firebase integration | O | O |
| CI/CD pipeline | - | O |
| App Store metadata | - | O |
| Code signing | O (signingConfigs) | O (xcconfig) |

---

## Not Yet Implemented / Future Extensions

| Area | Description |
|------|-------------|
| Android app icons | Adaptive icon / mipmap auto-generation |
| Android localized app names | `strings.xml`-based localized app names |
| Android CI/CD | Fastlane Android lanes / Google Play deploy workflow |
| Google Play metadata | Play Console app description, screenshot management |
| Android permissions | Android runtime permission configuration |
| Web / macOS / Windows / Linux | Flutter multi-platform flavor support |
| Environment variables / .env | Per-flavor API endpoints, feature flags via dart-define |
| Launch screen / Splash | Per-flavor launch screen configuration |
| pub.dev publishing | Install CLI tool via `dart pub global activate` |
