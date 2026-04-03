# Easy Setup - Integration Test Plan

`setup_test` Flutter 프로젝트를 대상으로 각 기능의 실제 동작을 검증한다.

---

## 사전 준비

- [ ] `setup_test/` 디렉토리가 Flutter 프로젝트로 정상 인식되는지 확인
- [ ] `easy_setup.yaml`이 프로젝트 루트에 존재하는지 확인
- [ ] 테스트용 아이콘 파일 존재 확인 (`resources/icons/icon_bird.png`, `icon_default.png`)

```bash
# easy_setup CLI 실행 방법 (프로젝트 루트에서)
dart run bin/easy_setup.dart flavor -p setup_test
dart run bin/easy_setup.dart ci-cd -p setup_test
```

---

## 테스트 항목

### 1. Android Flavor 설정

**대상 파일:** `setup_test/android/app/build.gradle.kts`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 1-1 | `flavorDimensions` 블록이 삽입되는가 | `build.gradle.kts`에서 `flavorDimensions` 검색 | [ ] |
| 1-2 | `productFlavors` 블록에 dev, prod가 모두 생성되는가 | `dev { applicationId "studio.etch.test.dev" }` 등 확인 | [ ] |
| 1-3 | bundle_id가 `applicationId`로 정확히 매핑되는가 | dev → `studio.etch.test.dev`, prod → `studio.etch.test` | [ ] |
| 1-4 | 2번 실행해도 중복 삽입 없는가 (멱등성) | 동일 명령 2회 실행 후 블록이 1개만 존재 | [ ] |
| 1-5 | `--dry-run`에서 파일이 변경되지 않는가 | dry-run 실행 후 파일 diff 없음 확인 | [ ] |

---

### 2. iOS Flavor 설정 (XcodeGen)

**대상 파일:** `setup_test/ios/project.yml`, `setup_test/ios/Runner.xcodeproj/`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 2-1 | `project.yml`이 생성되는가 | 파일 존재 확인 | [ ] |
| 2-2 | flavor별 build configuration이 정의되는가 | `Debug-dev`, `Release-dev`, `Profile-dev` 등 확인 | [ ] |
| 2-3 | flavor별 scheme이 정의되는가 | `dev`, `prod` scheme 존재 확인 | [ ] |
| 2-4 | `xcodegen generate` 실행 후 `.xcodeproj`가 생성되는가 | `Runner.xcodeproj/project.pbxproj` 존재 확인 | [ ] |
| 2-5 | `ios_version` 설정이 반영되는가 | project.yml의 deploymentTarget 확인 | [ ] |
| 2-6 | 2번 실행해도 project.yml 내용이 동일한가 (멱등성) | diff 없음 확인 | [ ] |

---

### 3. iOS xcconfig 파일

**대상 경로:** `setup_test/ios/Flutter/`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 3-1 | flavor별 3개 xcconfig 생성되는가 | `Debug-dev.xcconfig`, `Release-dev.xcconfig`, `Profile-dev.xcconfig` 존재 | [ ] |
| 3-2 | `APP_DISPLAY_NAME`이 YAML의 `name`과 일치하는가 | dev → `MyApp Dev`, prod → `MyApp` | [ ] |
| 3-3 | `Profile-*.xcconfig`이 `Release.xcconfig`을 include하는가 | 파일 내용에 `#include "Release.xcconfig"` 존재 | [ ] |
| 3-4 | 2번 실행해도 파일 내용이 동일한가 (멱등성) | diff 없음 확인 | [ ] |

---

### 4. iOS 앱 아이콘 자동 생성

**대상 경로:** `setup_test/ios/Runner/Assets.xcassets/`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 4-1 | flavor별 appiconset 디렉토리가 생성되는가 | `AppIcon-dev.appiconset/`, `AppIcon-prod.appiconset/` 존재 | [ ] |
| 4-2 | 15개 사이즈 PNG가 모두 생성되는가 | `ls` 명령으로 파일 수 확인 (15 PNG + 1 Contents.json) | [ ] |
| 4-3 | `Contents.json`이 올바른 형식인가 | JSON 파싱 성공 여부, images 배열 항목 수 확인 | [ ] |
| 4-4 | 아이콘 파일 사이즈가 정확한가 | 1024x1024, 180x180, 120x120 등 샘플 검증 | [ ] |
| 4-5 | 소스 이미지가 없으면 에러 메시지가 나오는가 | 존재하지 않는 경로 지정 후 에러 확인 | [ ] |

