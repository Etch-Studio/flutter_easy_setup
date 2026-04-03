# Easy Setup - 기능 현황

> Version: 0.0.2

`easy_setup.yaml` 하나로 Flutter 프로젝트의 Flavor 설정과 CI/CD 파이프라인을 자동 구성하는 CLI 도구.

---

## 사용법

```bash
easy_setup flavor              # Flavor 설정 (기본 명령어, 생략 가능)
easy_setup ci-cd               # CI/CD 파이프라인 생성
easy_setup flavor --dry-run    # 실제 파일 변경 없이 미리보기
easy_setup flavor -p ./myapp   # 프로젝트 경로 직접 지정
```

---

## 구현 완료된 기능

### 1. Android Flavor 설정

YAML에 정의한 flavor 정보를 기반으로 `build.gradle` / `build.gradle.kts`를 자동 수정.

- `flavorDimensions` + `productFlavors` 블록 삽입
- flavor별 `applicationId`, `versionCode`, `versionName` 설정
- `signingConfigs` 설정 (keystore/alias 지정 시)
- Groovy DSL / Kotlin DSL 모두 지원
- 중복 실행 방지 (이미 설정되어 있으면 스킵)

```yaml
flavors:
  dev:
    bundle_id: com.example.app.dev
    name: MyApp Dev
    version_code: 1
    version_name: "1.0.0"
    signing:
      keystore: path/to/keystore.jks
      alias: key-alias
```

---

### 2. iOS Flavor 설정 (XcodeGen 기반)

XcodeGen `project.yml`을 생성하고 `xcodegen generate`를 실행하여 Xcode 프로젝트를 자동 구성.

- flavor별 Build Configuration 생성 (Debug-dev, Release-dev, Profile-dev, ...)
- flavor별 Scheme 자동 생성
- flavor별 xcconfig 파일 생성 (APP_DISPLAY_NAME, DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY 등)
- Podfile에 flavor별 build mode 매핑 자동 추가
- iOS deployment target 설정 (`ios_version`)

```yaml
flavors:
  dev:
    bundle_id: com.example.app.dev
    name: MyApp Dev
    ios:
      team_id: XXXXXXXXXX
      provisioning_profile: "profile-name"
      code_sign_identity: "Apple Distribution"
      entitlements: path/to/entitlements.plist

ios_version: "13.0"
```

---

### 3. iOS 앱 아이콘 자동 생성

1024x1024 원본 이미지 하나로 iOS에 필요한 15개 사이즈를 자동 리사이즈.

- flavor별 독립 아이콘 세트 (`AppIcon-{flavor}.appiconset`)
- `Contents.json` 자동 생성
- 사용하지 않는 아이콘 디렉토리 자동 정리

```yaml
flavors:
  dev:
    app_icon: resources/icons/icon_dev.png
  prod:
    app_icon: resources/icons/icon_prod.png
```

---

### 4. 앱 이름 다국어 지원

flavor별, locale별 앱 표시 이름을 `InfoPlist.strings`로 자동 생성.

- `Info.plist`의 `CFBundleDisplayName`을 xcconfig 변수 참조로 변환
- flavor별 `ios/Flavors/{flavor}/{locale}.lproj/InfoPlist.strings` 생성
- 빌드 시 해당 flavor의 strings 파일을 자동 복사하는 스크립트 포함

```yaml
flavors:
  dev:
    name: MyApp Dev        # 기본 표시 이름
    localized:
      ko:
        app_name: 마이앱 Dev
      ja:
        app_name: マイアプリ Dev

localizations: [ko, en, ja]
```

---

### 5. iOS 권한 설명 다국어 지원

iOS 권한 요청 시 표시되는 설명 문구를 다국어로 설정. Podfile의 `permission_handler` GCC 매크로도 자동 매핑.

- 기본 권한 설명 (en.lproj 기준)
- locale별 권한 설명
- 20개 권한 키 지원 (카메라, 마이크, 사진, 위치, 연락처, 캘린더, 블루투스, 추적 등)

```yaml
permission:
  NSCameraUsageDescription: "Camera access required"
  NSPhotoLibraryUsageDescription: "Photo access required"

localized_permission:
  ko:
    NSCameraUsageDescription: "카메라 접근이 필요합니다"
  ja:
    NSCameraUsageDescription: "カメラアクセスが必要です"
```

---

### 6. Firebase 연동

flavor별 Firebase 프로젝트를 자동 연결. `flutterfire configure`를 실행하여 설정 파일을 다운로드하고 통합 라우터를 생성.

