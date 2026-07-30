# Easy Setup - Integration Test Plan

Validates the actual behavior of each feature against the `setup_test` Flutter project.

---

## Prerequisites

- [x] `setup_test/` directory is recognized as a Flutter project
- [x] `easy_setup.yaml` exists in the project root
- [x] Test icon files exist (`resources/icons/icon_bird.png`, `icon_default.png`)

```bash
# How to run the easy_setup CLI (from project root)
dart run bin/easy_setup.dart flavor -p setup_test
dart run bin/easy_setup.dart ci-cd -p setup_test
```

---

## Test Items

### 1. Android Flavor Setup

**Target file:** `setup_test/android/app/build.gradle.kts`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 1-1 | `flavorDimensions` block is inserted | Search for `flavorDimensions` in `build.gradle.kts` | PASS |
| 1-2 | `productFlavors` block contains both dev and prod | Verify `dev { applicationId "studio.etch.test.dev" }` etc. | PASS |
| 1-3 | bundle_id maps correctly to `applicationId` | dev -> `studio.etch.test.dev`, prod -> `studio.etch.test` | PASS |
| 1-4 | No duplicate insertion on second run (idempotency) | Run command twice, verify only one block exists | PASS |
| 1-5 | `--dry-run` does not modify the file | Confirm no file diff after dry-run | PASS |

---

### 2. iOS Flavor Setup (XcodeGen)

**Target files:** `setup_test/ios/project.yml`, `setup_test/ios/Runner.xcodeproj/`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 2-1 | `project.yml` is generated | File exists | PASS |
| 2-2 | Per-flavor build configurations are defined | `Debug-dev`, `Release-dev`, `Profile-dev` etc. exist | PASS |
| 2-3 | Per-flavor schemes are defined | `dev`, `prod` schemes exist | PASS |
| 2-4 | `.xcodeproj` is generated after `xcodegen generate` | `Runner.xcodeproj/project.pbxproj` exists | PASS |
| 2-5 | `ios_version` setting is reflected | Check deploymentTarget in project.yml | PASS |
| 2-6 | project.yml content is identical on second run (idempotency) | Confirm no diff | PASS |

---

### 3. iOS xcconfig Files

**Target path:** `setup_test/ios/Flutter/`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 3-1 | 3 xcconfig files generated per flavor | `Debug-dev.xcconfig`, `Release-dev.xcconfig`, `Profile-dev.xcconfig` exist | PASS |
| 3-2 | `APP_DISPLAY_NAME` matches YAML `name` | dev -> `MyApp Dev`, prod -> `MyApp` | PASS |
| 3-3 | `Profile-*.xcconfig` includes Pods xcconfig | File contains `#include? "Pods/...` | PASS |
| 3-4 | File content is identical on second run (idempotency) | Confirm no diff | PASS |

---

### 4. iOS App Icon Auto-Generation

**Target path:** `setup_test/ios/Runner/Assets.xcassets/`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 4-1 | Per-flavor appiconset directories are generated | `AppIcon-dev.appiconset/`, `AppIcon-prod.appiconset/` exist | PASS |
| 4-2 | All 15 PNG sizes are generated | Verify file count (15 PNG + 1 Contents.json) | PASS |
| 4-3 | `Contents.json` has valid format | JSON parses successfully, images array count is correct | PASS |
| 4-4 | Icon file dimensions are accurate | Verify 1024x1024, 180x180, 120x120 samples | PASS |
| 4-5 | Error message when source image is missing | Specify nonexistent path and verify error | PASS |

---

### 5. Localized App Names (InfoPlist.strings)

**Target path:** `setup_test/ios/Flavors/{flavor}/{locale}.lproj/`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 5-1 | Per-flavor, per-locale InfoPlist.strings are generated | `Flavors/dev/ko.lproj/InfoPlist.strings` etc. exist | PASS |
| 5-2 | Korean app name is correct | dev/ko contains the expected Korean name | PASS |
| 5-3 | Japanese app name is correct | dev/ja contains the expected Japanese name | PASS |
| 5-4 | CFBundleDisplayName is replaced with variable reference | `$(APP_DISPLAY_NAME)` found in Info.plist | PASS |
| 5-5 | copy_flavor_strings.sh script is generated | `ios/xcodegen/script/copy_flavor_strings.sh` exists | PASS |

---

### 6. Localized iOS Permission Descriptions

**Target path:** `setup_test/ios/Runner/{locale}.lproj/InfoPlist.strings`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 6-1 | en.lproj contains base permission descriptions | `NSCameraUsageDescription = "Camera access is required"` found | PASS |
| 6-2 | ko.lproj contains Korean permission descriptions | Korean camera permission string found | PASS |
| 6-3 | ja.lproj contains Japanese permission descriptions | Japanese camera permission string found | PASS |
| 6-4 | Podfile contains permission_handler macros | `PERMISSION_CAMERA=1`, `PERMISSION_PHOTOS=1` found | PASS |

---

### 7. Firebase Integration

**Target:** `setup_test/` project

