# iOS signing

`deploy` syncs the App Store profile on every run, which is all a TestFlight
upload needs. A **device install cannot use a distribution profile**, so
running the app on a phone needs a development profile as well — that is what
`easy_setup certs` is for.

```
easy_setup certs                    # development, and point Xcode at it
easy_setup certs --type adhoc       # fetch only (see "Which type" below)
easy_setup certs --readonly         # fetch without creating anything
easy_setup certs --register-device 00008101-… --device-name "My iPhone"
easy_setup certs --list-devices     # what the portal has; syncs nothing
```

Both commands drive the same match repository (`ios.match_git_url`) with the
same App Store Connect API key, and build their fastlane invocations from the
same code, so they cannot drift apart.

## Prerequisites

```yaml
# easy_setup.yaml
ios:
  team_id: ABCDE12345
  match_git_url: git@github.com:org/certificates.git
```

```bash
export ASC_KEY_ID=…            # App Store Connect API key
export ASC_ISSUER_ID=…
export ASC_KEY_P8_PATH=…       # or ASC_KEY_P8 with the contents (CI)
export MATCH_PASSWORD=…        # match's repo encryption password
```

`easy_setup doctor` reports all of these, with issuance steps when one is
missing.

## Which type, and what it writes

| `--type` | Build configurations | Identity | Written to Xcode by default |
|---|---|---|---|
| `development` (default) | Debug, Profile, Release | Apple Development | ✅ |
| `adhoc` | Release | Apple Distribution | ❌ — pass `--apply` |
| `appstore` | Release | Apple Distribution | ❌ — `deploy` does it per build |

`development` covers Release too, so `flutter run --release` installs on a
device like the other modes. `adhoc` and `appstore` profiles cannot install on
a device, so writing them into the project would break `flutter run` — hence
the explicit `--apply`.

`--no-apply` skips the Xcode write for any type; `--apply` forces it.

## Devices

A development or ad-hoc profile only covers devices registered on the
Developer Portal, so register first:

```bash
easy_setup certs --register-device 00008101-001828A21E92001E \
                 --device-name "My iPhone"
```

The command registers, then syncs — and always passes
`--force_for_new_devices`, because match otherwise hands back the profile it
already stored, without the device that was just added.

`--list-devices` prints the portal's list straight from the App Store Connect
API, and marks the `--register-device` UDID when both are given — the fastest
way to answer "is my phone in there?" without opening the web UI. On its own it
only reports; combined with `--register-device` it reports, registers and syncs.

Find the UDID in Xcode → Window → Devices and Simulators, or with
`xcrun xctrace list devices`.

## Running on a device

```bash
flutter run --release --dart-define-from-file=env.prod.json
```

The env file matters as much as the profile: without it `SENTRY_DSN`,
`AMPLITUDE_API_KEY` and the ad unit IDs compile as empty strings and every SDK
no-ops (see the README section on release dart-defines).

## Living with `deploy`

`deploy` switches Release to `match AppStore …` for the duration of its build —
`flutter build ipa` archives with the project's own signing settings, so there
is no way around it — and restores the project afterwards. Development signing
on Debug/Profile is never touched.

If a deploy is interrupted hard enough to skip the restore, `easy_setup certs`
puts development signing back.

## What is not automated

Issuing the ASC API key, and creating the private git repository match stores
into. Both are one-time, per account rather than per app.
