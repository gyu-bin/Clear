# 테스트

## 원칙

- 실제 사용자 캐시·프로젝트·시스템 파일은 지우지 않습니다.
- 파일 시스템 테스트는 테스트마다 새로 만드는 `$TMPDIR/ClearTests-<UUID>` 안에서만 하고, 끝나면 그 폴더를 지웁니다(`ClearTests/Support/TempDirectory.swift`).
- 실행 엔진은 `MockFileSystem`으로 검증합니다. 모든 변경 호출을 기록하므로 "계획한 경로만 건드렸는지"를 확인할 수 있습니다.
- 외부 명령은 `MockCommandRunner`로 대체합니다. 테스트 중 `brew`, `docker`, `xcrun`, `git`은 실제로 실행되지 않습니다.

## 실행 방법

### 1. Xcode / xcodebuild (앱에 호스팅)

```bash
xcodebuild -project Clear.xcodeproj -scheme Clear -derivedDataPath build/DerivedData test
```

`ClearTests`는 `TEST_HOST`로 앱 안에서 실행되므로 테스트하는 동안 Clear 창이 잠깐 열립니다(테스트 중에는 메뉴 막대 아이콘과 백그라운드 모니터가 꺼집니다). 컴파일만 확인하려면 `build-for-testing`을 쓰세요. 이 경우 앱이 열리지 않습니다.

### 2. 앱 없이 실행 (헤드리스, 권장)

```bash
scripts/run-headless-tests.sh
```

`scripts/headless-tests/`는 UI가 아닌 계층(`Clear/Models`, `Core`, `Adapters`, `Persistence`, `Features/DiskExplorer/TreemapLayout.swift`)과 `ClearTests/`를 상대 경로 심볼릭 링크로 묶은 Swift 패키지입니다. `swift test`로 실행하므로 앱 창이 열리지 않고, 약 1초 안에 끝납니다. 추가 인자는 `swift test`로 그대로 넘어갑니다. 예: `scripts/run-headless-tests.sh --filter SafeRemoverTests`

빌드 산출물(`scripts/headless-tests/.build`)은 `.gitignore`에 들어 있습니다.

## 요구 테스트 항목과 대응

| # | 항목 | 테스트 | 상태 |
|---|---|---|---|
| 1 | 일반 캐시 스캔 | `GeneralCleanupScannerTests` | ✅ |
| 2 | 개발자 캐시 스캔 | `DeveloperAdapterTests`(Xcode, npm, Gradle, 시뮬레이터) | ✅ |
| 3 | 빈 폴더 | `DirectorySizerTests.empty` | ✅ |
| 4 | 접근 거부 폴더 | `DirectorySizerTests.accessDenied`, `DiskTreeScannerTests.tree`, `GeneralCleanupScannerTests.restricted` | ✅ |
| 5 | 심볼릭 링크 | Sizer·SafeRemover·Validator·DuplicateFinder 각 테스트 | ✅ |
| 6 | 하드 링크 | `DirectorySizerTests.hardLinks/dedupAcrossCalls`, `SafeRemoverTests.hardLinks`, `DuplicateFinderTests.hardLinks` | ✅ |
| 7 | 파일 크기 계산 | `DirectorySizerTests.sums` (논리/할당 구분) | ✅ |
| 8 | 중복 파일 판정 | `DuplicateFinderTests` (앞뒤는 같고 중간이 다른 파일 포함) | ✅ |
| 9 | 앱 제거 후보 연결 | `AppInventoryTests` | ✅ |
| 10 | 삭제 전 안전 정책 | `SafetyPolicyTests`, `CleanupValidatorTests` | ✅ |
| 11 | 실행 중인 도구 감지 | `ProcessGuardTests`, 실행 중 가드 테스트(Xcode, Claude Code, 앱 캐시) | ✅ (실제 libproc 읽기는 수동 확인 대상) |
| 12 | 스캔 이후 파일 변경 | `replacedAfterScan`, `swappedForSymlink`, `modifiedFile`, `skipsChanged` | ✅ |
| 13 | 삭제 중 오류 | `CleanupExecutorTests.isolatesFailures` | ✅ |
| 14 | 작업 취소 | `SafeRemoverTests.cancellation`, `CleanupExecutorTests.cancellation` | ✅ |
| 15 | 외장 볼륨 처리 | `CleanupValidatorMockTests.otherVolume` (Mock 장치 번호) | ⚠️ 실제 외장 드라이브로는 미검증 |
| 16 | 저장공간 결과 검증 | `trashAccounting`(휴지통분은 확보로 세지 않음) | ⚠️ 실제 볼륨 재측정은 미검증 |
| 17 | 대용량 디렉터리 성능 | `DirectorySizerTests.performance`(5,000개 파일) | ✅ |
| 18 | 동일 항목 중복 합산 방지 | `CleanupPlannerTests.nested`, `dedupAcrossCalls`, `ownedSkipped` | ✅ |
| 19 | 사용자 원본 파일 보호 | `userFilesAlwaysTrash`, `ProjectAnalyzerTests`(소스·.env·.git·Git 추적·키 파일) | ✅ |
| 20 | 권한이 없을 때 처리 | 스캔 결과의 `restrictedLocations`·`inaccessibleCount` | ⚠️ 모델 수준만 검증. 화면 표시는 수동 확인 필요 |

최근 결과(헤드리스): **93개 테스트, 16개 스위트 모두 통과**(약 1초). `xcodebuild build-for-testing`: 성공.
