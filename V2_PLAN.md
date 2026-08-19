# easy_setup v2 — 재구축 계획서

> **이 문서가 v2 작업의 기준 문서다.** 2026-07-30 dream-diary 프로젝트에서
> 릴리스 자동화를 기획하다가, 기존 easy_setup을 확장 재구축해 범용 툴로
> 만들기로 결정했다. 파일럿 프로젝트 관점의 원본 기획은
> `~/Desktop/Lee-nest/dream-diary/docs/ops/release-automation.md` 참고.

---

## 1. 배경과 결정 사항

| 항목 | 내용 |
|---|---|
| 기존 상태 | v0.0.2 (2026-03-15 pub.dev 퍼블리시) — flavor 셋업 + Fastlane/GitHub Actions 생성 CLI. 만들다 중단됨 |
| **결정** | **처음부터 재구축한다.** 단, 아래 자산은 유지·계승 |
| 유지 자산 | ① pub.dev 패키지명 `easy_setup` (이미 확보 — 공개 배포의 최대 관문 통과) ② 저장소 `Etch-Studio/flutter_easy_setup` ③ v1 코드 중 검증된 모듈 (→ §8 재사용 지도) ④ "yaml 하나 → 멱등 적용" 설계 철학 |
| 비전 변화 | v1: flavor/CI 셋업 도구 → **v2: Flutter 프로젝트의 셋업(Setup Kit)과 배포(Deploy Kit) 전체를 콘솔 접속 없이 자동화하는 범용 툴킷** |
| 파일럿 | dream-diary(드림로그)가 첫 적용 대상. group-alarm(알람펫)이 두 번째 |

## 2. 제품 정의 — 두 개의 킷

| | **Setup Kit** (셋업·환경 설정) | **Deploy Kit** (배포 자동화) |
|---|---|---|
| 실행 시점 | 프로젝트 생성 시 1회 + 설정 변경 시 | 릴리스마다 반복 (태그 푸시) |
| 실행 장소 | 주로 로컬 | 주로 CI |
| 하는 일 | 서비스 프로비저닝(Sentry/Firebase·GA/AdMob), 네이티브 설정 주입(capabilities, background modes, AdMob ID), 아이콘·스크린샷 파이프라인, flavor | 코드사이닝(match), 빌드, 스토어 업로드, 트랙 승격 |
| 멱등성 | 필수 — 몇 번을 돌려도 같은 결과 (v1 철학 계승) | 태그 = 버전, 재실행 안전 |

## 3. CLI UX

```bash
dart pub global activate easy_setup

easy_setup init      # easy_setup.yaml + 워크플로 + 에셋 폴더 뼈대 생성 (대화형)
easy_setup doctor    # 환경·키·시크릿 검증 + 발급 방법 단계별 안내
easy_setup setup     # Setup Kit 전체 실행 (선언 상태로 수렴, --only sentry 등 부분 실행)
easy_setup deploy    # 로컬에서 배포 (CI 없이도 동작; CI도 내부적으로 이 명령을 호출)
easy_setup flavor    # v1 기능 계승 — flavor 환경 구성
```

**설계 원칙 세 가지:**

1. **CI와 로컬이 같은 코드를 실행한다.** GitHub Actions 재사용 워크플로
   내부에서도 `easy_setup deploy`를 호출 → "내 컴퓨터에선 되는데 CI에선
   안 돼요"를 원천 차단.
2. **`doctor`가 공개 툴 성패의 핵심이다.** 이런 툴이 버려지는 이유는 기능
   부족이 아니라 초기 설정(키 발급)에서 막혀서다. doctor는 "ASC API Key가
   없습니다 → App Store Connect > Integrations에서 발급 → 이 시크릿에
   넣으세요"까지 안내한다.
3. **전부 Dart로 구현한다.** bash/jq/Python 외부 의존 금지. iOS 전용
   작업(PlistBuddy 등)은 macOS 전제이므로 Process.run 허용.

## 4. `easy_setup.yaml` v2 스키마 (초안)

