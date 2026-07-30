# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **⚠️ v2 재구축 결정 (2026-07-30): 먼저 `V2_PLAN.md`를 읽을 것.**
> v0.0.2는 만들다 중단됐고, Setup Kit + Deploy Kit 범용 툴킷으로 처음부터
> 재구축한다. 아래 내용은 v1 코드 기준이며 현재 코드와도 일부 불일치한다
> (pbxproj 직접 조작 → XcodeGen으로 이미 전환됨). v1 모듈별 재사용 여부는
> V2_PLAN.md §8 참고.

## Overview

**easy_setup** is a Dart CLI tool that automates Flutter project setup by reading a single `easy_setup.yaml` configuration file and applying complex changes across Android and iOS platforms, plus generating CI/CD pipelines.

Two main commands:
- `flavor` (default) — Configures Android build.gradle + iOS xcconfig/pbxproj/schemes/Info.plist/Podfile
- `ci-cd` — Generates Fastlane files + GitHub Actions workflows

## Common Commands

### Development
```bash
# Run linter and analyzer
dart analyze lib/ test/

# Run all tests
dart test --reporter expanded

# Run specific test file
dart test test/ios/pbxproj_modifier_test.dart

# Run test matching pattern
dart test --name "parses valid map"

# Run the CLI locally (from project root)
dart run bin/easy_setup.dart flavor --dry-run
dart run bin/easy_setup.dart ci-cd --dry-run

# Compile to native binary
dart compile exe bin/easy_setup.dart -o easy_setup
```

### Testing-specific
```bash
# Run tests with verbose output
dart test -v

# Run a single test group
dart test test/models/flavor_config_test.dart -p flavor

# Watch for file changes and re-run tests
dart test --watch

# Run tests with coverage (requires coverage package)
dart pub global activate coverage
dart run coverage:test_with_coverage
```

## High-Level Architecture

### Dual-Command Orchestration Pattern

```
bin/easy_setup.dart
├── Parses CLI args (--help, --dry-run, --project-root)
├── Routes to either FlavorCommand or CiCdCommand
└── Catches SetupException for user-friendly error messages

FlavorCommand.run()  (lib/src/commands/flavor_command.dart)
├── 1. Find Flutter project root (ProjectFinder.findFlutterRoot)
├── 2. Load & parse easy_setup.yaml (EasySetupConfig.fromFile)
├── 3. Android: modify build.gradle (BuildGradleModifier)
├── 3.5. Android: copy Firebase configs (FirebaseCopier)
├── 4. iOS: generate xcconfig files (XcconfigGenerator)
├── 4.5. iOS: copy Firebase configs (FirebaseCopier)
├── 5. iOS: modify project.pbxproj (PbxprojModifier) ← returns runner target UUID
├── 6. iOS: generate xcscheme files (SchemeGenerator)
├── 7. iOS: modify Info.plist (InfoPlistModifier)
└── 8. iOS: modify Podfile (PodfileModifier)

CiCdCommand.run()  (lib/src/commands/ci_cd_command.dart)
├── 1. Find Flutter project root
├── 2. Load & parse easy_setup.yaml (ci_cd section)
├── 3. Resolve CI/CD flavors (ci_cd.flavors overrides → fallback to easy_setup.flavors)
├── 4-7. Generate Fastlane files (Gemfile, Matchfile, Appfile, Fastfile)
└── 8. Generate GitHub Actions workflow (ios-deploy.yml)
```

Each modifier/generator is **idempotent** — running multiple times doesn't create duplicates.

### Key Patterns

**1. Pipeline Orchestration**
Commands execute modifiers in strict order (some steps depend on previous ones). FlavorCommand returns the Runner target UUID from pbxproj modification, which SchemeGenerator needs.

**2. Modifier Pattern**
All modifiers (BuildGradleModifier, PbxprojModifier, etc.) follow:
- Check if already applied (idempotency guard)
- Parse text file to find insertion/modification points
- Apply changes
- Write if not dry-run

**3. Config Models with Factory Constructors**
- `FlavorConfig`, `EasySetupConfig`, `CiCdConfig` parse YAML into structured models
- Optional fields handled gracefully
- Factory constructors use `fromYaml(Map)` pattern

