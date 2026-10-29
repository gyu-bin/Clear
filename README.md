# Clear

더 깨끗하고 가벼운 Mac — 개인용 macOS 저장공간 관리 앱.

일반 캐시·로그 정리, 디스크 트리맵 분석, 앱 제거, 중복 파일·비슷한 사진 찾기, 개발 도구(Xcode·npm·Gradle·Homebrew·Docker)와 AI 도구(Claude Code·Codex·Cursor·Ollama 등) 데이터 관리를 한 앱에서 합니다. 완전히 로컬에서 동작하며 데이터를 외부로 보내지 않습니다.

## 설치

**[⬇ Clear.dmg 내려받기 (최신 버전)](https://github.com/gyu-bin/Clear/releases/latest/download/Clear.dmg)** · macOS 14 이상

Clear는 Apple 공증을 받지 않은 개인용 앱이라, 내려받은 그대로 열면 macOS가 "'Clear.dmg'을(를) 열지 않음"이라며 막습니다. 아래 두 방법 중 하나로 한 번만 허용하면 됩니다.

**방법 A — 터미널 (가장 간단)**: 내려받은 파일의 차단 표시를 지운 뒤 엽니다.

```bash
xattr -d com.apple.quarantine ~/Downloads/Clear.dmg
```

**방법 B — 시스템 설정**: 경고 창에서 **완료**를 누르고(휴지통으로 이동 ✕), 시스템 설정 → 개인정보 보호 및 보안 맨 아래의 **그래도 열기**를 누릅니다. 앱을 처음 실행할 때 또 막히면 같은 방법으로 한 번 더 허용합니다.

그다음:

1. `Clear.dmg`를 엽니다.
2. **Clear**를 **Applications** 폴더로 끌어다 놓습니다.
3. 디스크 전체를 분석하려면 시스템 설정 → 개인정보 보호 및 보안 → **전체 디스크 접근 권한**에서 Clear를 켭니다.

이전 버전은 [Releases](https://github.com/gyu-bin/Clear/releases)에서 받을 수 있습니다.

## 개발 요구 사항

- macOS 14 이상
- Xcode 16 이상 (개발 환경: Xcode 27.1, Swift 6)

## 빌드와 실행

```bash
open Clear.xcodeproj
```

또는 명령줄에서 Release 앱과 설치용 DMG 만들기:

```bash
scripts/build-app.sh
```

`dist/`에 `Clear.app`, `Clear.zip`, `Clear.dmg`가 생깁니다. DMG를 열고 Clear를 Applications 폴더로 끌어다 놓으면 설치됩니다.

## 테스트

앱 창을 띄우지 않고 단위 테스트 실행:

```bash
scripts/run-headless-tests.sh
```

## 안전 원칙

- 모든 정리는 확인 화면을 거치고, 실행 직전 항목마다 경로·식별자·실행 중인 앱을 다시 검증합니다.
- 사용자 파일·앱·중복 파일·모델은 항상 휴지통으로 이동합니다.
- 대화 기록, 인증 정보, 소스 코드, `.git`, 키 파일 등은 보호됩니다.
- 관리자 권한(sudo)을 사용하지 않으며 App Sandbox 없이 실행되는 개인용 앱입니다.

자세한 내용은 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/SAFETY.md](docs/SAFETY.md), [docs/TESTING.md](docs/TESTING.md), [docs/STATUS.md](docs/STATUS.md)를 참고하세요.