```yaml
app:
  name: 마이앱
  bundle_id: com.example.myapp          # iOS
  package_name: com.example.myapp      # Android

ios:
  team_id: XXXXXXXXXX
  match_git_url: git@github.com:my-org/certificates.git
  capabilities:                         # Developer Portal App ID capability
    - push_notifications
    - app_groups: [group.com.example.myapp]
  background_modes: [audio, fetch]      # Info.plist UIBackgroundModes

android:
  play_track_default: internal          # internal → beta → production

flavors:                                # v1 기능 계승 (선택)
  dev: { suffix: .dev, name: 마이앱 DEV }
  prod: {}

branding:
  icon_src: assets/branding/icon/       # icon.png(1024, no-alpha), fg/bg/mono.png

screenshots:
  locales: [ko, en-US]
  devices: [iphone_6_9, ipad_13, android_phone]
  captions: assets/store/screenshots/captions.yaml

sentry:
  org: my-org
  project: myapp                        # 없으면 setup이 생성 후 DSN 회수

firebase:
  project_id: my-org-myapp              # 없으면 생성, GA4 자동 링크
  analytics: true

admob:
  ios_app_id: ca-app-pub-XXXX~YYYY      # API 미승인 시 수동 기입
  android_app_id: ca-app-pub-XXXX~ZZZZ
  ad_units:
    banner_main: { ios: ..., android: ... }
```

v1 스키마(`easy_setup:` 루트 키, flavor 중심)와 다르다. **하위 호환은
포기한다** — v0.0.2 사용자는 사실상 없고, 재구축이 결정됐으므로 v2 스키마를
깨끗하게 설계한다. 퍼블리시는 0.1.0부터 (CHANGELOG에 breaking 명시).

## 5. Setup Kit 기능 명세

### 5.1 앱 아이콘 파이프라인
- 원천 소스만 git 버저닝: `icon.svg`(권장 — 텍스트라 diff·재편집 가능하고
  AI가 직접 그린다) 또는 `icon.png`(1024, **알파 금지** — App Store 규정),
  `fg`/`bg`(Android 적응형, 중앙 66% 안전영역), `mono`(Android 13+ 테마)
- 변환: SVG는 헤드리스 Chrome이 1024×1024로 래스터화 → 이후 v1의
  `app_icon_generator.dart`(image 패키지)가 iOS 15종 + Android 5밀도로 팬아웃
- flavor별 아이콘 배지(dev 리본) 합성, 알파 채널 검증(심사 반려 사전 차단),
  적응형 안전영역 검증
- `.claude/skills/app-icon/SKILL.md`를 생성해 AI가 제약(전면 도색, viewBox,
  텍스트 금지, 40px 가독성)을 지킨 채 디자인하게 한다

### 5.2 스크린샷 파이프라인
두 층 분리가 핵심: **① raw 캡처**와 **② 마케팅 합성**.
- ① `easy_setup capture` — devices 목록대로 시뮬레이터를 부팅하고 상태바를
  9:41로 고정한 뒤 `integration_test` 투어를 돌려 자동 캡처.
  **`binding.takeScreenshot`은 쓰지 않는다** — Impeller/Metal에서 Flutter
  서피스를 못 읽어 전체 실행이 스플래시로 나오는 사례를 확인했다. 대신
  투어가 마커 파일로 요청하면 호스트(CLI)가 `simctl io screenshot`으로
  컴포지터에서 뜬다 — 상태바 포함, 눈에 보이는 그대로. 투어와 데모 데이터는
  앱마다 다르므로 앱 저장소에 남고 스킬이 작성을 안내한다.
  iPhone 16 Pro Max = 1320×2868, iPad Pro 13" = 2064×2752로 스토어 규격을
  네이티브로 캡처하므로 리스케일이 없다. (Android는 아직 수동)
