import Foundation

/// Static description of what may and may not be removed.
///
/// Two independent lists are applied:
/// 1. **Allowed roots** — removal is only possible strictly *inside* one of them.
/// 2. **Protected locations** — never removable, regardless of which rule proposed them.
///    `exact` protects the directory itself (and therefore everything above it, since
///    removing an ancestor would remove it too); `subtree` additionally protects
///    everything inside it. Name-based protections catch things like `.git` or
///    `*.photoslibrary` wherever they appear.
struct SafetyPolicy: Sendable {
    enum Scope: Sendable { case exact, subtree }

    struct Protection: Sendable {
        let path: String
        let scope: Scope
        let reason: String
    }

    let home: String
    private(set) var allowedRoots: [String]
    private(set) var protections: [Protection]
    /// Path components that are protected anywhere (exact match).
    let protectedComponentNames: [String: String]
    /// Path component suffixes that are protected anywhere.
    let protectedComponentSuffixes: [String: String]
    /// Inside these folders, files with these extensions are protected at any depth
    /// (conversation logs, databases, settings of AI tools).
    let protectedFilesInTrees: [(tree: String, suffixes: [String], reason: String)]
    /// Narrow carve-outs from subtree protections (e.g. Mail's attachment copies
    /// inside the otherwise protected Mail container).
    let protectionExceptions: [String]
    /// User-configured exclusions (subtree).
    var exclusions: [String]