**4. Project Finder Utilities**
`ProjectFinder` provides:
- `findFlutterRoot()` — walks up directory tree checking for `pubspec.yaml` with `sdk: flutter`
- Standard path helpers: `androidBuildGradlePath()`, `iosPbxprojPath()`, `iosXcconfigDir()`, etc.

## Complex Components

### pbxproj_modifier.dart — The Most Complex File

The Xcode `project.pbxproj` file is a hand-written property list with 6 sections:
1. **PBXFileReference** — file/folder references
2. **PBXGroup** — folder structures
3. **PBXNativeTarget** — build targets (usually "Runner")
4. **XCBuildConfiguration** — build configurations (Debug, Release, Profile)
5. **XCConfigurationList** — maps targets/projects to their configurations
6. **PBXProject** — root project metadata

**Strategy: Clone-Based Approach**

Rather than using hardcoded templates, the modifier **clones** existing build configurations:
- Find existing `Debug` (for new Debug-{flavor}), `Release` (for Release-{flavor}), `Profile` (for Profile-{flavor})
- Deep-copy the entire block, preserving all Xcode-version-specific keys
- Update UUIDs and configuration names
- Insert at appropriate locations

This handles Xcode version differences automatically.

**Runner Target vs Project Level**

Both must be updated:
- **PBXNativeTarget** section: maps Runner target → its XCConfigurationList → its XCBuildConfigurations
- **PBXProject** section: maps Project (root) → its XCConfigurationList → its XCBuildConfigurations

Schemas reference the Runner target UUID, but the project-level configs are also needed for consistency.

### build_gradle_modifier.dart — Brace-Counting Parser

Gradle files (Groovy DSL or Kotlin DSL) use nested `{}` blocks. The modifier:
- Finds the `buildTypes` block by searching for the closing brace
- Uses `_findBlockEnd()` which counts brace depth to find the true closing brace (not a nested one)
- Inserts `flavorDimensions` + `productFlavors` after `buildTypes` closes

This avoids regex-based parsing which would fail on nested structures.

### Dry-Run Mode

All generators/modifiers accept a `dryRun` parameter. When true:
- Modifications are simulated and logged
- No files are written
- Allows users to preview changes before applying

## Key Design Decisions

1. **Idempotency Guards Everywhere**
   - Every modifier checks if the change already exists before applying
   - Users can run the command multiple times without issues
   - Guards vary: text search in build.gradle, UUID-based checks in pbxproj, file existence for xcconfig

2. **Clone vs Template for pbxproj**
   - Cloning existing blocks preserves Xcode-generated metadata that changes between versions
   - Templates would break with newer/older Xcode versions

3. **Profile xcconfig Includes Release**
   - `Profile-{flavor}.xcconfig` includes `Release.xcconfig`, not a standalone config
   - Matches Flutter's build system conventions

4. **Flavor Resolution in CI/CD**
   - `ci_cd.flavors` (if present) overrides `easy_setup.flavors`
   - Allows picking specific flavors for CI/CD without modifying the main flavor list
   - Falls back gracefully

5. **UUID Generation**
   - 24-character hex UUIDs matching Xcode format
   - Generated deterministically where needed (though most use cloning to preserve existing UUIDs)

## Test Structure

Tests follow standard patterns:
- `test/` directory mirrors `lib/src/` structure
- Use `package:test` framework
- Test files use `group()` for organizing related tests
- Tests validate both happy paths and error conditions
- Modifiers tested with mock file content, not real project directories

Key test files:
- `flavor_config_test.dart` — YAML parsing
- `pbxproj_modifier_test.dart` — largest test file, covers 6 sections and idempotency
- `build_gradle_modifier_test.dart` — brace-counting and Groovy/Kotlin DSL handling
- `xcconfig_generator_test.dart` — file content generation

## Configuration Files