- ② 합성: raw × 로케일별 문구·팔레트(`screenshots.yaml`) × 프레임 디자인
  (`template.html`) → 헤드리스 Chrome이 스토어 규격으로 렌더. 폰트는 data
  URI로 임베드(네트워크 불필요, 머신 간 동일 출력), 렌더 지문을 PNG tEXt에
  심어 변경 없는 화면은 건너뛴다
- `.claude/skills/store-screenshots/SKILL.md`로 캡처 → 카피 작성 → 템플릿
  디자인 → 렌더 → 육안 검증까지 AI가 진행
- 규격: iPhone 6.9" 1320×2868 · iPad 13" 2064×2752 (**이 둘만 있으면 나머지
  사이즈는 Apple이 자동 축소 — 2024 정책**) · Android phone 9:16 최소 2장 ·
  feature graphic 1024×500
- 출력을 fastlane 규격(`fastlane/screenshots/ko/…`)에 맞춰 `deliver`/`supply`가
  그대로 업로드

### 5.3 iOS Capabilities + Background Modes
설정이 세 군데에 흩어져 있고 각각 자동화 방법이 다르다:

| 위치 | 자동화 방법 |
|---|---|
| Developer Portal (App ID) | **공식 ASC API `bundleIdCapabilities`** — API Key로 완전 자동 |
| `Runner.entitlements` | 파일 생성/갱신 (git 버저닝) |
| `Info.plist`의 `UIBackgroundModes` | PlistBuddy 주입 — **포털 설정 자체가 없는 순수 로컬 설정** (예외: `remote-notification`은 Push capability 선행 필요) |

**함정:** Portal capability 변경 시 기존 프로비저닝 프로파일이 무효화된다 —
반드시 `match --force` 재생성까지 이어서 실행. 부가 가치: 설정이 yaml에
선언돼 있으면 `ios/` 폴더를 재생성해도 명령 한 번으로 복원된다.

### 5.4 AdMob — **구현됨** (조회는 일반 공개, 생성은 제한적 접근)
- **조회 API는 누구나 쓸 수 있다**: `accounts.list` / `accounts.apps.list` /
  `accounts.adUnits.list` (scope: `admob.readonly`). 그래서 콘솔에서 ID를
  복사해 붙이는 일 자체가 사라졌다 — yaml에 없는 ID는 매 실행마다 조회로
  채운다. 앱은 플랫폼별로 매칭(Android는 패키지명=`linkedAppInfo.appStoreId`,
  그 외에는 앱 이름), ad unit은 `display_name`(기본값=yaml 키)으로 매칭.
- **생성 API는 제한적 접근**: `accounts.apps.create` /
  `accounts.adUnits.create`는 승인 없으면 403(scope:
  `admob.monetization`). 클라이언트는 이 403을 null로 돌려주고, 스텝은
  "콘솔에서 1회 생성" 안내로 격하한다 — 실행 자체는 실패하지 않는다.
- **인증은 OAuth 사용자 자격증명뿐**(서비스 계정 미지원). 우선순위:
  `ADMOB_ACCESS_TOKEN` → `ADMOB_REFRESH_TOKEN`+OAuth 클라이언트 →
  `gcloud auth application-default print-access-token`.
- 코드 쪽 자동화: `AndroidManifest.xml` APPLICATION_ID meta-data,
  `Info.plist` GADApplicationIdentifier + SKAdNetworkItems 주입, ad unit ID는
  `env.json`(디버그=테스트 ID)/`env.prod.json` 분리 후 `--dart-define-from-file`
- 오프라인 유지가 필요하면 `admob.auto: false`, 계정 고정은
  `admob.publisher_id`.
- 자동화 불가: app-ads.txt 게시, 결제/세금 정보, 신규 앱 광고 승인 대기