---

### 5. 앱 이름 다국어 (InfoPlist.strings)

**대상 경로:** `setup_test/ios/Flavors/{flavor}/{locale}.lproj/`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 5-1 | flavor별, locale별 InfoPlist.strings가 생성되는가 | `Flavors/dev/ko.lproj/InfoPlist.strings` 등 존재 | [ ] |
| 5-2 | 한국어 앱 이름이 정확한가 | dev/ko → `"마이앱 Dev"`, prod/ko → `"마이앱"` | [ ] |
| 5-3 | 일본어 앱 이름이 정확한가 | dev/ja → `"マイアプリ Dev"`, prod/ja → `"マイアプリ"` | [ ] |
| 5-4 | Info.plist의 CFBundleDisplayName이 변수 참조로 변경되는가 | `$(APP_DISPLAY_NAME)` 확인 | [ ] |
| 5-5 | copy_flavor_strings.sh 스크립트가 생성되는가 | `ios/xcodegen/script/copy_flavor_strings.sh` 존재 | [ ] |

---

### 6. iOS 권한 설명 다국어

**대상 경로:** `setup_test/ios/Runner/{locale}.lproj/InfoPlist.strings`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 6-1 | en.lproj에 기본 권한 설명이 들어가는가 | `NSCameraUsageDescription = "Camera access is required"` 확인 | [ ] |
| 6-2 | ko.lproj에 한국어 권한 설명이 들어가는가 | `NSCameraUsageDescription = "카메라 접근이 필요합니다"` 확인 | [ ] |
| 6-3 | ja.lproj에 일본어 권한 설명이 들어가는가 | 일본어 문구 확인 | [ ] |
| 6-4 | Podfile에 permission_handler 매크로가 추가되는가 | `PERMISSION_CAMERA=1`, `PERMISSION_PHOTOS=1` 확인 | [ ] |

---

### 7. Firebase 연동

**대상:** `setup_test/` 프로젝트 전체

> **주의:** Firebase 테스트는 `flutterfire` CLI가 설치되어 있고, Firebase 프로젝트 접근 권한이 있어야 실행 가능.

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 7-1 | Android: flavor별 google-services.json이 다운로드되는가 | `android/app/src/dev/google-services.json` 존재 | [ ] |
| 7-2 | iOS: flavor별 GoogleService-Info.plist가 다운로드되는가 | `ios/Runner/Firebase/dev/GoogleService-Info.plist` 존재 | [ ] |
| 7-3 | `lib/firebase_options_dev.dart`가 생성되는가 | 파일 존재 및 import 가능 확인 | [ ] |
| 7-4 | `lib/firebase_options.dart` 통합 라우터가 생성되는가 | dev/prod 분기 로직 확인 | [ ] |
| 7-5 | copy_firebase_plist.sh 스크립트가 생성되는가 | `ios/xcodegen/script/copy_firebase_plist.sh` 존재 | [ ] |
| 7-6 | firebase 설정 없는 flavor에서는 Firebase 단계를 스킵하는가 | firebase 항목 제거 후 실행 시 에러 없음 확인 | [ ] |

---

### 8. Podfile 수정

**대상 파일:** `setup_test/ios/Podfile`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 8-1 | flavor별 build mode 매핑이 추가되는가 | `Debug-dev => :debug`, `Release-dev => :release` 등 확인 | [ ] |
| 8-2 | permission_handler GCC 매크로가 추가되는가 | `GCC_PREPROCESSOR_DEFINITIONS` 블록 확인 | [ ] |
| 8-3 | 2번 실행해도 중복 매핑 없는가 (멱등성) | 동일 항목이 1번만 존재 | [ ] |

---

### 9. CI/CD 파이프라인 생성