### easy_setup.yaml Format
```yaml
easy_setup:
  flavors:
    {flavor_name}:
      bundle_id: {reverse-domain-style identifier}
      name: {display name}
      # Optional:
      version_code: {integer}
      version_name: {string}
      signing: {android signing config}
      firebase: {file paths for google-services.json / GoogleService-Info.plist}
      ios: {team_id, provisioning_profile, code_sign_identity, entitlements, app_icon}

  ci_cd:  # Optional
    flavors:  # Optional — defaults to all easy_setup.flavors
      {flavor_name}:
        bundle_id: {override if different}
    ios:
      storage: {git repo URL for certs}
      team_id: {Apple Team ID}
      itc_team_id: {App Store Connect Team ID}
      api_key:
        id: {API Key ID}
        issuer_id: {API Key Issuer ID}
        key_path: {path to .p8 file}
        duration: {seconds, optional}
        in_house: {bool, optional}
```

## Dependencies

- `args: ^2.7.0` — CLI argument parsing
- `yaml: ^3.1.3` — YAML parsing
- `path: ^1.9.0` — path manipulation (direct dependency)

## Common Pitfalls & Debugging

1. **"Could not find a Flutter project root"**
   - Ensure `pubspec.yaml` exists with `sdk: flutter`
   - Or use `--project-root` flag

2. **pbxproj Modifications Not Appearing**
   - Check if idempotency guard triggered (configuration name already exists)
   - Verify Runner target UUID is being found correctly
   - Check both PBXNativeTarget and PBXProject sections were modified

3. **Test Failures in pbxproj Tests**
   - pbxproj test fixtures are sensitive to whitespace/formatting
   - When updating fixtures, preserve exact spacing in section markers (/* ... */)

4. **Android Gradle Not Parsing**
   - Ensure `buildTypes` block exists (Flutter projects have it by default)
   - Brace-counting may fail if Groovy strings contain unmatched braces (rare)

5. **CI/CD Flavor Mismatch**
   - If `ci_cd.flavors` is set, it must reference flavors that exist in `easy_setup.flavors` (or provide bundle_id override)
   - If empty, defaults to all flavors from easy_setup

## File Structure at a Glance

```
bin/
  easy_setup.dart                    # CLI entry, command routing

lib/src/
  easy_setup_base.dart               # (legacy, minimal use)
  exceptions.dart                    # SetupException class

  commands/
    flavor_command.dart              # Orchestrates 8-step flavor setup
    ci_cd_command.dart               # Orchestrates Fastlane + GitHub Actions

  models/
    flavor_config.dart               # FlavorConfig, EasySetupConfig, Firebase/Signing
    ci_cd_config.dart                # CiCdConfig, CiCdIosConfig, ApiKeyConfig

  utils/
    project_finder.dart              # Flutter root detection, standard paths
    uuid_generator.dart              # 24-char Xcode-style UUID

  android/
    build_gradle_modifier.dart       # Groovy/Kotlin DSL, brace-counting

  ios/
    pbxproj_modifier.dart            # Clone-based 6-section modification
    xcconfig_generator.dart          # Debug/Release/Profile per flavor
    scheme_generator.dart            # .xcscheme XML with runner UUID
    info_plist_modifier.dart         # CFBundleDisplayName → $(APP_DISPLAY_NAME)
    podfile_modifier.dart            # Build mode mapping for CocoaPods

  fastlane/
    gemfile_generator.dart           # Ruby dependencies
    matchfile_generator.dart         # Cert/profile storage config
    appfile_generator.dart           # Team IDs & bundle IDs
    fastfile_generator.dart          # Build & TestFlight upload

  github/
    workflow_generator.dart          # GitHub Actions ios-deploy.yml

  firebase/
    firebase_copier.dart             # Copies google-services.json & GoogleService-Info.plist

test/
  (mirrors lib/src structure)        # Unit tests for all modules
```

## When Adding Features

- **New modifier/generator**: Follow the pattern — idempotency guard + parse + apply + write
- **New YAML config option**: Add to model factory constructor, validate in command
- **New CLI flag**: Add to ArgParser in bin/easy_setup.dart, pass through commands
- **Platform-specific logic**: Check ProjectFinder for standard paths, handle gracefully if missing
- **Testing**: Test idempotency (run twice, should be identical), test error cases
