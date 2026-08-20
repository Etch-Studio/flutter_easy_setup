# Amplitude setup

`easy_setup setup --only amplitude` takes the API key from the environment,
checks it against Amplitude's ingestion API, and writes it into the
dart-define env files — so the key never gets pasted into a tracked file, and a
wrong one fails at setup time instead of silently collecting nothing.

Creating the project is the one thing that stays manual: **Amplitude has no
project-creation API.** Only ingestion, query, Experiment and SCIM APIs are
public, so a project (and the key it comes with) is made in the console. That
is once per app, not once per build.

```
easy_setup setup --only amplitude
  ├─ read $AMPLITUDE_API_KEY          (and $AMPLITUDE_DEV_API_KEY when set)
  ├─ POST /2/httpapi {events: []}     verify the key, ingest nothing
  ├─ env.prod.json                    AMPLITUDE_API_KEY = production key
  ├─ env.json                         AMPLITUDE_API_KEY = dev key, or ""
  └─ flutter pub add amplitude_flutter   (skipped when already listed)
```

## 1. Create the project and copy the key

Amplitude → Settings → **Organization settings → Projects** → *Create
Project*. Open the new project's General settings and copy its **API Key**.

> Not the **Secret Key**. The API key is a client write-only credential and is
> meant to ship inside the app; the secret key reads and deletes data and
> belongs on a server.

A separate development project is optional. Without one, debug builds get an
empty key, which makes the SDK a no-op — usually what you want, since it also
means a mis-set `APP_ENV` cannot pollute production.

## 2. Export it

```bash
export AMPLITUDE_API_KEY=<32-char key>
export AMPLITUDE_DEV_API_KEY=<dev project key>   # optional
```

## 3. Declare the section

```yaml
amplitude:
  project: my-app                      # optional, used in messages only
  api_key_env: AMPLITUDE_API_KEY       # optional, source of the prod key
  dev_api_key_env: AMPLITUDE_DEV_API_KEY
  region: us                           # us (default) | eu — data residency
  verify: true                         # check the key before writing it
  sdk: true                            # add the amplitude_flutter dependency
```

## 4. Run it

```bash
easy_setup doctor                        # "Amplitude API key ✓"
easy_setup setup --only amplitude --dry-run
easy_setup setup --only amplitude
```

Idempotent: a second run reports `already up to date` and writes nothing.

## How the key is verified

The probe posts an **empty event batch** to the ingestion endpoint. Amplitude
checks the key before it looks at the batch, so a good key ingests nothing and
a wrong one names itself:

```
{"code":400,"error":"Invalid API key: 0000…dead"}
```

Two consequences worth knowing:

- **Nothing shows up in the console after `setup`.** The probe deliberately
  sends no events; seeing data requires a build (below).
- A failure that is *not* an invalid key — a 5xx, a rate limit, an unreachable
  host — is reported as unverified and the run continues. Those say nothing
  about the key, and blocking setup on Amplitude's uptime would be wrong.

Set `verify: false` to skip the probe entirely.

## What it writes

| File | Value |
|---|---|
| `env.prod.json` | the production key |
| `env.json` | the dev key, or `""` when none is configured |

`region: eu` also writes `AMPLITUDE_SERVER_ZONE=EU`, and switches the probe to
`api.eu.amplitude.com`. Going back to `us` removes the key again.

The step owns exactly `AMPLITUDE_API_KEY` and `AMPLITUDE_SERVER_ZONE` — an
`AMPLITUDE_*` entry you added for something else is left alone.

## Getting the key into the app

Two halves, neither of which easy_setup can guess for you:

**The build** must pass the file, or `String.fromEnvironment` yields `''` and
the SDK no-ops. `deploy` passes `env.prod.json`; commit that file so CI, which
builds from a clean clone, has it too (see the README section on release
dart-defines).

**The app** reads it:

```dart
static const _apiKey = String.fromEnvironment('AMPLITUDE_API_KEY');
static const _appEnv = String.fromEnvironment('APP_ENV');

Future<void> init() async {
  // An empty key means "no analytics here" — that is what env.json carries.
  if (_apiKey.isEmpty || _appEnv != 'prod') return;
  final amplitude = Amplitude(Configuration(apiKey: _apiKey));
  await amplitude.isBuilt;
}
```

Gating on an explicit `APP_ENV` rather than on build mode is worth copying: a
local `--release` run with the regular `env.json` then cannot land in
production data.

## Confirming events actually arrive

```bash
flutter run --release --dart-define-from-file=env.prod.json
```

Use the app for a moment, then watch Amplitude → **Data → Ingestion Debugger**
(or find your device under User Look-Up). A simulator is enough; on a device
you need a development profile — see [ios-signing.md](ios-signing.md).

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| `Amplitude setup needs the AMPLITUDE_API_KEY environment variable` | not exported, or exported in a shell the command does not inherit | step 2 |
| `Amplitude rejected the key in AMPLITUDE_API_KEY: Invalid API key: …` | wrong key, or a key from a different project | re-copy from the project's General settings |
| `! Could not verify AMPLITUDE_API_KEY (HTTP 503…)` | Amplitude is unhappy, not your key | the key was still written; re-run later to confirm |
| `! AMPLITUDE_DEV_API_KEY is not set` | no dev project | expected — debug builds no-op |
| doctor: `AMPLITUDE_API_KEY set, AMPLITUDE_DEV_API_KEY missing` | same, as a warning | ignore, or create a dev project |
| Key verifies, no events in the console | the build had no dart-defines, or the app's own gate is off | check `doctor`'s `Release dart-defines`, then `APP_ENV` |
| Events land in the wrong project | a stale key in an env file from another app | re-run the step; the diff is visible because `env.prod.json` is committed |
| `Invalid API key` for an EU project | EU keys are rejected by the US endpoint | set `region: eu` |

## What stays manual

Creating the project, and copying its key once. Everything after that —
verification, injection, the SDK dependency — is `setup`'s job.