### 5.5 Sentry — 100% 자동화 가능
- Org Auth Token(`org:write`, `project:write`) 1회 발급
- 프로젝트 생성: `POST /api/0/teams/{org}/{team}/projects/` (이미 있으면 무시)
- DSN 회수: `GET /api/0/projects/{org}/{project}/keys/` → env.json 주입
- 빌드 연동: `sentry_dart_plugin`으로 심볼 업로드, release/dist를 git tag와 일치
- **pubspec까지 자동화(구현됨)**: `sentry_flutter` 의존성,
  `sentry_dart_plugin` dev 의존성, 그리고 심볼 업로드가 읽는 pubspec의
  `sentry:` 블록(org/project/upload_debug_symbols)을 직접 써준다. 개발자가
  추가한 키(예: `upload_source_maps`)는 건드리지 않는다. 빌드 시점 토큰은
  `SENTRY_AUTH_TOKEN`(org 토큰 그대로 사용 가능).

### 5.5b Amplitude — 프로젝트 생성만 콘솔, 나머지는 자동
- **프로젝트 생성 API가 없다.** 공개된 것은 수집(HTTP V2)·조회·Experiment
  Management·SCIM뿐이고, 프로젝트/키 발급은 콘솔 전용이다. 따라서 정책은
  ASC 앱 레코드와 동일: **생성만 웹에서 1회, doctor가 안내**.
- 그 다음부터는 자동: API 키는 환경변수(`AMPLITUDE_API_KEY`)로만 들어오고,
  `env.json`(dev 키 또는 빈 값=SDK no-op)과 `env.prod.json`에 주입된다 —
  추적되는 파일에 손으로 붙여넣는 경로가 없다.
- **키 검증**: `POST /2/httpapi`에 빈 `events` 배열을 보낸다. Amplitude는
  배열보다 키를 먼저 검사하므로, 맞는 키는 아무것도 적재하지 않고 틀린 키는
  `Invalid API key`로 스스로를 밝힌다.
- `region: eu`는 수집 호스트를 바꾸고 `AMPLITUDE_SERVER_ZONE=EU`를 기록한다.
- SDK 의존성(`amplitude_flutter`)은 `flutter pub add`로 붙인다.

### 5.6 Firebase / Google Analytics — 완전 자동화 가능
- Flutter에서 GA = Firebase Analytics(GA4)
- `firebase projects:create` → Firebase Management API
  `projects:addGoogleAnalytics`로 GA4 링크 → `flutterfire configure --yes`가
  `google-services.json`/`GoogleService-Info.plist`/`firebase_options.dart` 생성
- v1의 `firebase_copier.dart`(flavor별 설정 복사)는 이 위에 그대로 얹힌다

### 5.7 Flavor (v1 계승)
v1의 핵심 기능이자 차별점 — v2에도 포함한다. 구현 방식은 §10 열린 질문 참고
(XcodeGen vs pbxproj 직접 조작).

## 6. Deploy Kit 기능 명세

### 6.1 iOS — 열쇠는 ASC API Key
- 계정당 1회: API Key(.p8) 발급 + match용 private 인증서 저장소
- 자동: Bundle ID 등록, match(인증서/프로파일), `flutter build ipa`,
  pilot(TestFlight), deliver(메타데이터·스크린샷·심사 제출)
- **불가: 앱 레코드 최초 생성** — 공식 API에 엔드포인트 없음.
  `fastlane produce`는 Apple ID 세션(비공식 API) 방식이라 채택하지 않는다.
  **정책: 앱 생성만 웹에서 1회(5분), doctor가 안내**
  (v1은 produce 기반 register lane이 있었다 — v2에서 폐기)

### 6.2 Android — 서비스 계정
- 계정당 1회: GCP 서비스 계정 + Play Console 권한 부여
- **앱마다 1회 수동(API 없음): 앱 생성 + 첫 AAB 업로드** — doctor가 안내
- 이후: `supply`로 트랙 승격, 단계 출시, 스토어 텍스트·스크린샷

### 6.3 CI — GitHub Actions 재사용 워크플로
- 이 저장소에 `release-ios.yml`/`release-android.yml`(workflow_call)을 두고
  각 앱은 5줄짜리 호출 워크플로만 가짐 (`secrets: inherit`)
