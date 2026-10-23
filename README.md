# Clear

더 깨끗하고 가벼운 Mac — 개인용 macOS 저장공간 관리 앱.

일반 캐시·로그 정리, 디스크 트리맵 분석, 앱 제거, 중복 파일·비슷한 사진 찾기, 개발 도구(Xcode·npm·Gradle·Homebrew·Docker)와 AI 도구(Claude Code·Codex·Cursor·Ollama 등) 데이터 관리를 한 앱에서 합니다. 완전히 로컬에서 동작하며 데이터를 외부로 보내지 않습니다.

## 요구 사항

- macOS 14 이상
- Xcode 16 이상 (개발 환경: Xcode 27.1, Swift 6)

## 빌드와 실행

```bash
open Clear.xcodeproj
```

또는 명령줄에서 Release 앱 만들기:

```bash
scripts/build-app.sh
```

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