    init(home: URL = PathUtilities.realHomeDirectory,
         temporaryDirectory: URL = PathUtilities.userTemporaryDirectory,
         extraAllowedRoots: [URL] = [],
         exclusions: [String] = []) {
        let h = PathUtilities.canonicalPath(home.path) ?? home.path
        self.home = h
        func p(_ rel: String) -> String { h + "/" + rel }

        var roots = [
            p("Library/Caches"), p("Library/Logs"), p("Library/Saved Application State"),
            p("Library/Developer"), p("Downloads"),
            p(".npm"), p(".gradle"), p(".android"), p(".expo"), p(".cache"),
            p("Library/pnpm/store"), p(".yarn/berry/cache"), p(".Trash"),
            p(".m2"), p(".cocoapods"), p(".cargo"), p(".pub-cache"), p(".bun"), p(".node-gyp"),
            p(".electron-gyp"), p(".nuget"), p(".composer"), p("Library/iTunes"), p("Desktop"),
            p(".claude"), p(".codex"), p(".ollama"), p(".lmstudio"),
            p("Library/Application Support/Cursor"), p("Library/Application Support/Claude"),
            p("Library/Application Support/Code"),
            // App uninstall locations
            "/Applications", p("Applications"),
            p("Library/Application Support"), p("Library/Preferences"), p("Library/Containers"),
            p("Library/Group Containers"), p("Library/HTTPStorages"), p("Library/WebKit"),
            p("Library/Cookies"), p("Library/LaunchAgents"),
            temporaryDirectory.path,
        ]
        roots += extraAllowedRoots.map { PathUtilities.canonicalPath($0.path) ?? $0.path }
        self.allowedRoots = roots

        let exactOnly: [(String, String)] = [
            ("/", "시스템 루트"), ("/Applications", "응용 프로그램 폴더"), ("/Users", "사용자 폴더 목록"),
            ("/Library", "시스템 Library"), ("/Volumes", "볼륨 목록"),
            (h, "홈 폴더"), (p("Library"), "사용자 Library"), (p("Library/Caches"), "캐시 폴더 자체"),
            (p("Library/Logs"), "로그 폴더 자체"), (p("Library/Application Support"), "Application Support 폴더 자체"),
            (p("Library/Preferences"), "환경설정 폴더 자체"), (p("Library/Containers"), "컨테이너 폴더 자체"),
            (p("Library/Group Containers"), "그룹 컨테이너 폴더 자체"), (p("Library/Developer"), "Developer 폴더 자체"),
            (p("Library/Developer/Xcode"), "Xcode 폴더 자체"), (p("Library/Developer/CoreSimulator"), "시뮬레이터 폴더 자체"),
            (p("Downloads"), "다운로드 폴더 자체"), (p("Documents"), "문서 폴더"), (p("Desktop"), "데스크탑 폴더"),
            (p("Pictures"), "사진 폴더"), (p("Movies"), "동영상 폴더"), (p("Music"), "음악 폴더"),
            (p("Applications"), "사용자 응용 프로그램 폴더"), (p(".npm"), "npm 폴더 자체"),
            (p(".gradle"), "Gradle 폴더 자체"), (p(".gradle/caches"), "Gradle 캐시 루트 — Gradle 자체 정리 정책 존중"),
            (p(".android"), "Android 설정 폴더"), (p(".cache"), ".cache 폴더 자체"),
            (p(".claude"), "Claude Code 데이터 폴더"), (p(".codex"), "Codex 데이터 폴더"),
            (p(".ollama"), "Ollama 데이터 폴더"), (p(".lmstudio"), "LM Studio 데이터 폴더"),
            (p(".expo"), "Expo 데이터 폴더"), (p("Library/Developer/Xcode/UserData"), "Xcode 사용자 데이터 폴더"),
            (temporaryDirectory.path, "임시 폴더 자체"), (p(".Trash"), "휴지통 폴더 자체"),
            (p(".m2"), "Maven 폴더 자체"), (p(".cocoapods"), "CocoaPods 폴더 자체"), (p(".cargo"), "Cargo 폴더 자체"),
            (p(".pub-cache"), "Dart/Flutter 폴더 자체"), (p(".bun"), "Bun 폴더 자체"), (p(".nuget"), "NuGet 폴더 자체"),
            (p(".composer"), "Composer 폴더 자체"), (p("Library/iTunes"), "iTunes 폴더 자체"),
        ]
        let subtrees: [(String, String)] = [
            ("/System", "macOS 시스템"), ("/usr", "시스템 바이너리"), ("/bin", "시스템 바이너리"),
            ("/sbin", "시스템 바이너리"), ("/private/etc", "시스템 설정"), ("/private/var/db", "시스템 데이터베이스"),
            ("/Library/Apple", "Apple 시스템 구성요소"), ("/System/Volumes", "시스템 볼륨"),
            (p("Library/Keychains"), "키체인"), (p("Library/Mobile Documents"), "iCloud Drive"),
            (p("Library/CloudStorage"), "클라우드 저장소"), (p("Library/Mail"), "메일 데이터"),
            (p("Library/Messages"), "메시지 데이터"), (p("Library/Photos"), "사진 데이터"),
            (p("Library/Accounts"), "계정 정보"), (p("Library/Calendars"), "캘린더"),
            (p("Library/Containers/com.apple.mail"), "메일 데이터"), (p("Library/Group Containers/group.com.apple.notes"), "메모"),
            (p("Library/Application Support/MobileSync"), "iPhone 백업 — 직접 관리 필요"),
            (p("Library/Application Support/AddressBook"), "연락처"),
            (p(".ssh"), "SSH 키"), (p(".gnupg"), "GPG 키"), (p(".aws"), "AWS 자격 증명"),
            (p(".config/gh"), "GitHub CLI 인증"), (p(".docker/config.json"), "Docker 인증"),
            (p(".netrc"), "인증 정보"), (p(".npmrc"), "npm 인증"),
            // AI tools: history, sessions, credentials, memory, settings
            (p(".claude/projects"), "Claude Code 대화 기록"), (p(".claude/sessions"), "Claude Code 세션"),
            (p(".claude/history.jsonl"), "Claude Code 기록"), (p(".claude/settings.json"), "Claude Code 설정"),
            (p(".claude/file-history"), "Claude Code 체크포인트"), (p(".claude/plugins"), "Claude Code 플러그인"),
            (p(".claude/skills"), "Claude Code 스킬"), (p(".claude/rules"), "Claude Code 규칙"),
            (p(".claude/backups"), "Claude Code 설정 백업"), (p(".claude/state"), "Claude Code 상태"),
            (p(".claude/session-env"), "Claude Code 세션 환경"), (p(".claude.json"), "Claude Code 설정"),
            (p(".codex/sessions"), "Codex 세션"), (p(".codex/auth.json"), "Codex 인증"),
            (p(".codex/config.toml"), "Codex 설정"), (p(".codex/worktrees"), "Codex 작업 트리"),
            (p(".codex/memories"), "Codex 메모리"), (p(".codex/skills"), "Codex 스킬"),
            (p(".codex/plugins"), "Codex 플러그인"), (p(".codex/agents"), "Codex 에이전트 설정"),
            (p(".codex/automations"), "Codex 자동화"),
            (p(".ollama/models"), "Ollama 모델 — ollama rm으로만 제거"),
            (p(".ollama/id_ed25519"), "Ollama 키"),
            (p(".expo/state.json"), "Expo 로그인 정보"), (p(".expo/codesigning"), "Expo 코드 서명"),
            (p(".android/debug.keystore"), "Android 서명 키"), (p(".android/avd"), "Android 에뮬레이터 — 직접 관리"),
            (p(".gradle/gradle.properties"), "Gradle 설정(자격 증명 포함 가능)"),
            (p(".cargo/bin"), "설치된 Rust 도구"), (p(".cargo/credentials.toml"), "Cargo 인증"), (p(".cargo/credentials"), "Cargo 인증"),
            (p(".m2/settings.xml"), "Maven 설정(자격 증명 포함 가능)"), (p(".bun/bin"), "설치된 Bun"),
            (p(".pub-cache/credentials.json"), "pub 인증"), (p(".composer/auth.json"), "Composer 인증"),
            (p("Library/Application Support/Cursor/User"), "Cursor 사용자 설정 및 기록"),
            (p("Library/Application Support/Code/User"), "VS Code 사용자 설정"),
            (p("Library/Application Support/Claude/claude-code-sessions"), "Claude 세션"),
            (p("Library/Application Support/Claude/local-agent-mode-sessions"), "Claude 세션"),
            (p("Library/Developer/Xcode/Archives"), "Xcode Archives — 배포/디버깅에 필요"),
            (p("Library/Developer/Xcode/UserData/CodeSnippets"), "Xcode 코드 스니펫"),
            (p("Library/Developer/Xcode/UserData/FontAndColorThemes"), "Xcode 테마"),
            (p("Library/Developer/Xcode/UserData/KeyBindings"), "Xcode 단축키"),
            (p("Library/Developer/Xcode/UserData/Provisioning Profiles"), "프로비저닝 프로파일"),
            (p("Library/Developer/Xcode/UserData/xcdebugger"), "Xcode 브레이크포인트"),
            (p("Library/Developer/Xcode/UserData/IB Support"), "Interface Builder 설정"),
            (p("Library/Developer/CoreSimulator/Devices"), "시뮬레이터 — simctl로만 제거"),
        ]
        protections = exactOnly.map { Protection(path: $0.0, scope: .exact, reason: $0.1) }
            + subtrees.map { Protection(path: $0.0, scope: .subtree, reason: $0.1) }

        protectedComponentNames = [
            ".git": "Git 저장소", ".ssh": "SSH 키", ".gnupg": "GPG 키", "Backups.backupdb": "Time Machine 백업",
            ".Trashes": "볼륨 휴지통", ".Spotlight-V100": "Spotlight 색인", ".DocumentRevisions-V100": "문서 버전",
            ".fseventsd": "파일 시스템 이벤트",
        ]
        protectionExceptions = [p("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")]
        protectedFilesInTrees = [
            (p(".codex"), [".sqlite", ".sqlite-wal", ".sqlite-shm", ".jsonl", ".json", ".toml", ".md"], "Codex 기록·설정"),
            (p(".claude"), [".jsonl", ".json", ".md", ".sqlite"], "Claude Code 기록·설정"),
            (p(".gemini"), [".json", ".jsonl", ".md", ".toml"], "Gemini CLI 기록·설정"),
            (p(".cursor"), [".json", ".jsonl", ".sqlite", ".vscdb"], "Cursor 데이터"),
        ]
        protectedComponentSuffixes = [
            ".photoslibrary": "사진 보관함", ".backupdb": "Time Machine 백업", ".previousSystem": "이전 시스템",
            ".keychain": "키체인", ".keychain-db": "키체인", ".sparsebundle": "디스크 이미지 번들",
        ]
        self.exclusions = exclusions.map { PathUtilities.canonicalPath($0) ?? $0 }
    }

