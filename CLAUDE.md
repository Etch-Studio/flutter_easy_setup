# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## Overview

**easy_setup** is a Dart CLI that takes a Flutter app from "code exists" to
"live in both stores" from one `easy_setup.yaml`, **without opening a web
console**. Two halves:

- **Setup Kit** — provisioning (Sentry, Firebase, AdMob), native config
  (entitlements, background modes, ad IDs), store assets (app icon,
  screenshots, promo site), and store listings.
- **Deploy Kit** — code signing via fastlane match, builds, and uploads to
  TestFlight and Play.

`V2_PLAN.md` is the design document and the source of truth for scope and
open questions. Read it before starting anything structural. `docs/sentry.md`,
`docs/amplitude.md`, `docs/admob.md` and `docs/ios-signing.md` are the
user-facing guides — keep them in step when behaviour or error messages
change.

## Commands

| Command | What it does |
|---|---|
| `init` | Write a v2 `easy_setup.yaml` template + asset folder skeleton |
| `doctor` | Verify tools, keys and secrets, with issuance guidance |
| `setup` | Apply the declared state; every step is idempotent |
| `capture` | Tour the app on an iOS simulator, save raw store screenshots |
| `certs` | iOS signing for local builds: match (development/adhoc/appstore) + the Xcode project |
| `deploy` | Build and upload (iOS TestFlight / Play track) |
| `flavor` | **v1**, still on the old `easy_setup:` root-key schema |
| `ci-cd` | **v1**, superseded by the reusable workflows |

Global flags: `--dry-run` / `-n`, `--project-root` / `-p`.

`setup` runs its steps in this order, and the order matters — `site` writes
the support/marketing/privacy URLs that `store` then uploads, and
`screenshots` fills `fastlane/screenshots/` that `store` uploads with
`deliver --overwrite_screenshots`:

```
sentry → amplitude → firebase → admob → ios_capabilities → branding →
screenshots → site → store
```

`--only <step>` runs one of them. It takes a single value.

## Development

```bash
dart analyze lib bin test        # must be clean
dart test --reporter compact     # 651 tests
dart test test/setup/screenshots_step_test.dart
dart run bin/easy_setup.dart setup --dry-run
dart compile exe bin/easy_setup.dart -o easy_setup
```

Run a Codex review after code changes (see the project memory), and update
this file and `README.md` when behaviour changes.

## Architecture

### The step pattern

Every Setup Kit unit is a `SetupStep` (`lib/src/setup/setup_step.dart`):
`name`, `isConfigured(config)`, `isActive(context)`, `configurationHint`,
`run(context)`. `SetupContext` carries the project root, the parsed config,
the environment, and **injectable** collaborators — `ProcessRunner`,
`HttpJsonClient`, `HtmlRenderer` — which is what makes the steps testable
without a shell, a network or a browser.

Steps must be idempotent: run twice, get the same tree.

### Who owns which file

This is the central idea and it decides how everything is written:

| Kind | Writer | Examples |
|---|---|---|
| **Design source** — the user or an AI skill owns it | `writeIfAbsent` (seed once, never clobber) | `icon.svg`, `template.html`, `screenshots.yaml`, the tour, `site/*.html` |
| **User-owned config** — the developer owns it | line-based edits only (`PubspecText`, `EnvJsonWriter`) | `pubspec.yaml`, `env.json`, `env.prod.json` |
| **Protocol/derived** — easy_setup owns it | `writeIfChanged` (rewrite every run) | the capture harness, the drive driver, `SITE_BRIEF.md` |
| **Output** — regenerated from sources | `writeBytesIfChanged` + pruning | `AppIcon.appiconset`, `mipmap-*`, `fastlane/screenshots/` |

Nothing in the build path calls an AI. The AI only ever edits design
sources, so `setup` stays deterministic and re-runnable.

### Store assets: text sources → headless Chrome → exact pixels

`lib/src/render/html_renderer.dart` renders an HTML page to a pixel-exact
bitmap by driving an installed Chrome through its command-line screenshot
mode — no Node, no npm, no browser download.

- App icon: `icon.svg` → 1024×1024 → 15 iOS sizes + 5 Android densities.
- Screenshots: `template.html` + `screenshots.yaml` + a raw capture →
  1320×2868 / 2064×2752 / 1080×1920.

The Dart↔template contract is one rule: `{{PLACEHOLDER}}`. Text fields in
`screenshots.yaml` become `{{TITLE}}`-style names, palette entries become
`{{C_BG}}`-style ones. A new palette key is a new placeholder with no Dart
change.

Renders are fingerprinted into the output PNG's `tEXt` chunk, so an
unchanged screen costs a header read instead of a browser launch.

### Integrations: no console after the first credential

Three steps exist to keep provisioning out of the browser, and each one hits
a different ceiling in the vendor's API:

