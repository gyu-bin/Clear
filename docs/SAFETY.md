# Clear 삭제 안전 정책

Clear의 원칙: **기능 개수보다 데이터 안전이 먼저**입니다. UI 코드는 파일을 지우지 않으며, 모든 삭제는 `CleanupPlanner` → `CleanupCoordinator`(사용자 확인) → `CleanupExecutor`(항목별 재검증)를 거칩니다.

## 위험도

| 등급 | 의미 | 기본 선택 | 원클릭 Smart Clean |
|---|---|---|---|
| SAFE | 정책상 허용되고 런타임 검증을 통과한, 재생성되는 데이터 | 선택됨(관련 앱이 실행 중이면 해제) | 포함 |
| REVIEW | 대부분 문제없지만 사용자가 확인해야 함 | 해제 | 제외 |
| MANUAL | 사용자 파일·모델·앱 번들·시뮬레이터처럼 개별 선택이 필요함 | 해제 | 제외, 확인 시트에서 추가 동의 필요 |
| BLOCKED | 삭제 불가. 정보만 표시 | 선택 불가 | 제외 |

`~/Library/Caches` 아래라는 사실만으로 SAFE가 되지 않습니다. `CacheKnowledgeBase.knownRegenerable`에 있는 캐시와 업데이트 잔여 파일(`*.ShipIt`)만 SAFE이고, 나머지는 REVIEW, 계정·동기화·보안 관련 캐시는 BLOCKED입니다.

## 실행 직전 재검증 (`CleanupValidator`)

모든 경로 항목을 지우기 직전에 다음을 다시 확인합니다.

1. 경로 형식: 절대 경로이고 `.`/`..`/NUL이 없을 것.
2. 허용 루트: 후보의 루트가 `SafetyPolicy`에 등록되어 있고, 정규화된 경로가 그 루트 **안쪽**(경로 구성요소 단위 비교, 문자열 prefix 아님)일 것.
3. 심볼릭 링크: 후보 자체가 링크가 아니고, `realpath` 결과가 스캔 때 경로와 같을 것(상위 경로에 링크가 끼어들지 않음).
4. 보호 경로: 시스템·홈·Library 루트, 키체인, iCloud Drive, 메일·메시지, `.ssh`, `.git`, `*.photoslibrary`, Time Machine 백업, AI 도구의 대화 기록·인증·설정, Xcode Archives, 사용자 제외 경로. 보호 경로의 **상위 폴더**도 지울 수 없습니다.
5. 식별자: 장치·inode·종류가 스캔 때와 같을 것. 파일과 사용자 데이터는 mtime·크기도 같아야 합니다(캐시 폴더는 내용 변화 허용).
6. 볼륨: 루트와 같은 볼륨일 것(마운트 지점·외장 드라이브로 넘어가지 않음).
7. 소유자: 현재 사용자 소유일 것. 상위 폴더에 쓰기 권한이 있을 것.
8. 프로세스: 관련 앱(번들 ID), 실행 파일(예: `xcodebuild`), 인터프리터 인자(예: `npm-cli.js`, `org.gradle`)가 실행 중이 아닐 것.

## 삭제 방식

- **휴지통 이동**(`FileManager.trashItem`): 기본값입니다. 사용자 파일·앱·중복 파일·모델·앱 관련 파일은 설정과 관계없이 항상 휴지통으로 갑니다. 휴지통으로 옮긴 용량은 "확보한 공간"으로 계산하지 않습니다.
- **즉시 삭제**(`SafeRemover`): "휴지통 우선"을 끄면 재생성 가능한 캐시에만 적용됩니다.
  - 루트(`/`)부터 각 경로 구성요소를 `openat(O_NOFOLLOW | O_DIRECTORY)`로 열어 TOCTOU 심볼릭 링크 탈출을 막습니다.
  - 대상을 연 뒤 `fstat`으로 장치·inode를 다시 확인합니다.
  - 하위 항목은 링크를 따라가지 않고(링크 자체만 unlink), 다른 볼륨(마운트 지점)으로 넘어가지 않습니다.
  - 하드 링크 파일은 확보 용량에 넣지 않습니다.
- **공식 명령**: `brew cleanup`(먼저 `brew cleanup -n` 결과 표시), `xcrun simctl delete …`, `docker image/builder/container prune -f`, `pnpm store prune`, `ollama rm <model>`.
  - `CommandRunner`가 고정된 신뢰 경로의 실행 파일(root 또는 본인 소유, 다른 사용자 쓰기 불가)을 인자 배열로 실행합니다. 셸을 거치지 않습니다.
  - 시뮬레이터 UDID와 Ollama 모델 이름은 정규식으로 검증합니다.
  - Docker 볼륨은 정리하지 않습니다.

## 하지 않는 것

sudo·관리자 권한 요청, `rm -rf`, `/System`·`/Library`·`~/Library` 전체 삭제, 키체인·인증 정보 삭제, 사진 보관함 내부 삭제, Time Machine 백업 삭제, 휴지통 비우기, iCloud 전용 파일 다운로드 유발, Gradle 캐시 루트 통째 삭제, 프로젝트 소스·`.git`·`.env`·키 파일 삭제, Git 추적 파일 삭제(`.gitignore`에 있다는 이유만으로 삭제 대상으로 보지 않음).

## 영역별 규칙 요약

- **앱 제거**: 번들 ID가 정확히 일치하는 항목만 연결합니다. 캐시·HTTP 저장소·창 복원 정보는 SAFE, 환경설정·앱 데이터·컨테이너는 REVIEW, 서명에 선언된 그룹 컨테이너와 이름만 같은 폴더는 MANUAL입니다. Apple 앱, 관리자 소유 앱, 실행 중인 앱은 제거하지 않습니다.
- **중복 파일**: 크기 → 앞뒤 64KB 해시 → 전체 SHA-256(스트리밍, `F_NOCACHE`)으로 확인된 파일만 묶습니다.
  - 하드 링크와 심볼릭 링크는 중복이 아닙니다.
  - 원본이 하나로 분명할 때만 자동 선택합니다.
  - 실행 직전에 각 그룹에 남길 파일이 디스크에 그대로 있는지 다시 확인합니다(`DuplicatesModel.verifyKeepers`).
- **비슷한 사진**: 아무것도 자동 선택하지 않습니다.
- **개발 프로젝트**: 알려진 생성 폴더(`android/build`, `ios/build`, `.expo`, `.next` 등)만 후보로 올립니다.
  - Git이 추적하는 파일이 있거나, 비밀 파일(키·인증서·`.env`·DB)이 들어 있으면 BLOCKED입니다.
  - `node_modules`와 `ios/Pods`는 MANUAL이고, lockfile이 없으면 `node_modules`는 BLOCKED입니다.
- **AI 도구**: 대화·세션·기록·인증·설정·메모리·플러그인은 보호합니다. 로컬 모델은 캐시가 아니며 MANUAL입니다(Ollama는 `ollama rm`, 사용 중인 모델은 BLOCKED).

## 테스트에서의 데이터 안전

자동 테스트는 각 테스트 전용 임시 폴더(`$TMPDIR/ClearTests-<UUID>`)와 `MockFileSystem`만 사용합니다. 실제 사용자 캐시나 프로젝트는 지우지 않습니다. 개발 중 실제 사용자 데이터로 정리를 실행한 적도 없습니다.