- 시크릿은 GitHub **Organization Secrets**로 1회 등록 → 전 앱 상속:
  `ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8`, `MATCH_PASSWORD`+deploy key,
  `PLAY_SERVICE_ACCOUNT_JSON`, `SENTRY_ORG_TOKEN`, `FIREBASE_SERVICE_ACCOUNT`,
  (`ADMOB_OAUTH_CREDENTIALS`)
- 버전: git tag `v*`가 단일 진실 — 태그 푸시가 배포 트리거, 빌드번호는 CI run number

## 7. 검증된 사실관계 (2026-07-30 웹 확인 — 재조사 불필요)

| 사실 | 출처 |
|---|---|
| 공식 ASC API에 **앱 생성 엔드포인트 없음**. produce는 Apple ID 세션 방식 | docs.fastlane.tools/actions/produce |
| ASC API로 Bundle ID capability 등록 가능 (`bundleIdCapabilities`) | developer.apple.com/documentation/appstoreconnectapi |
| AdMob API v1beta에 apps/adUnits **create 존재하나 limited access** (403 시 승인 신청) | developers.google.com/admob/api/reference/rest/v1beta |
| Background Modes는 포털 capability가 아닌 **순수 Info.plist** 설정 | Apple 문서 |
| App Store 스크린샷: iPhone 6.9" + iPad 13" 두 벌이면 나머지 자동 축소 | developer.apple.com/help/app-store-connect |
| Play Developer API로 **앱 생성 불가** — 첫 AAB 수동 업로드 필요 | Google Play 문서 |
| Sentry는 프로젝트 생성·DSN 회수 전부 공개 API | docs.sentry.io/api |
| Firebase: projects:create + addGoogleAnalytics + flutterfire configure로 완전 자동 | firebase.google.com/docs |

## 8. v1 자산 재사용 지도 (lib/src, 약 3,800줄)

| v1 모듈 | v2 처분 |
|---|---|
| `android/build_gradle_modifier.dart` (brace-counting 파서) | ✅ 이식 — 검증된 코드 |
| `ios/xcconfig_generator.dart`, `info_plist_modifier.dart`, `podfile_modifier.dart` | ✅ 이식 |
| `ios/app_icon_generator.dart` (image 패키지) | 🔍 flutter_launcher_icons 래핑과 비교 후 결정 |
| `ios/xcodegen_*` (XcodeGen 기반 프로젝트 생성) | ⚠️ §10 열린 질문 — 침습성 큼 |
| `ios/info_plist_strings_generator.dart` (로케일라이징) | ✅ 이식 |
| `firebase/firebase_copier.dart`, `firebase_options_generator.dart` | ✅ 이식 |
| `fastlane/*_generator.dart` 6종 | ✅ 골격 이식, register lane(produce)만 폐기 |
| `github/workflow_generator.dart` | 🔄 재설계 — 생성형 → **재사용 워크플로 호출형**으로 전환 |
| `utils/project_finder.dart`, 멱등성 가드 패턴, dry-run 모드 | ✅ 그대로 계승 |
| `models/` (v1 스키마) | ❌ v2 스키마로 재설계 (하위 호환 포기) |
| CLAUDE.md | ⚠️ 현재 코드와 불일치(오래됨) — 재구축 시 재작성 |

## 9. 공개 배포 전략

**형태: pub.dev의 Dart CLI** (melos/flutterfire_cli/mason_cli가 검증한 경로.
타겟인 Flutter 개발자는 이미 Dart가 있어 진입장벽 0. 이름도 이미 확보됨).

| 단계 | 내용 |
|---|---|
| **v0** | 재구축 + 본인 프로젝트 2개(dream-diary, group-alarm)로 검증. 처음부터 Dart로 작성해 재작성 비용 제거 |
| **v1** | 저장소 공개 + semver 태그 + README 온보딩. 재사용 워크플로는 `@v1` 태그로 참조 |
| **v2** | pub.dev 0.1.0 퍼블리시 + doctor 완성 + (선택) brickhub |