| Step | Fully automated | Console, once |
|---|---|---|
| `sentry` | project creation, DSN, pubspec `sentry:` block, symbol upload wiring | one API token (`SENTRY_API_TOKEN`) |
| `amplitude` ([guide](docs/amplitude.md)) | key verification, env.json/env.prod.json injection, SDK dependency | the project itself — **no project-creation API exists** |
| `admob` ([guide](docs/admob.md)) | app + ad unit *lookup* (generally available), creation when the account has access | app/ad unit creation for accounts without it (403) |

Consequences worth remembering: keys never get pasted into a tracked file
(they arrive as environment variables and land in env.json / env.prod.json),
and `admob` treats easy_setup.yaml as intent — an ad unit is declared by name
and `type`, and the IDs are resolved per run unless they are pinned in the
yaml. `admob.auto: false` keeps the step offline.

### Screenshot capture (layer ①)

`capture` boots the simulator for each device key, freezes the status bar,
and runs an `integration_test` tour. The tour writes a screen name into the
app's tmp directory; the CLI watches for it, captures with
`xcrun simctl io screenshot`, and answers with a done marker.

### Deploy

Thin, honest wrapping of fastlane: `match` → `update_code_signing_settings`
→ build → `pilot`/`supply`, plus `deliver` for metadata. Auth is always an
App Store Connect API key (ES256 JWT), never an Apple ID session — that is
why `fastlane produce` is not used.

## Things that cost real time to learn

Do not "simplify" these without reading the reason:

- **Chrome writes the screenshot and then keeps running** (151+). The
  renderer waits on the *file*, accepts it only once its IEND chunk lands,
  then kills the browser. A private `--user-data-dir` is mandatory or
  Chrome attaches to the developer's open instance and never shoots.
- **`IntegrationTestWidgetsFlutterBinding.takeScreenshot` is unreliable**
  under Impeller/Metal — a whole run can come back as the splash screen.
  Hence the marker-file handshake through simctl.
- **The capture watcher must not clear markers** when it first resolves the
  app container (the tour may already have written one), and **must consume
  a request** after answering it (or the next `shot()`, which clears the
  done marker first, re-captures it against the wrong screen).
- **Icon SVGs render on a transparent backdrop** so the App Store alpha
  check can actually fire; alpha is rejected before the PNG is written.
- **Braces in a template's own comments are real placeholders.** Listing
  `{{C_ACCENT}}` in a comment silently made the palette mandatory.
- **`:empty` collapses decorative elements too** — scope it to text nodes.
- **`crop_bottom` is in raw-capture pixels**, not output pixels, so the
  right value depends on which simulator took the shot.
- **Store assets must not carry an alpha channel**, even fully opaque.
- **A distribution profile cannot install on a device.** That is why `certs`
  exists next to `deploy`: development covers Debug/Profile/Release so
  `flutter run` works, deploy narrows its own rewrite to Release, and both
  build their fastlane arguments from `deploy/ios_signing.dart` so the profile
  names (`match AdHoc`, not `match Adhoc`) cannot drift.
- **`deploy` rewrites the developer's Xcode project and must put it back.**
  `update_code_signing_settings` pins manual signing with the App Store
  profile because that is what `flutter build ipa` needs; an App Store profile
  cannot install on a device, so leaving it behind breaks `flutter run` on a
  phone and shows up as an unexplained pbxproj diff. `IosDeployer` snapshots
  the file and restores it in a `finally`.
- **A release build without `--dart-define-from-file` is the silent failure
  mode of the whole Setup Kit.** Every value the steps write lands in
  env.prod.json, and `String.fromEnvironment` yields `''` when the build does
  not pass the file — SDKs written to no-op on an empty key then report
  nothing, while the upload succeeds. Both deployers pass it (see
  `deploy/dart_define_file.dart`) and doctor warns when the file is absent.
- **Sentry answers two different problems with the same 403 on project
  creation**: the token may lack `project:write`, or the org may have turned
  off member project creation — which Sentry then wants `org:write` or
  `team:admin` for. The step names both, since the response alone does not
  say which.
- **A Sentry organization token cannot create a project.** Its scopes are
  fixed to CI tasks, so `setup` needs an internal-integration or personal
  token (`project:write` + `org:read`) in `SENTRY_API_TOKEN`, while symbol
  upload at build time wants exactly the organization token in
  `SENTRY_AUTH_TOKEN`. Two tokens, two jobs — doctor warns when the
  `sntrys_` prefix shows up in the wrong one.
- **app-ads.txt is read from the domain root, path dropped.** The crawler
  takes the developer website out of the store listing, keeps only the host,
  and fetches `/app-ads.txt` — so the file never belongs beside the app's own
  pages, and on GitHub Pages only a `<owner>.github.io` repository serves
  that root. `AppAdsTxtCheck` mirrors that: host from `site.base_url`,
  publisher from `admob.publisher_id` or the app ID already in Info.plist /
  AndroidManifest.xml — read from the key that holds it, since a project that
  changed apps has the old ID sitting in a comment. A record has to name
  google.com *and* the publisher *and* a relationship: matching the publisher
  alone would accept a file that only authorizes a mediation partner. It
  warns rather than fails, because a missing file costs fill rate while ads
  keep serving — the reason it goes unnoticed.