> **Note:** Firebase tests require the `flutterfire` CLI to be installed and Firebase project access.

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 7-1 | Android: per-flavor google-services.json is downloaded | `android/app/src/dev/google-services.json` exists | PASS |
| 7-2 | iOS: per-flavor GoogleService-Info.plist is downloaded | `ios/Runner/Firebase/dev/GoogleService-Info.plist` exists | PASS |
| 7-3 | `lib/firebase_options_dev.dart` is generated | File exists and is importable | PASS |
| 7-4 | Unified `lib/firebase_options.dart` router is generated | Contains dev/prod branching logic | PASS |
| 7-5 | copy_firebase_plist.sh script is generated | `ios/xcodegen/script/copy_firebase_plist.sh` exists | PASS |
| 7-6 | Firebase step is skipped when no firebase config | No error when firebase section is removed | PASS |

---

### 8. Podfile Modification

**Target file:** `setup_test/ios/Podfile`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 8-1 | Per-flavor build mode mappings are added | `Debug-dev => :debug`, `Release-dev => :release` etc. found | PASS |
| 8-2 | permission_handler GCC macros are added | `GCC_PREPROCESSOR_DEFINITIONS` block found | PASS |
| 8-3 | No duplicate mappings on second run (idempotency) | Each mapping appears exactly once | PASS |

---

### 9. CI/CD Pipeline Generation

**Target paths:** `setup_test/ci_cd/ios/fastlane/`, `setup_test/.github/workflows/`

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 9-1 | `.env` file is generated | File exists with TEAM_ID etc. placeholders | PASS |
| 9-2 | `Gemfile` is generated | Contains fastlane gem | PASS |
| 9-3 | `Appfile` references team_id | Contains ENV reference | PASS |
| 9-4 | `Matchfile` contains all bundle_ids | Both `studio.etch.test.dev` and `studio.etch.test` present | PASS |
| 9-5 | `Fastfile` contains all required lanes | sync_certs, beta, register lanes found | PASS |
| 9-6 | `ios-deploy.yml` is generated | File exists | PASS |
| 9-7 | Workflow has flavor selection options | `workflow_dispatch` inputs contain dev, prod | PASS |
| 9-8 | No duplicates on second run (idempotency) | File content is identical | PASS |

---

### 10. App Store Metadata

> **Note:** `easy_setup.yaml` does not include a `metadata` section by default. Must be added for testing.

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 10-1 | Metadata directory structure is created | `ci_cd/ios/fastlane/metadata/ko/` etc. exist | PASS |
| 10-2 | Per-locale text files are generated | `name.txt`, `description.txt` etc. exist | PASS |
| 10-3 | File content matches YAML configuration | Compare file contents | PASS |
| 10-4 | Fastfile includes update_metadata lane | Lane exists | PASS |
| 10-5 | Step is skipped when metadata is not configured | No error when running without metadata | PASS |

---

### 11. Dry-Run Mode

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 11-1 | `flavor --dry-run` does not modify files | No git diff | PASS |
| 11-2 | `ci-cd --dry-run` does not modify files | No git diff | PASS |
| 11-3 | Dry-run logs show planned operations | stdout contains planned changes | PASS |

---

### 12. Error Handling

| # | Test | Verification | Result |
|---|------|-------------|--------|
| 12-1 | Error when specifying a non-Flutter project path | `Could not find a Flutter project root` message | PASS |
| 12-2 | Error when `easy_setup.yaml` is missing | Clear error message output | PASS |
| 12-3 | Error when required YAML fields are missing | Run without `bundle_id` or `name` | PASS |
| 12-4 | Error on malformed YAML format | Parse error message confirmed | PASS |

---

## Recommended Test Execution Order

Run tests in this order. Some steps produce outputs that subsequent steps depend on.

```
1. Dry-run tests (#11) - safely verify without file changes
2. Android flavor (#1) - independent, run first
3. iOS xcconfig (#3) -> XcodeGen (#2) -> App icons (#4) - iOS base setup
4. Localized app names (#5) + Localized permissions (#6)
5. Podfile (#8) - includes permission macros
6. Firebase (#7) - must run after xcodegen
7. CI/CD (#9) + Metadata (#10) - separate command
8. Error handling (#12) - abnormal cases last
```

---

## Test Command Reference

```bash
# Unit tests (177 tests)
dart test --reporter expanded

# Flavor integration test
dart run bin/easy_setup.dart flavor -p setup_test

# Flavor dry-run
dart run bin/easy_setup.dart flavor -p setup_test --dry-run

# CI/CD integration test
dart run bin/easy_setup.dart ci-cd -p setup_test

# Idempotency test (run twice, check diff)
dart run bin/easy_setup.dart flavor -p setup_test
dart run bin/easy_setup.dart flavor -p setup_test
git diff setup_test/

# Error case tests
dart run bin/easy_setup.dart flavor -p /tmp           # Non-Flutter project path
dart run bin/easy_setup.dart flavor -p nonexistent     # Nonexistent path
```
