# Clear 아키텍처

Clear는 SwiftUI(+필요한 곳은 AppKit) 기반의 macOS 14+ 네이티브 앱입니다. 외부 의존성이 없으며 Swift 6 언어 모드와 strict concurrency(`complete`)로 빌드합니다.

## 계층

| 계층 | 위치 | 책임 |
|---|---|---|
| Presentation | `Clear/Features/*`, `Clear/DesignSystem` | 화면, 상태 표시, 사용자 선택. 파일을 직접 지우지 않음 |
| Application | `Clear/App` | `AppModel`(DI 루트·상태), `CleanupCoordinator`(확인→실행→결과 흐름), 백그라운드 모니터, 메뉴 막대 |
| Scan Engine | `Clear/Core/Scanning`, `Core/Storage` | `DirectorySizer`, `DiskTreeScanner`, `VolumeService`, `StorageBreakdownScanner` (fts 기반, 읽기 전용) |
| Classification | `Clear/Core/Classification` | 일반 청소 규칙(`GeneralCleanupScanner`), 캐시 지식 베이스, `ScanContext.makeCandidate` |
| Safety (Policy) | `Clear/Core/Safety` | `SafetyPolicy`(허용 루트·보호 경로), `CleanupValidator`(실행 직전 재검증) |
| Cleanup (Execution) | `Clear/Core/Cleanup` | `CleanupPlanner`, `CleanupExecutor`, `CleanupReport` |
| File System | `Clear/Core/FileSystem` | `FileSystemOperating` 추상화, `LocalFileSystem`, `SafeRemover`, `FTSWalker` |
| Process / Commands | `Clear/Core/Process` | `ProcessInspector`(libproc + KERN_PROCARGS2), `CommandRunner`(신뢰된 실행 파일, 셸 미사용) |
| Developer / AI Adapters | `Clear/Adapters/*` | Xcode, Node(npm/pnpm/Yarn), Expo/RN, Gradle/Android, Homebrew, Docker, 프로젝트 분석, AI 도구 |
| Apps / Duplicates | `Clear/Core/Applications`, `Core/Duplicates` | 앱 관련 파일 탐색, SHA-256 중복 검사, Vision 유사 이미지 |
| Persistence | `Clear/Persistence` | `SettingsStore`(UserDefaults JSON), `HistoryStore`(`~/Library/Application Support/Clear/history.json`) |
| Tests | `ClearTests` | Swift Testing. 임시 폴더와 Mock File System만 사용 |

## 정리 파이프라인

```
Scan → Classify → Plan → Validate → Confirm → Execute → Verify
```

1. **Scan / Classify** — 각 규칙·어댑터가 `ScanContext.makeCandidate`로 후보를 만든다. 이때 경로를 `realpath`로 정규화하고, `lstat` 식별자(장치·inode·mtime·소유자)를 저장하고, 정책에 걸리면 `BLOCKED`로 표시한다.
2. **Plan** — `CleanupPlanner`가 BLOCKED 제거, 중복/중첩 경로 제거(상위 폴더 우선), 삭제 방법 결정(휴지통/즉시 삭제), 경고를 만든다.
3. **Confirm** — `CleanupCoordinator`가 확인 시트를 띄운다. MANUAL 항목이나 명령이 있으면 별도 동의 체크가 필요하다. 이 확인 절차는 설정으로 끌 수 없다.
4. **Validate / Execute** — `CleanupExecutor`가 항목마다 프로세스 스냅샷을 새로 찍고 `CleanupValidator`로 재검증한 뒤 실행한다. 실패는 항목별로 격리되고, 취소는 다음 항목 전에 적용된다.
5. **Verify** — 결과를 항목별로 기록하고, 볼륨 여유 공간을 다시 측정해 정리 전후를 비교한다. 휴지통 이동분은 "확보"로 계산하지 않는다.

## 동시성

- 화면 상태는 `@MainActor @Observable` 클래스(`AppModel`, 기능별 모델)에 있다.
- 스캔·해시·삭제는 메인 액터 밖에서 실행된다(`nonisolated async` 함수, `@concurrent runOffMain`, `Task.detached`).
- 진행률 콜백은 `ProgressThrottle`로 줄인 뒤 메인 액터로 넘긴다.
- 취소는 `Task` 취소로 전달되며, fts 순회·해시·삭제 루프가 주기적으로 확인한다.

## 앱 진입점과 메뉴 막대

- `ClearApp`은 `Window`(main)와 `Settings` 장면만 가진다. `AppModel`은 `AppDelegate`가 하나만 소유한다.
- `AppModel`은 구체 타입 `EnvironmentKey`(`\.appModel`)로 주입한다. Observable 객체용 SwiftUI 환경 API(제네릭 key path)는 쓰지 않는다.
- 메뉴 막대는 SwiftUI `MenuBarExtra` 대신 AppKit `NSStatusItem` + `NSPopover`(`StatusItemController`)로 구현했다. `MenuBarExtra(isInserted:)`가 시작 시 장면 그래프를 재귀적으로 다시 갱신하면서 메인 스레드 스택을 소진해, 실행 3번 중 1번꼴로 충돌했기 때문이다. `MenuBarExtra`를 뺀 빌드는 10번 실행해 10번 모두 정상이었다.

## 빌드 설정

- 배포 대상 macOS 14.0, Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete`.
- **App Sandbox: 꺼짐**, Hardened Runtime: 켜짐, 로컬 실행용 ad-hoc 서명(`CODE_SIGN_IDENTITY = -`).
  - 샌드박스를 끈 이유: 다른 앱의 `~/Library/Caches`, 개발 도구 폴더(`~/.npm`, `~/.gradle`, `~/Library/Developer`)를 읽고, `brew`·`xcrun`·`docker`를 실행해야 하기 때문이다. 개인용 직접 실행 앱이라는 전제다.
  - 대신 관리자 권한(sudo)은 요청하지 않고, TCC(전체 디스크 접근, 폴더 접근 동의)를 우회하지 않는다. 읽지 못한 위치는 "접근 제한"으로 표시한다.
  - 프로젝트 폴더는 일반 bookmark로 저장해 폴더가 옮겨져도 따라간다. 샌드박스 밖이므로 security-scoped bookmark는 필요하지 않다.
- 네트워크 접근 코드는 없다. 사용자 데이터를 외부로 보내지 않는다.