- Android: `android/app/src/{flavor}/google-services.json` 다운로드
- iOS: `ios/Runner/Firebase/{flavor}/GoogleService-Info.plist` 다운로드
- flavor별 `lib/firebase_options_{flavor}.dart` 생성
- 통합 `lib/firebase_options.dart` 생성 (flavor에 따라 자동 라우팅)
- 빌드 시 해당 flavor의 plist를 복사하는 스크립트 포함

```yaml
flavors:
  dev:
    firebase:
      project_id: my-firebase-dev
  prod:
    firebase:
      project_id: my-firebase-prod
```

---

### 7. iOS CI/CD 파이프라인 생성

Fastlane 파일 + GitHub Actions 워크플로우를 자동 생성.

**생성되는 Fastlane 구성:**
- `.env` - 환경 변수 (TEAM_ID, API_KEY_ID 등)
- `Gemfile` - Ruby 의존성
- `Appfile` - App Store Connect 인증 정보
- `Matchfile` - 인증서/프로비저닝 프로파일 관리
- `Fastfile` - 빌드 & 배포 lane들

**제공되는 Fastlane Lane:**
| Lane | 기능 |
|------|------|
| `sync_certs` | 인증서 + 프로비저닝 프로파일 동기화 |
| `refresh_profiles` | 프로비저닝 프로파일만 재생성 |
| `beta` | Flutter 빌드 → TestFlight 업로드 |
| `register` | App Store Connect에 앱 등록 (2FA 대응) |
| `increment_build_number_in_pubspec` | pubspec.yaml 버전 자동 증가 |

**GitHub Actions 워크플로우 (`ios-deploy.yml`):**
- workflow_dispatch로 flavor 선택하여 수동 실행
- Flutter SDK / Ruby / Fastlane 자동 설치
- Match 인증서 동기화 → 빌드 → TestFlight 업로드

```yaml
# ci_cd 섹션은 easy_setup.yaml에 별도 설정 불필요
# flavors 정보를 자동으로 가져와서 생성
```

---

### 8. App Store 메타데이터 관리

App Store에 업로드할 앱 정보를 locale별로 관리.

- `ci_cd/ios/fastlane/metadata/{locale}/` 하위에 텍스트 파일 생성
- `update_metadata` lane으로 App Store Connect에 업로드
- 지원 필드: name, description, subtitle, keywords, promotional_text, release_notes, privacy_url, support_url, marketing_url

```yaml
metadata:
  ko:
    name: 마이앱
    description: "앱 설명입니다"
    keywords: "키워드1,키워드2"
  en-US:
    name: My App
    description: "App description"
```

---

### 9. Dry-Run 모드

모든 기능에서 `--dry-run` 플래그를 지원. 실제 파일을 수정하지 않고 어떤 변경이 일어나는지 미리 확인 가능.

---

### 10. 멱등성 (Idempotent)

모든 설정 작업이 중복 실행에 안전. 이미 적용된 설정이 있으면 스킵하므로 여러 번 실행해도 동일한 결과.

---

## 플랫폼별 기능 지원 현황

| 기능 | Android | iOS |
|------|:-------:|:---:|
| Flavor 설정 (빌드 구성) | O | O |
| 앱 아이콘 자동 생성 | - | O |
| 앱 이름 다국어 | - | O |
| 권한 설명 다국어 | - | O |
| Firebase 연동 | O | O |
| CI/CD 파이프라인 | - | O |
| App Store 메타데이터 | - | O |
| 코드 서명 설정 | O (signingConfigs) | O (xcconfig) |

---

## 미구현 / 확장 가능 영역 (참고용)

| 영역 | 설명 |
|------|------|
| Android 앱 아이콘 | Android용 adaptive icon / mipmap 자동 생성 |
| Android 앱 이름 다국어 | `strings.xml` 기반 다국어 앱 이름 |
| Android CI/CD | Fastlane Android lane / Google Play 배포 워크플로우 |
| Google Play 메타데이터 | Play Console용 앱 설명, 스크린샷 관리 |
| Android 권한 설명 | Android 런타임 권한 관련 설정 |
| Web / macOS / Windows / Linux | Flutter 멀티플랫폼 Flavor 지원 |
| 환경변수 / .env 관리 | flavor별 API endpoint, feature flag 등 dart-define 관리 |
| Launch Screen / Splash | flavor별 런치 스크린 자동 구성 |
| pub.dev 배포 | CLI 도구를 `dart pub global activate`로 설치 가능하게 |
