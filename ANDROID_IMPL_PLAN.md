# Android Feature Parity Plan (Features 1-4)

## Context

The easy_setup CLI has full iOS feature support but Android only has `BuildGradleModifier` for flavor setup. This plan adds 4 Android features to reach parity: localized app names, app icons, CI/CD pipeline, and Google Play metadata.

## Phase 1: Models & Utilities (no command changes)

### 1a. Add Android path helpers to `project_finder.dart`

```dart
static String androidFlavorResDir(String root, String flavor)
  // → {root}/android/app/src/{flavor}/res

static String androidAppSrcDir(String root)
  // → {root}/android/app/src
```

### 1b. Add `toAndroidFileMap()` to `LocaleMetadataConfig` in `ci_cd_config.dart`

Maps existing YAML fields to Google Play filenames:
| YAML field | Android file |
|-----------|-------------|
| `name` | `title.txt` |
| `subtitle` | `short_description.txt` |
| `description` | `full_description.txt` |
| `release_notes` | `changelogs/default.txt` |

Other iOS-only fields (keywords, promotional_text, URLs) are skipped for Android.

---

## Phase 2: Feature 1 + 2 (FlavorCommand scope)

### Feature 1: Android Localized App Names

**New file:** `lib/src/android/strings_xml_generator.dart`

```dart
class AndroidStringsXmlGenerator {
  static void generate(String projectRoot, String flavor, FlavorConfig config, {bool dryRun = false})
  static void cleanupUnusedFlavors(String projectRoot, Set<String> activeFlavors, {bool dryRun = false})
}
```

**Output:**
```
android/app/src/{flavor}/res/values/strings.xml            → <string name="app_name">{name}</string>
android/app/src/{flavor}/res/values-ko/strings.xml         → <string name="app_name">{ko app_name}</string>
android/app/src/{flavor}/res/values-ja/strings.xml         → <string name="app_name">{ja app_name}</string>
```

**Note:** Keep existing `resValue` in build.gradle (no breaking change). Android resource merging gives flavor source set `strings.xml` precedence over `resValue`.

**Test:** `test/android/strings_xml_generator_test.dart` — default name, localized variants, cleanup unused, dry-run, idempotency.

### Feature 2: Android App Icon Generation

**New file:** `lib/src/android/android_app_icon_generator.dart`

```dart
class AndroidAppIconGenerator {
  static void generate(String projectRoot, String flavor, String appIconPath, {bool dryRun = false})
  static void cleanupUnusedAppIcons(String projectRoot, Set<String> activeFlavorsWithIcon, {bool dryRun = false})
}
```

**Sizes:** mdpi (48), hdpi (72), xhdpi (96), xxhdpi (144), xxxhdpi (192), Play Store (512)

**Output:**
```
android/app/src/{flavor}/res/mipmap-mdpi/ic_launcher.png      (48x48)
android/app/src/{flavor}/res/mipmap-hdpi/ic_launcher.png      (72x72)
android/app/src/{flavor}/res/mipmap-xhdpi/ic_launcher.png     (96x96)
android/app/src/{flavor}/res/mipmap-xxhdpi/ic_launcher.png    (144x144)
android/app/src/{flavor}/res/mipmap-xxxhdpi/ic_launcher.png   (192x192)
android/app/src/{flavor}/playstore-icon.png                    (512x512)
```

**Test:** `test/android/android_app_icon_generator_test.dart` — 6 sizes correct, missing source error, dry-run, cleanup, idempotency.

### Wire into FlavorCommand

Update step count from 11 to 14. Insert after step 1 (Android build.gradle):

```
[1/14] Android build.gradle           (existing)
[2/14] Android strings.xml            (NEW)
[3/14] Android App Icons              (NEW)
[4/14] iOS xcconfig                   (was 2)
...                                   (renumber remaining)
[13/14] iOS Podfile                   (was 10)
[14/14] .gitignore                    (was 11, add Android entries)
```

---

## Phase 3: Feature 3 + 4 (CiCdCommand scope)

### Feature 3: Android CI/CD Pipeline

**New files:**

| File | Class | Purpose |
|------|-------|---------|
| `lib/src/fastlane/android_dotenv_generator.dart` | `AndroidDotenvGenerator` | `.env` with GOOGLE_PLAY_JSON_KEY, KEYSTORE_* vars |
| `lib/src/fastlane/android_appfile_generator.dart` | `AndroidAppfileGenerator` | `Appfile` with package_name, json_key_file |
| `lib/src/fastlane/android_fastfile_generator.dart` | `AndroidFastfileGenerator` | `Fastfile` with build/deploy_internal/deploy_beta lanes |
| `lib/src/github/android_workflow_generator.dart` | `AndroidWorkflowGenerator` | `.github/workflows/android-deploy.yml` |