- **AdMob creation is limited access.** `accounts.apps.create` and
  `accounts.adUnits.create` answer 403 unless Google grants the account
  access; listing does not. The client returns null for those 403s so the
  step can fall back to console creation instead of failing the run.
- **AdMob does not accept service accounts** — it is OAuth user credentials
  only, which is why the token chain ends at gcloud's application-default
  credentials rather than a key file.
- **A gcloud ADC token names no project, and AdMob refuses it.** ADC is
  minted by gcloud's own OAuth client, which belongs to no project, so
  admob.googleapis.com answers 403 — listing included — until the caller
  names one. `set-quota-project` records it as `quota_project_id` in the ADC
  file and Google's client libraries send it as `x-goog-user-project`;
  `print-access-token` hands over the token alone, so `AdmobApi` reads the
  file and sets the header itself. Only for a gcloud token: a token from an
  OAuth client of your own already carries a project, and attaching an
  unrelated one from the machine's ADC file would break a working setup.
- **The Amplitude key probe posts an empty event batch.** Amplitude checks
  the key before it looks at the batch, so an accepted key ingests nothing
  and a rejected one names itself in the error. Never probe with a real
  event — it would land in the project's data.
- **A flow-style block in a user-owned yaml is never rewritten.**
  `PubspecText` bails out and prints the block to paste, the same rule
  `capture` follows for screenshots.yaml.
- **Prefix pruning would delete IDs a failed lookup could not re-derive.**
  `EnvJsonWriter.merge` takes a `prunes(key)` predicate, not a prefix: a unit
  still declared in the yaml keeps the value already in env.json even when
  this run resolved nothing, a unit deleted from the yaml converges, and an
  `AMPLITUDE_*`/`ADMOB_*` key the developer added for something else is not
  the step's to delete.
- **An AdMob store link is identity; a display name is a coincidence.**
  Match Android apps by `linkedAppInfo.appStoreId` (the package name) first
  and only fall back to the name — two apps in one account can share a name.
  Same idea for ad units: a same-named unit of a different `adFormat` is not
  the declared unit, and adopting it would ship a banner ID in a rewarded
  placement while env.json hid it behind the declared format's test ID.
- **OAuth token endpoints take form-encoded requests.** Google's happens to
  parse JSON too, but `postForm` is what the docs promise — do not route the
  refresh exchange back through `post`.

## Configuration files

- `easy_setup.yaml` — v2 schema, top-level `app` / `ios` / `android` /
  `flavors` / `build` / `branding` / `screenshots` / `sentry` / `amplitude` /
  `firebase` / `admob` / `site`. A v1 `easy_setup:` root key is detected and
  rejected.
- `easy_setup_store_info.yaml` — store listing copy, review information,
  age rating. Limits are enforced at parse time.
- `assets/store/screenshots/screenshots.yaml` — per-screen copy, palettes,
  fonts, cropping.

## Testing

`test/` mirrors `lib/src/`. Steps are tested against a temp directory with
fake collaborators (`test/support/fake_html_renderer.dart`, local
`ProcessRunner` fakes). Always cover: the happy path, idempotency (run
twice), convergence (remove a source, the output goes too), and the error
message a user would actually hit.

## File structure

```
bin/easy_setup.dart              CLI entry, subcommand routing
lib/src/
  commands/                      init, doctor, setup, capture, deploy, flavor, ci-cd
  config/                        v2 schema + store info parsing
  setup/                         the steps + their templates
  capture/                       simulator control + tour scaffolding
  render/                        headless Chrome + {{placeholder}} filling
  deploy/                        iOS/Android deployers, version resolution
  doctor/                        checks + report
  appstore/                      ASC API client, JWT, key files
  fastlane/ github/              generators for the v1 ci-cd command
  admob/                         AdMob API v1beta client (OAuth + apps/units)
  android/ ios/ firebase/        platform modifiers (v1 flavor path)
  utils/                         process, http, paths, idempotent writes, hashing
```

`ios/xcodegen_*` and `utils/xcodegen_runner.dart` belong to the **v1 flavor
path only**; v2 configures iOS through xcconfig and plist edits.

## Runtime dependencies

Chrome (store assets), Xcode + `simctl` (capture, iOS deploy), fastlane
(deploy, store listings), Flutter. Optional: `gcloud`, as the least-effort
AdMob credential. `doctor` reports each one when the config asks for it.

## When adding a feature

- New step: follow the pattern — guard, converge, prune, report — and add
  it to `SetupCommand.defaultSteps()` in the right position.
- New design source: seed with `writeIfAbsent`, never rewrite it, and teach
  the matching Claude skill how to edit it.
- New YAML key: parse and validate it in the model, with an error message
  that says what to type.
- Rewriting a user-owned YAML file: line-based edits only, bail out and
  print the block for flow-style input, and follow the file's existing
  indentation.