**대상 경로:** `setup_test/ci_cd/ios/fastlane/`, `setup_test/.github/workflows/`

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 9-1 | `.env` 파일이 생성되는가 | 파일 존재, TEAM_ID 등 placeholder 확인 | [ ] |
| 9-2 | `Gemfile`이 생성되는가 | fastlane gem 포함 확인 | [ ] |
| 9-3 | `Appfile`에 team_id 참조가 있는가 | ENV 참조 확인 | [ ] |
| 9-4 | `Matchfile`에 모든 bundle_id가 포함되는가 | `studio.etch.test.dev`, `studio.etch.test` 모두 존재 | [ ] |
| 9-5 | `Fastfile`에 필수 lane이 모두 존재하는가 | sync_certs, beta, register lane 확인 | [ ] |
| 9-6 | `ios-deploy.yml`이 생성되는가 | 파일 존재 확인 | [ ] |
| 9-7 | workflow에 flavor 선택 옵션이 있는가 | `workflow_dispatch` inputs에 dev, prod 존재 | [ ] |
| 9-8 | 2번 실행해도 중복 없는가 (멱등성) | 파일 내용 동일 확인 | [ ] |

---

### 10. App Store 메타데이터

> **주의:** 현재 `easy_setup.yaml`에 `metadata` 섹션이 없음. 테스트 시 추가 필요.

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 10-1 | metadata 디렉토리 구조가 생성되는가 | `ci_cd/ios/fastlane/metadata/ko/` 등 존재 | [ ] |
| 10-2 | locale별 텍스트 파일이 생성되는가 | `name.txt`, `description.txt` 등 존재 | [ ] |
| 10-3 | 파일 내용이 YAML 설정과 일치하는가 | 파일 내용 비교 | [ ] |
| 10-4 | Fastfile에 update_metadata lane이 추가되는가 | lane 존재 확인 | [ ] |
| 10-5 | metadata 미설정 시 이 단계가 스킵되는가 | metadata 없이 실행 시 에러 없음 | [ ] |

---

### 11. Dry-Run 모드

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 11-1 | `flavor --dry-run`에서 파일 변경 없음 | git diff 결과 없음 | [ ] |
| 11-2 | `ci-cd --dry-run`에서 파일 변경 없음 | git diff 결과 없음 | [ ] |
| 11-3 | dry-run 시 로그에 수행할 작업이 출력되는가 | stdout에 변경 예정 내용 출력 확인 | [ ] |

---

### 12. 에러 처리

| # | 테스트 | 확인 방법 | 결과 |
|---|--------|----------|------|
| 12-1 | Flutter 프로젝트가 아닌 경로 지정 시 에러 | `Could not find a Flutter project root` 메시지 | [ ] |
| 12-2 | `easy_setup.yaml` 없는 프로젝트에서 에러 | 명확한 에러 메시지 출력 | [ ] |
| 12-3 | YAML에 필수 필드 누락 시 에러 | `bundle_id` 또는 `name` 없이 실행 | [ ] |
| 12-4 | 잘못된 YAML 형식에서 에러 | 파싱 에러 메시지 확인 | [ ] |

---

## 테스트 실행 순서

실제 테스트는 아래 순서를 권장한다. 이전 단계의 출력물이 다음 단계의 입력이 되는 경우가 있다.

```
1. dry-run 테스트 (11번) — 파일 변경 없이 안전하게 먼저 확인
2. Android flavor (1번) — 독립적이므로 먼저 실행
3. iOS xcconfig (3번) → XcodeGen (2번) → 앱 아이콘 (4번) — iOS 기본 설정
4. 앱 이름 다국어 (5번) + 권한 다국어 (6번) — 다국어 관련
5. Podfile (8번) — 권한 매크로 포함
6. Firebase (7번) — xcodegen 이후 실행 필요
7. CI/CD (9번) + 메타데이터 (10번) — 별도 명령어
8. 에러 처리 (12번) — 마지막에 비정상 케이스 확인
```

---

## 테스트 실행 명령어 참고

```bash
# 단위 테스트 (기존 166개)
dart test --reporter expanded

# flavor 통합 테스트
dart run bin/easy_setup.dart flavor -p setup_test

# flavor dry-run
dart run bin/easy_setup.dart flavor -p setup_test --dry-run

# CI/CD 통합 테스트
dart run bin/easy_setup.dart ci-cd -p setup_test

# 멱등성 테스트 (2번 연속 실행 후 diff 확인)
dart run bin/easy_setup.dart flavor -p setup_test
dart run bin/easy_setup.dart flavor -p setup_test
git diff setup_test/

# 에러 케이스 테스트
dart run bin/easy_setup.dart flavor -p /tmp           # Flutter 프로젝트 아닌 경로
dart run bin/easy_setup.dart flavor -p nonexistent     # 존재하지 않는 경로
```
