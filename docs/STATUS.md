# 구현 상태 (2026-10-23)

이 문서는 실제로 확인한 사실만 적습니다. "구현됨"은 코드가 있고 빌드된다는 뜻이며, 검증 방법을 따로 적었습니다.

## 빌드·테스트

| 항목 | 결과 |
|---|---|
| Debug 빌드 (`xcodebuild … -configuration Debug build`) | 성공, 경고 없음 |
| Release 빌드 | 성공 |
| 테스트 타깃 컴파일 (`build-for-testing`) | 성공 |
| 단위·파일 시스템·안전 정책 테스트 (`scripts/run-headless-tests.sh`) | 93개 통과 / 실패 0 |
| 시작 시 충돌 | 원인을 찾아 수정함(`MenuBarExtra` → `NSStatusItem`, 자세한 내용은 ARCHITECTURE.md). `MenuBarExtra`를 뺀 빌드는 10회 실행 모두 정상. 최종 반복 실행 검증은 진행 중 |

## 구현 완료 (코드 + 자동 테스트)

- 안전 엔진: 허용 루트, 보호 경로(상위 폴더 포함), 경로 구성요소 비교, 심볼릭 링크·TOCTOU 방어, 식별자 재검증, 볼륨·소유자·권한 확인, 프로세스 가드
- 삭제 실행: 휴지통 우선, descriptor 기반 `SafeRemover`, 항목별 실패 격리, 취소, 정리 기록, 볼륨 재측정
- 스캔: 디렉터리 크기(논리/할당/하드 링크 공유 구분), 접근 제한 표시, 디스크 트리, 대용량·오래된 파일, 파일 유형별 사용량
- Smart Cleanup 규칙: 앱 캐시(지식 베이스), 로그, 창 복원 정보, 오래된 임시 항목, 다운로드 폴더의 큰 파일·설치 파일, 휴지통 크기 표시
- 개발자 도구: Xcode(DerivedData, 캐시, Device Support, Previews, `simctl`로만 시뮬레이터 정리, Archives는 보호), npm/Yarn/pnpm(`pnpm store prune`), Expo/Metro/CocoaPods, Gradle/Android Studio, Homebrew(`brew cleanup -n` 결과를 먼저 표시), Docker(`docker system df` 분석, 볼륨 제외)
- 개발 프로젝트 분석: 종류·패키지 매니저 감지, 소스/의존성/빌드/캐시 구분, Git 추적·비밀 파일 차단
- AI 도구: Claude Code, Codex, Cursor, Claude 데스크톱, Ollama(`ollama rm`), LM Studio, Hugging Face, Gemini CLI. 기록·인증·설정 보호
- 앱 관리: 설치 앱 목록, 크기, Spotlight 마지막 사용일, 번들 ID·서명 그룹 기반 관련 파일, 휴지통으로 제거
- 중복 파일: 크기 → 부분 해시 → 전체 SHA-256, 하드 링크·iCloud 전용 파일·사진 보관함 처리, 보존 파일 유지 규칙

## 부분 구현 / 수동 확인 필요

- **화면(UI)**: 9개 메뉴 화면은 모두 코드가 있고 빌드됩니다. 하지만 실제 앱에서 눈으로 확인한 것은 **Overview 첫 화면뿐**입니다. 나머지 화면의 배치·상호작용·다크/라이트 전환·창 크기 대응은 아직 직접 확인하지 않았습니다.
- **비슷한 사진**: Vision 특징값 비교는 구현했지만, 유사도 기준값(기본 0.35)을 실제 사진으로 조정하지 않았습니다.
- **메뉴 막대·알림·자동 스캔**: 구현했지만 실제 동작(알림 표시, 주기 실행)은 확인하지 않았습니다.
- **VoiceOver·키보드 탐색·Reduce Motion**: 접근성 레이블과 Reduce Motion 처리는 코드에 있지만 VoiceOver로 확인하지 않았습니다.

## 직접 검증하지 못한 것

- 실제 사용자 데이터로 정리 실행. 의도적으로 하지 않았고, 정리 경로는 임시 폴더와 Mock으로만 검증했습니다.
- Docker, Ollama, LM Studio: 이 Mac에 설치되어 있지 않아 실제 출력으로 확인하지 못했습니다(파싱은 예제 출력으로 테스트).
- 외장 드라이브 스캔, 전체 디스크 접근 권한을 줬을 때와 안 줬을 때의 차이
- 메모리·CPU 프로파일링(Instruments)
- 앱 번들을 휴지통으로 옮길 때 macOS "앱 관리" 권한이 필요한 경우의 동작

## 해결된 문제

- `~/.Trash`가 없을 때 "접근 제한"으로 잘못 표시되던 문제 → 빈 휴지통으로 처리
- Overview 사용량 링 그라디언트에 다른 색이 섞이던 문제 → 상태 색 한 가지로 통일

## 다음 작업

1. 시작 안정성 반복 검증을 마치고 각 화면을 실제로 열어 확인(라이트/다크, 좁은 창).
2. 비슷한 사진 기준값 조정, VoiceOver 점검, Instruments로 대용량 스캔 메모리 확인.
3. Release 빌드를 공증 없이 개인용으로 설치하는 방법 정리.
