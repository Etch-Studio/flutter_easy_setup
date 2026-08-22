# AdMob setup

`easy_setup setup --only admob` resolves the AdMob IDs an app needs through
the AdMob API and injects them into the native projects and the dart-define
env files — so `ca-app-pub-…~…` is never copied out of the console by hand,
and an ad unit that was renamed or recreated converges on the next run.

Creating the app and its ad units is the one thing that usually stays manual.
`accounts.apps.create` and `accounts.adUnits.create` are **limited access**:

> This method has limited access. If you see a 403 permission denied error,
> please reach out to your account manager for access.
> — [accounts.apps.create](https://developers.google.com/admob/api/reference/rest/v1beta/accounts.apps/create),
> [accounts.adUnits.create](https://developers.google.com/admob/api/reference/rest/v1beta/accounts.adUnits/create)

There is no public application form; access is granted per account. The step
calls both anyway and degrades to a console-creation message on 403 — listing
is generally available, so the ID work is automatic either way.

```
easy_setup setup --only admob
  ├─ access token            ADMOB_ACCESS_TOKEN → refresh token → gcloud ADC
  ├─ GET  /v1beta/accounts   → accounts/pub-…   (or admob.publisher_id)
  ├─ GET  …/apps             match per platform, create where allowed
  ├─ GET  …/adUnits          match by display name + ad format
  ├─ AndroidManifest.xml     com.google.android.gms.ads.APPLICATION_ID
  ├─ ios/Runner/Info.plist   GADApplicationIdentifier + SKAdNetworkItems
  ├─ env.json                ADMOB_<UNIT>_<PLATFORM> = Google's test ID
  └─ env.prod.json           ADMOB_<UNIT>_<PLATFORM> = the real ID
```

## 1. Give the API a credential

AdMob does not accept service accounts — it is OAuth **user** credentials
only. Easiest first, and the order matters — each command needs the one
before it:

```bash
# a) sign in as the AdMob publisher.
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/admob.monetization,https://www.googleapis.com/auth/admob.readonly,https://www.googleapis.com/auth/cloud-platform

# b) pick the Cloud project the API calls bill to. `gcloud projects list`
#    shows the IDs; the app's Firebase project is already one of them.
gcloud config set project <project-id>
gcloud services enable admob.googleapis.com

# c) point the credential from (a) at that project.
gcloud auth application-default set-quota-project <project-id>
```

Three things this sequence is easy to get wrong:

- **`gcloud auth login` is a different credential.** It signs the CLI in; ADC
  is what libraries and easy_setup read, and only (a) writes it. Running (c)
  without (a) answers *"Application default credentials have not been set
  up"*.
- **The project is pure billing plumbing** — it holds no AdMob data. But (c)
  is not optional: an ADC token is minted by gcloud's own OAuth client, which
  belongs to no project, so AdMob refuses every call — listing included —
  until one is named. The API also has to be enabled on it. Any project the
  signed-in user can reach works.
- **`cloud-platform` is in the scope list for (c)'s sake**, not the API's:
  `set-quota-project` verifies the project through the Service Usage API,
  which the two AdMob scopes cannot call. To keep the token narrow, drop it
  and pin the project by environment variable instead:

  ```bash
  export GOOGLE_CLOUD_QUOTA_PROJECT=<project-id>
  ```

(c) writes `quota_project_id` into gcloud's ADC file; easy_setup reads it
from there and sends it as `x-goog-user-project`, the same way Google's own
client libraries do — `print-access-token` hands over the token alone. The
environment variable wins over the file, and applies to every credential
source. A token of your own (`ADMOB_ACCESS_TOKEN`, or the refresh triple)
already carries the project of the OAuth client that minted it, so the ADC
file is never read for one.

Alternatives, in the order `AdmobApi.accessToken()` tries them:

```bash
export ADMOB_ACCESS_TOKEN=<token>          # short-lived, fine for a one-off run

export ADMOB_OAUTH_CLIENT_ID=<id>          # long-lived: a one-time OAuth client
export ADMOB_OAUTH_CLIENT_SECRET=<secret>  # in the Cloud console, then a
export ADMOB_REFRESH_TOKEN=<token>         # refresh token for your AdMob user
```

First match wins; gcloud is consulted last, and only when a token is actually
needed. `admob.readonly` alone is enough when you never expect to create.

## 2. Create the app and the ad units once

[apps.admob.com](https://apps.admob.com) → **Apps → Add app**, then **Ad
units → Add ad unit**, one per placement.

Two things make the lookup reliable afterwards:

- **Link the app to its store listing** once it is published. Android apps are
  matched by `linkedAppInfo.appStoreId` — the package name — before the step
  falls back to the display name, and two apps in one account can share a name.
- **Name each ad unit what the yaml will call it.** The lookup matches on the
  unit's name, so `display_name` (or the yaml key, when it is omitted) has to
  be what the console shows.

If the account does have creation access, skip this step: `setup` creates
whatever the yaml declares with a `type`.

## 3. Declare the section

```yaml
admob:
  auto: true                              # default. false → offline, yaml only
  # publisher_id: pub-XXXXXXXXXXXXXXXX    # default: the credential's first account
  # ios_app_id: ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY
  # android_app_id: ca-app-pub-XXXXXXXXXXXXXXXX~ZZZZZZZZZZ
  ad_units:
    banner_main:
      type: banner                        # banner | interstitial | rewarded | native | app_open
      display_name: Banner (main)         # default: the key above
      # ios: ca-app-pub-XXXXXXXXXXXXXXXX/YYYYYYYYYY
      # android: ca-app-pub-XXXXXXXXXXXXXXXX/ZZZZZZZZZZ
```

You do not have to open the console to know what is there. A normal run
already lists the account's ad units to resolve the ones the yaml declares,
so it names the rest too:

```
  ✓ Matched ios ad unit "banner_main" (ca-app-pub-…/5266731514)
  ! 1 ad unit(s) in AdMob are not declared here:
      rewarded_hint (REWARDED)
    Add them with: easy_setup setup --only admob --adopt
```

Reported, not adopted: an account keeps units a shipped app version still
requests long after the current one stopped asking, and pulling those in
would put an accessor and two env keys behind each of them.

Declaring the units by hand is optional. For an app whose units already
exist in the console — which is most of them, since creation is limited
access — read them in once instead:

```bash
easy_setup setup --only admob --adopt
```

That lists the units belonging to this app and writes the ones the yaml does
not name yet into `admob.ad_units`, with the `type` taken from the unit's own
`adFormat`, then carries on with the run. A console name that is not a usable
key (`Banner (main)`) becomes `banner_main` with a `display_name:` beside it
so the lookup still matches; a name with nothing usable left in it
(`배너 (메인)`) is reported for you to name yourself.

It is a bootstrap, not part of a normal run: a `setup` that re-added whatever
the console holds would make deleting an ad unit impossible. Run it once, keep
the yaml, and from then on the yaml is the intent — which is what makes a
console rename show up as a failed lookup instead of a silently renamed
accessor in your code.

A declared ID always wins and is never looked up — pin one to take a value out
of the API's hands. `auto: false` keeps the step offline entirely, and then the
yaml is the whole truth: `ADMOB_*` keys it does not name are pruned from the
env files.

`type` does double duty: it is the format a created unit gets, the format the
lookup refuses to mismatch, and what tells the step which of Google's test IDs
belongs in `env.json`.

## 4. Run it

```bash
easy_setup doctor                        # "AdMob API credential", "AdMob app IDs"
easy_setup setup --only admob --dry-run
easy_setup setup --only admob
```

Idempotent: a second run reports `up to date` and writes nothing.

## What it writes

| File | Value |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | `com.google.android.gms.ads.APPLICATION_ID` meta-data |
| `ios/Runner/Info.plist` | `GADApplicationIdentifier`, plus `cstr6suwn9.skadnetwork` in `SKAdNetworkItems` |
| `env.json` | `ADMOB_<UNIT>_<PLATFORM>` = Google's official **test** unit for the declared `type` |
| `env.prod.json` | `ADMOB_<UNIT>_<PLATFORM>` = the real unit ID |
| `lib/ads/ad_ids.dart` | one accessor per declared unit, regenerated from `ad_units` |

Keys are the yaml name upper-cased: `banner_main` becomes
`ADMOB_BANNER_MAIN_IOS` and `ADMOB_BANNER_MAIN_ANDROID`. A unit without a
`type` has no known test ID, so `env.json` gets the real one instead.

Only platforms the project actually has are touched — the native file has to
exist. The step owns `ADMOB_*` keys it declared; one you added for something
else is left alone, and so is a value a failed lookup could not re-derive.

## How the lookup matches

| | Matched on | When it refuses |
|---|---|---|
| App | platform + store ID (Android: the package name), else the display name, case-insensitively | several matches → uses the first and asks you to pin `ios_app_id` / `android_app_id` |
| Ad unit | same app + display name, case-insensitively + the declared `adFormat` | a same-named unit of another format is **not** adopted |

That last refusal is deliberate: adopting a banner unit for a `rewarded`
placement would ship the wrong ID in release while `env.json` hid it behind
the declared format's test ID.

## Getting the IDs into the app

The step seeds **`lib/ads/ad_ids.dart`** — one accessor per declared unit,
reading the dart-defines the env files carry:

```dart
static String? get bannerMain {
  final id = Platform.isIOS ? _bannerMainIos : _bannerMainAndroid;
  if (id.isNotEmpty) return id;
  // A debug build launched without --dart-define-from-file still shows an
  // ad; release keeps null, since the wrong ID is worse than none.
  if (!kDebugMode) return null;
  return Platform.isIOS ? _bannerMainTestIos : _bannerMainTestAndroid;
}
```

That debug fallback is the point. env.json holds the test IDs, but
`String.fromEnvironment` yields `''` when the build passes no file at all —
an IDE run button, a bare `flutter run` — and an empty ID is a banner that
never appears. The fallback makes "debug serves test ads" a property of the
app instead of a property of the command that launched it. Release keeps the
empty string as null: shipping no ad beats shipping the wrong one, and a
release build should be passing env.prod.json anyway.

A unit declared without a `type` has no test unit to fall back to, so its
accessor returns null instead.

Unit names have to be lower_snake_case (`banner_main`, `rewarded_hint`):
the name becomes both the `ADMOB_…` environment key and the Dart accessor,
and anything else breaks one of the two. `setup` refuses the name rather
than generating a file that will not compile.

Every line of the file follows from the yaml, so easy_setup owns it and
**rewrites it each run**: a unit added to `ad_units` gains an accessor, one
deleted loses it — which turns a removed unit into a compile error at each
call site instead of an ID that quietly stops resolving. Edits to it are
overwritten; app logic belongs in a file of your own that imports it. It is
only rewritten — or deleted — while it still starts with the generated
header, so a `lib/ads/ad_ids.dart` you write yourself is reported and left
alone. A run
that changes nothing reports `up to date`, and the file is formatted through
the project's own `dart format`, so it never fails a CI formatting check.

Nothing else is added for you: unlike the Sentry and Amplitude steps, this
one installs no SDK, because ad placement is app code.

```bash
flutter pub add google_mobile_ads
```

```dart
final unitId = AdIds.bannerMain;
if (unitId != null) BannerAd(adUnitId: unitId, ...);
```

Release builds still have to pass the file — the fallback deliberately does
not cover them:

```bash
flutter run                                                      # env.json → test ads
flutter build appbundle --dart-define-from-file=env.prod.json    # deploy passes it for you
```

## app-ads.txt

Programmatic buyers refuse — or discount — inventory they cannot verify you
authorized someone to sell. `app-ads.txt` is that authorization: one record
per seller, published where only the app's owner could have put it.

The crawler gets there from the store listing, and the path is the part
people get wrong:

```
studio.etch.dreamdiary.app          the bundle in the bid request
  → the store listing's developer website     https://host/some/path
  → the HOST, path dropped                    host
  → GET https://host/app-ads.txt              ← the only place it looks
```

So the file belongs at the **domain root**, never beside the app's own pages.
On GitHub Pages that root is served by a repository named `<owner>.github.io`
and nothing else — a project repository's Pages answer under `/<repo>/`,
which the crawler never asks for.

One file covers every app on that host: the records name *publisher
accounts*, not apps, so adding an app changes nothing. Records are added only
when a new publisher account or a mediation partner appears.

```
google.com, pub-XXXXXXXXXXXXXXXX, DIRECT, f08c47fec0942fa0
```

Copy the exact contents from the AdMob console (**Apps > app-ads.txt**) —
mediation partners each add their own record. The store listing also has to
carry that URL as its developer website, or the crawler never learns the
domain. AdMob re-crawls periodically; expect a day before the console calls
it verified.

Publishing it is manual — it lives on a host `setup` never writes to — but
`easy_setup doctor` checks it: it takes the host from `site.base_url` and the
publisher from `admob.publisher_id` (or from the app ID already written into
Info.plist / AndroidManifest.xml), fetches the file, and warns when it is
missing or does not name that publisher. Nothing here fails a build — a
missing file costs fill rate, not ad serving, which is exactly why it goes
unnoticed without a check.

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| `AdMob API access needs OAuth user credentials …` | no token, no refresh triple, gcloud missing or not logged in | step 1 |
| `gcloud… The required property [project] is not currently set.` | no default Cloud project | `gcloud projects list`, then `gcloud config set project <id>` |
| `gcloud… Application default credentials have not been set up.` | `gcloud auth login` signs in the CLI, not ADC | run step 1 (a) first — it is what writes ADC |
| `set-quota-project` → `Service Usage API has not been used` / permission denied | ADC was minted without `cloud-platform` | re-run 1 (a) with the third scope, or `export GOOGLE_CLOUD_QUOTA_PROJECT=<id>` |
| `403: … requires a quota project, which is not set by default` | the ADC token names no project | `gcloud auth application-default set-quota-project <id>` — see step 1 (c) |
| `HTTP 403: AdMob API has not been used in project …` | the API is off for the token's Cloud project | `gcloud services enable admob.googleapis.com`, then set the quota project |
| `HTTP 403: The requested resource is not accessible to the effective user` | signed in as a user without access to that publisher account | check [AdMob user roles](https://support.google.com/admob/answer/12822095) |
| `The AdMob credential can see no publisher account.` | wrong Google account, or several accounts | sign in as the owner, or set `admob.publisher_id` |
| `! AdMob refused to create the ios app (403 — app creation is limited access)` | the expected answer for most publishers | create it in the console (step 2); the lookup still fills the ID in |
| `! No ios app ID — set admob.ios_app_id, or create the app once …` | no app matched the store ID or the name | rename it in the console, or pin the ID |
| `! 2 AdMob android apps match "…"` | two apps share a name | pin `android_app_id` |
| `! ios ad unit "…" is a BANNER unit, but admob.ad_units.x.type says rewarded` | name collision across formats | rename one, or fix `type` |
| `! No ios ad unit named "…" — declare admob.ad_units.x.type …` | the unit does not exist and no format was declared | add `type`, or create the unit in the console |
| `AdMob OAuth refresh failed (HTTP 400): invalid_grant` | the refresh token was revoked or expired | mint a new one, or switch to gcloud |
| `! AdMob lookup skipped: …` | any of the above during `setup` | declared IDs were still injected; doctor lists what is missing |
| IDs look right, no ads in release | the build had no `--dart-define-from-file` | `easy_setup doctor` → `Release dart-defines` |

## What stays manual

Creating the app and its ad units, unless Google granted the account
limited-access approval; publishing app-ads.txt, which lives on a domain root
`setup` has no reach into; and the ad-loading code itself. Everything between
— account discovery, ID resolution, the native entries, the env files — is
`setup`'s job, and doctor checks the two ends it cannot write.
