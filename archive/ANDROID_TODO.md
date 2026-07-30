# Android - Missing Features (iOS Parity)

Features currently implemented for iOS but not yet available for Android.

---

## 1. App Icon Auto-Generation

**iOS:** Generates 15 icon sizes from a single 1024x1024 source image per flavor (`AppIcon-{flavor}.appiconset`).

**Android gap:** No automatic icon generation. Users must manually create `mipmap-*` directories with all required density variants.

**What to implement:**
- Read `app_icon` from flavor config (same YAML field as iOS)
- Generate adaptive icon resources from 1024x1024 source:
  - `mipmap-mdpi` (48x48)
  - `mipmap-hdpi` (72x72)
  - `mipmap-xhdpi` (96x96)
  - `mipmap-xxhdpi` (144x144)
  - `mipmap-xxxhdpi` (192x192)
- Generate `ic_launcher.xml` (adaptive icon with foreground/background layers)
- Generate `ic_launcher_round.xml` (round variant)
- Output to `android/app/src/{flavor}/res/mipmap-*/`
- Generate or update `Contents.json` equivalent (`ic_launcher.xml`)

**Complexity:** Medium. Image resizing logic already exists in `AppIconGenerator`. Need to add Android-specific sizes and adaptive icon XML templates.

---

## 2. Localized App Names

**iOS:** Generates `InfoPlist.strings` per flavor per locale with `CFBundleDisplayName`. Build script copies the correct flavor's strings at build time.

**Android gap:** No automatic localized app name generation. Users must manually create `strings.xml` files in `values-{locale}/` directories.

**What to implement:**
- Read `localized.{locale}.app_name` from flavor config (same YAML field as iOS)
- Generate per-flavor, per-locale `strings.xml`:
  - `android/app/src/{flavor}/res/values/strings.xml` (default)
  - `android/app/src/{flavor}/res/values-ko/strings.xml`
  - `android/app/src/{flavor}/res/values-ja/strings.xml`
- Each file contains: `<string name="app_name">{localized name}</string>`
- Update `AndroidManifest.xml` to use `@string/app_name` for `android:label` (if not already)

**Complexity:** Low. Straightforward XML template generation. No external tools required.

---

## 3. CI/CD Pipeline (Google Play)

**iOS:** Generates Fastlane files (Gemfile, Matchfile, Appfile, Fastfile with sync_certs/beta/register lanes) + GitHub Actions workflow for TestFlight deployment.

**Android gap:** No CI/CD pipeline generation for Android. Users must manually set up Fastlane for Google Play or write custom workflows.

**What to implement:**
- Generate Fastlane files in `ci_cd/android/fastlane/`:
  - `Gemfile` - Ruby dependencies
  - `Appfile` - Google Play credentials (json_key_file, package_name)
  - `Fastfile` - Lanes:
    - `build` - Build AAB per flavor
    - `deploy_internal` - Upload to Google Play internal testing
    - `deploy_beta` - Upload to Google Play open testing
    - `promote` - Promote internal -> production
- Generate `.env` for credentials:
  - `GOOGLE_PLAY_JSON_KEY_PATH` - Service account key file
  - `KEYSTORE_PATH`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`
- Generate GitHub Actions workflow (`android-deploy.yml`):
  - workflow_dispatch with flavor selection
  - Flutter build -> AAB signing -> Fastlane upload
- Handle signing: keystore setup for release builds

**Complexity:** High. Google Play API authentication differs from App Store Connect. Need to handle AAB signing, service account keys, and track management.

---

## 4. Google Play Metadata

**iOS:** Generates `ci_cd/ios/fastlane/metadata/{locale}/` text files (name, description, keywords, etc.) and provides `update_metadata` lane.

**Android gap:** No metadata file generation for Google Play.

**What to implement:**
- Generate metadata files in `ci_cd/android/fastlane/metadata/android/{locale}/`:
  - `title.txt` - App name (max 30 chars)
  - `short_description.txt` - Short description (max 80 chars)
  - `full_description.txt` - Full description (max 4000 chars)
  - `changelogs/{version_code}.txt` - Release notes
- Generate `update_metadata` lane in Android Fastfile
- Use same YAML `metadata` section with platform-specific field mapping:

```yaml
metadata:
  ko:
    name: My App          # -> title.txt
    description: "..."    # -> full_description.txt
    subtitle: "..."       # -> short_description.txt (iOS subtitle -> Android short desc)
    release_notes: "..."  # -> changelogs/{version_code}.txt
```

**Complexity:** Low. Same pattern as iOS metadata generation with different directory structure and field names.

---

## 5. Permission Descriptions

**iOS:** Generates per-locale permission description strings in `InfoPlist.strings` and auto-maps `permission_handler` GCC macros in Podfile.

**Android gap:** Android handles permissions differently (runtime permissions via `AndroidManifest.xml`). No automatic configuration.

**What to implement (if applicable):**
- This is a lower priority since Android permissions work differently:
  - `AndroidManifest.xml` declares permissions (already handled by packages)
  - Runtime permission dialogs use system defaults, not custom strings
  - Custom rationale dialogs are app-level UI, not build-level config
- Possible scope: auto-add `<uses-permission>` entries to `AndroidManifest.xml` based on the same `permission` YAML section
- Auto-configure ProGuard rules for permission-related packages

**Complexity:** Low, but questionable value. Android permission strings are not configurable at the build level like iOS.

---

## Priority Recommendation

| # | Feature | Complexity | Impact | Priority |
|---|---------|-----------|--------|----------|
| 1 | Localized app names | Low | High | P1 |
| 2 | App icon auto-generation | Medium | High | P1 |
| 3 | Google Play metadata | Low | Medium | P2 |
| 4 | CI/CD pipeline | High | High | P2 |
| 5 | Permission descriptions | Low | Low | P3 |

**P1** items (localized names + icons) share the same YAML config as iOS and are straightforward to implement. They provide immediate value for any multi-flavor project.

**P2** items (metadata + CI/CD) complete the deployment story. Metadata is easy; CI/CD is complex due to Google Play authentication.

**P3** (permissions) has limited value since Android permissions don't work the same way as iOS.
