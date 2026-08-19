# Sentry setup

Everything after one token is automated: `easy_setup setup --only sentry`
creates the project, fetches its DSN into the dart-define env files, and wires
the pubspec so debug symbols upload against the right project. Re-pointing an
app at a fresh Sentry project never means opening the web UI again.

```
easy_setup setup --only sentry
  ├─ POST /teams/{org}/{team}/projects/   create the project (409 = already there)
  ├─ GET  /projects/{org}/{project}/keys/ read the DSN
  ├─ env.json + env.prod.json             write SENTRY_DSN
  ├─ flutter pub add sentry_flutter        (skipped when already listed)
  ├─ flutter pub add dev:sentry_dart_plugin
  └─ pubspec.yaml `sentry:` block          org / project / upload_debug_symbols
```

## 1. Issue the token (the only console visit)

`setup` needs `project:write` (create the project, read its keys) and
`org:read` (find the team). **An organization token cannot do this** — its
scopes are fixed to CI tasks. Sentry names this exact case in its own docs:
*"to programmatically create a new project, you would use an internal
integration."*

**Settings → Developer Settings → Custom Integrations → Create New Internal
Integration**, with:

| Permission | Level | Why |
|---|---|---|
| Project | **Write** | create the project, read its client keys |
| Organization | **Read** | list the teams to create the project under |
| Organization | **Write** | only if your org disables member project creation (see below) |
| Release | **Admin** | only if you want this same token to upload debug symbols |

A personal token with the same scopes works too (Settings → Account →
Personal Tokens), but it stops working if that user leaves the organization —
prefer the internal integration for anything shared.

Then export it:

```bash
export SENTRY_API_TOKEN=<token>
```

`SENTRY_ORG_TOKEN` is still read for backwards compatibility, and `doctor`
tells you when the token arrived under that older name.

## 2. Declare the section

```yaml
sentry:
  org: my-org               # required — the slug in sentry.io/organizations/<slug>/
  project: my-app           # optional — defaults to a slug of app.name
  team: mobile              # optional — defaults to the org's first team
  sdk: true                 # optional — add the sentry_flutter dependency
  upload_symbols: true      # optional — sentry_dart_plugin + the pubspec block
```

## 3. Run it

```bash
easy_setup doctor              # "Sentry API token ✓"
easy_setup setup --only sentry --dry-run
easy_setup setup --only sentry
```

The step is idempotent: a second run reports `already exists` /
`already up to date` and writes nothing.

## 4. What it touches

| File | How |
|---|---|
| `env.json`, `env.prod.json` | `SENTRY_DSN` merged in; other keys untouched |
| `pubspec.yaml` dependencies | `sentry_flutter`, dev `sentry_dart_plugin` — via `flutter pub add`, so pub picks the version |
| `pubspec.yaml` `sentry:` block | `org`, `project`, `upload_debug_symbols`, and `url` for a self-hosted instance. Keys you added yourself (`upload_source_maps`, `dart_symbol_map_path`, …) survive |

Turning `upload_symbols` off later sets `upload_debug_symbols: false` rather
than leaving an earlier `true` uploading. A `sentry:` block written in flow
style (`sentry: { org: x }`) is never rewritten — easy_setup prints the block
to paste instead.

## 5. Ship the DSN with the build

The DSN is a compile-time constant (`String.fromEnvironment('SENTRY_DSN')`),
so the machine that compiles has to have the env file. `deploy` passes
`env.prod.json` to `flutter build`; **commit that file** so CI, which builds
from a clean clone, has it too. Without it every value compiles as an empty
string and the SDK silently no-ops — see the README section on release
dart-defines. `doctor`'s `Release dart-defines` check covers this.

## 6. Upload debug symbols

`sentry_dart_plugin` is a post-build command — `flutter build` does not run
it:

```bash
flutter build ipa --release --obfuscate --split-debug-info=build/symbols \
  --extra-gen-snapshot-options=--save-obfuscation-map=build/app/obfuscation.map.json
flutter pub run sentry_dart_plugin
```

It reads `SENTRY_AUTH_TOKEN` from the environment, and an **organization
token is the right kind here** — its fixed CI scopes are exactly what the
upload needs, and it cannot create projects or edit org settings if it leaks:

```bash
export SENTRY_AUTH_TOKEN=<organization token>   # Settings > Developer Settings > Organization Tokens
```

Two tokens, two jobs. Reusing the setup token works if it also carries
Release: Admin, but then whatever holds it (a CI secret, say) can create
projects too.

The token has to be exported in the shell that runs the plugin. If you keep
secrets in a file that only wraps the `easy_setup` command, the plugin will
not see it:

```bash
source ~/.secrets/easy_setup.env && flutter pub run sentry_dart_plugin
```

## 7. Self-hosted

Set `SENTRY_URL` and everything follows it — the API calls, and the `url:` key
written into the pubspec block so symbol upload targets the same instance
(sentry-cli otherwise defaults to sentry.io). Move back to the hosted service
and the key is removed again.

```bash
export SENTRY_URL=https://sentry.internal
```

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| `Sentry setup needs the SENTRY_API_TOKEN environment variable` | not exported, or exported in a shell the command does not inherit | step 1 |
| doctor: `set, but this is an organization token (sntrys_…)` | organization tokens have fixed CI scopes | issue an internal-integration or personal token |
| `403 … Your organization has disabled this feature for members.` | the org forbids members creating projects; Sentry then wants more than `project:write` | add **Organization: Write** (or Team: Admin) to the integration — the existing token value keeps working — or allow member project creation in the org settings |
| `403` with no such detail | the token lacks `project:write` | add Project: Write |
| `Could not list Sentry teams for org "…" (HTTP 403/404)` | `org:read` missing, or the org slug is wrong | check the slug in the sentry.io URL; add Organization: Read |
| `Sentry org "…" has no teams` | the org has no team to own the project | create a team, or set `sentry.team` |
| `has no client keys` | the project exists but its DSN was deleted | create a client key in Project Settings |
| Events never arrive from a release build | the build did not carry the DSN | commit `env.prod.json`, confirm `doctor`'s `Release dart-defines`, rebuild |
| Stack traces stay obfuscated | symbols were never uploaded | step 6 — build with `--split-debug-info`, then run the plugin |

## What stays manual

Issuing the token, and nothing else. Sentry has no API to mint a token
(that would be the bootstrap problem), so it is one visit per organization —
not per app.