**Reuse:** `GemfileGenerator` for `ci_cd/android/fastlane/Gemfile` (identical content).

**Fastfile lanes:**
- `build` — `flutter build appbundle --flavor {flavor} --release`
- `deploy_internal` ��� build + `upload_to_play_store(track: 'internal')`
- `deploy_beta` — build + `upload_to_play_store(track: 'beta')`

**Workflow:** `runs-on: ubuntu-latest`, Java 17, Flutter, Ruby, decode keystore from secret, fastlane deploy.

**GitHub Secrets:**
- `GOOGLE_PLAY_JSON_KEY_BASE64` — Service account key
- `KEYSTORE_BASE64` — Keystore file
- `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`

### Feature 4: Google Play Metadata

**New file:** `lib/src/fastlane/android_metadata_generator.dart`

```dart
class AndroidMetadataGenerator {
  static void generate(String outputDir, Map<String, LocaleMetadataConfig> metadata, {bool dryRun = false})
}
```

**Output:**
```
ci_cd/android/fastlane/metadata/android/{locale}/
  title.txt
  short_description.txt
  full_description.txt
  changelogs/default.txt
```

### Wire into CiCdCommand

Add Android steps after iOS steps:

```
Steps 1-3: unchanged (root, config, flavors)
Steps 4-7: iOS fastlane (unchanged)
Step 8:    Android fastlane (NEW - .env, Gemfile, Appfile, Fastfile)
Step 9:    Android bundle install (NEW)
Step 10:   Android metadata (NEW, if metadata configured)
Step 11:   GitHub Actions iOS workflow (existing)
Step 12:   GitHub Actions Android workflow (NEW)
```

---

## Phase 4: Final Wiring

- `lib/easy_setup.dart` — add exports for new Android generators
- Update `.gitignore` template in `flavor_command.dart._updateGitignore` to include Android entries

---

## New Files (7)

| File | Feature |
|------|---------|
| `lib/src/android/strings_xml_generator.dart` | 1 |
| `lib/src/android/android_app_icon_generator.dart` | 2 |
| `lib/src/fastlane/android_dotenv_generator.dart` | 3 |
| `lib/src/fastlane/android_appfile_generator.dart` | 3 |
| `lib/src/fastlane/android_fastfile_generator.dart` | 3 |
| `lib/src/fastlane/android_metadata_generator.dart` | 4 |
| `lib/src/github/android_workflow_generator.dart` | 3 |

## Modified Files (6)

| File | Change |
|------|--------|
| `lib/src/utils/project_finder.dart` | Add Android path helpers |
| `lib/src/models/ci_cd_config.dart` | Add `toAndroidFileMap()` |
| `lib/src/commands/flavor_command.dart` | Add steps 2-3, renumber to 14 steps, update gitignore |
| `lib/src/commands/ci_cd_command.dart` | Add Android fastlane + metadata + workflow steps |
| `lib/easy_setup.dart` | Export new classes |
| `archive/ANDROID_TODO.md` | Mark features 1-4 as implemented |

## New Test Files (7)

| File | Tests |
|------|-------|
| `test/android/strings_xml_generator_test.dart` | default name, localized, cleanup, dry-run, idempotency |
| `test/android/android_app_icon_generator_test.dart` | 6 sizes, missing source, dry-run, cleanup, idempotency |
| `test/fastlane/android_dotenv_generator_test.dart` | .env content, dry-run |
| `test/fastlane/android_appfile_generator_test.dart` | Appfile content |
| `test/fastlane/android_fastfile_generator_test.dart` | lanes, addMetadataLane, idempotency |
| `test/fastlane/android_metadata_generator_test.dart` | field mapping, locale dirs, dry-run |
| `test/github/android_workflow_generator_test.dart` | YAML content, flavor options |

---

## Verification

```bash
# Analyze
dart analyze lib/ test/

# Run all tests (expect ~210+ total)
dart test --reporter expanded

# Integration test
dart run bin/easy_setup.dart flavor -p setup_test
dart run bin/easy_setup.dart ci-cd -p setup_test

# Verify Android outputs
ls setup_test/android/app/src/dev/res/values/strings.xml
ls setup_test/android/app/src/dev/res/mipmap-xxhdpi/ic_launcher.png
ls setup_test/ci_cd/android/fastlane/Fastfile
ls setup_test/.github/workflows/android-deploy.yml

# Codex review
codex exec "Review git diff for Android feature parity changes" -s read-only
```