    mutating func addAllowedRoots(_ urls: [URL]) {
        for url in urls {
            let path = PathUtilities.canonicalPath(url.path) ?? url.path
            if !allowedRoots.contains(path) { allowedRoots.append(path) }
        }
    }

    mutating func addProtection(_ path: String, scope: Scope, reason: String) {
        protections.append(Protection(path: path, scope: scope, reason: reason))
    }

    /// Reason the canonical path is protected, or nil.
    func protectionReason(for path: String) -> String? {
        let lowerName = (path as NSString).lastPathComponent.lowercased()
        for rule in protectedFilesInTrees where PathUtilities.isStrictDescendant(path, of: rule.tree) {
            if rule.suffixes.contains(where: { lowerName.hasSuffix($0) }) { return rule.reason }
        }
        let exempt = protectionExceptions.contains { PathUtilities.isSameOrDescendant(path, of: $0) }
        for prot in protections where !exempt {
            if path == prot.path { return prot.reason }
            // Removing an ancestor of a protected location would remove it too.
            if PathUtilities.isStrictDescendant(prot.path, of: path) { return "\(prot.reason) 포함" }
            if prot.scope == .subtree, PathUtilities.isStrictDescendant(path, of: prot.path) { return prot.reason }
        }
        for component in PathUtilities.components(path) {
            if let reason = protectedComponentNames[component] { return reason }
            for (suffix, reason) in protectedComponentSuffixes where component.lowercased().hasSuffix(suffix) {
                return reason
            }
        }
        for excluded in exclusions where PathUtilities.isSameOrDescendant(path, of: excluded)
            || PathUtilities.isStrictDescendant(excluded, of: path) {
            return "사용자 제외 경로"
        }
        return nil
    }

    /// The registered allowed root that contains `path`, if any.
    func allowedRoot(containing path: String) -> String? {
        allowedRoots
            .filter { PathUtilities.isStrictDescendant(path, of: $0) }
            .max { $0.count < $1.count }
    }

    func isAllowedRoot(_ root: String) -> Bool { allowedRoots.contains(root) }
}