CI 워크플로는 pub.dev에 못 올라가므로 **공개 GitHub 저장소 + semver 태그**가
배포 채널이다. 남의 계정에서 돌게 하려면 org 하드코딩 금지 — 모든 조직
정보는 easy_setup.yaml과 시크릿에서만 온다.

## 10. 열린 설계 질문 (구현 시작 전 결정 필요)

1. **XcodeGen 유지 여부** — v1은 flavor를 위해 Xcode 프로젝트 전체를
   XcodeGen으로 재생성했다(침습적, brew 의존). 대안: v1 초기의 pbxproj
   직접 조작(클론 기반) 복원, 또는 xcconfig-only 접근. capabilities/plist
   작업에는 XcodeGen이 불필요하다.
2. ~~**아이콘 생성기** — flutter_launcher_icons 래핑 vs v1 자체 구현 유지.~~
   → **결정: 자체 구현 유지.** 소스는 `icon.svg`(헤드리스 Chrome으로 1024
   래스터화), 팬아웃은 기존 `image` 패키지 구현. flutter_launcher_icons는
   SVG 소스·알파 검증·안전영역 검증을 제공하지 않는다.
3. **스크린샷 캡처의 CI 실행** — 시뮬레이터 부팅 매트릭스를 macOS 러너에서
   돌리는 비용 vs 로컬 전용으로 시작. **캡처 자체는 `easy_setup capture`로
   구현됐고(로컬 전용), CI 실행 여부만 열려 있다.** layer ② 합성도 결정됨:
   HTML 템플릿을 헤드리스 Chrome이 스토어 규격으로 렌더 — `image` 패키지
   직접 합성보다 폰트/레이아웃 자유도가 크고, AI가 템플릿을 직접 다시
   디자인할 수 있다. 남은 것: Android 캡처(에뮬레이터 + adb).
4. **flavor 기능의 v2 1차 릴리스 포함 여부** — 파일럿(dream-diary)은 당장
   flavor가 없어도 된다. 늦출 수 있다.

## 11. 마일스톤

| # | 내용 | 완료 기준 |
|---|---|---|
| M1 | CLI 골격 + v2 스키마 + doctor | `easy_setup doctor`가 dream-diary에서 키 상태 정확 보고 |
| M2 | Deploy Kit iOS (match/pilot/deliver 래핑) | dream-diary TestFlight 업로드가 명령 한 번 |
| M3 | Deploy Kit Android + 재사용 워크플로 | 태그 푸시 → 양 스토어 자동 배포 |
| M4 | Setup Kit: Sentry + Amplitude + Firebase/GA + capabilities + AdMob 조회·주입 | dream-diary 출시 전 재등록 작업을 `easy_setup setup`으로 수행 |
| M5 | 아이콘 + 스크린샷 파이프라인 | 스토어 에셋이 저장소에서 재생성 가능 |
| M6 | 공개 준비 (README, semver, pub.dev 0.1.0) | 외부인이 doctor 안내만으로 온보딩 성공 |

### M6 상세 (진행하며 쌓인 것)

- **README 본문 정리** — 현재 300줄 이상이 v1 전용이다: `easy_setup:` 루트 키
  스키마, `app_icon` 필드, XcodeGen 설치 prerequisite. 상단 배너가 "아래는
  v1"이라고 밝히고 있어 틀리진 않지만 처음 읽는 사람에겐 혼란스럽다.
  v2를 본문으로 올리고 v1은 별도 문서(또는 부록)로 내린다.
- **semver 태그** — `init`이 생성하는 caller 워크플로가 재사용 워크플로를
  `@main`으로 참조한다. 태그를 끊고 `@v1` 같은 고정 참조로 바꿔야 남의
  저장소에서 안전하다.
- **CLAUDE.md** — v2 기준으로 재작성 완료(M5b). 공개 시점에 명령어·스텝
  목록만 다시 대조할 것.
- **pub.dev 0.1.0** — `flavor`/`ci-cd`가 v1 스키마로 남아 있다는 점을
  릴리스 노트에 명시한다.
