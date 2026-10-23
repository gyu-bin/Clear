import Foundation

struct ProjectReport: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let kinds: [String]
    let packageManager: String?
    let total: SizeInfo
    let dependencies: Int64
    let build: Int64
    let cache: Int64
    let candidates: [CleanupCandidate]
    let analyzedAt: Date
    let isGitRepository: Bool
    let notes: [String]

    var source: Int64 { max(0, total.allocated - dependencies - build - cache) }
    var cleanable: Int64 { candidates.filter { $0.risk != .blocked }.reduce(0) { $0 + $1.estimatedBytes } }
}

/// Analyzes a user-registered development project. Only well-known generated
/// directories are ever proposed, and each one is checked against Git tracking
/// and for secrets before it can be selected.
struct ProjectAnalyzer: Sendable {
    enum Role { case dependency, build, cache }

    struct Known {
        let relativePath: String
        let role: Role
        let title: String
        let impact: String
        /// Required marker files (relative to project) for the folder to be considered generated.
        let requires: [String]
    }

    static let known: [Known] = [
        Known(relativePath: "node_modules", role: .dependency, title: "node_modules",
              impact: "패키지 매니저로 의존성을 다시 설치해야 합니다.", requires: ["package.json"]),
        Known(relativePath: "ios/Pods", role: .dependency, title: "CocoaPods (ios/Pods)",
              impact: "`pod install`(또는 `npx pod-install`)을 다시 실행해야 합니다.", requires: ["ios/Podfile"]),
        Known(relativePath: ".expo", role: .cache, title: ".expo", impact: "Expo CLI가 다시 만듭니다.", requires: []),
        Known(relativePath: "android/build", role: .build, title: "android/build", impact: "다음 Android 빌드 때 다시 만들어집니다.", requires: ["android"]),
        Known(relativePath: "android/app/build", role: .build, title: "android/app/build", impact: "다음 Android 빌드 때 다시 만들어집니다.", requires: ["android/app"]),
        Known(relativePath: "android/.gradle", role: .cache, title: "android/.gradle", impact: "Gradle이 다시 만듭니다.", requires: ["android"]),
        Known(relativePath: "android/app/.cxx", role: .build, title: "android/app/.cxx", impact: "네이티브 빌드가 다시 수행됩니다.", requires: ["android/app"]),
        Known(relativePath: "ios/build", role: .build, title: "ios/build", impact: "다음 iOS 빌드 때 다시 만들어집니다.", requires: ["ios"]),
        Known(relativePath: ".build", role: .build, title: ".build (SwiftPM)", impact: "다음 swift build 때 다시 만들어집니다.", requires: ["Package.swift"]),
        Known(relativePath: ".next", role: .build, title: ".next", impact: "다음 Next.js 빌드 때 다시 만들어집니다.", requires: ["package.json"]),
        Known(relativePath: ".turbo", role: .cache, title: ".turbo", impact: "Turborepo 캐시가 다시 만들어집니다.", requires: ["package.json"]),
        Known(relativePath: ".parcel-cache", role: .cache, title: ".parcel-cache", impact: "Parcel이 다시 만듭니다.", requires: ["package.json"]),
        Known(relativePath: "node_modules/.cache", role: .cache, title: "node_modules/.cache", impact: "도구가 다시 만듭니다.", requires: ["package.json"]),
    ]

    static let sensitiveNames: Set<String> = [
        "google-services.json", "GoogleService-Info.plist", "credentials.json", "secrets.json", "id_rsa", "id_ed25519",
    ]
    static let sensitiveExtensions: Set<String> = [
        "pem", "p12", "p8", "key", "keystore", "jks", "mobileprovision", "cer", "sqlite", "db", "realm",
    ]

    static func isSensitive(_ name: String) -> Bool {
        if sensitiveNames.contains(name) { return true }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        return sensitiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    func analyze(projectAt url: URL, ctx: ScanContext) async -> ProjectReport {
        let path = PathUtilities.canonicalPath(url.path) ?? url.path
        let root = URL(fileURLWithPath: path)
        func has(_ rel: String) -> Bool { ctx.exists(root.appendingPathComponent(rel)) }

        var kinds: [String] = []
        let pkg = (try? Data(contentsOf: root.appendingPathComponent("package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let deps = ((pkg?["dependencies"] as? [String: Any]) ?? [:]).merging((pkg?["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
        if deps["expo"] != nil { kinds.append("Expo") }
        if deps["react-native"] != nil { kinds.append("React Native") }
        if pkg != nil && kinds.isEmpty { kinds.append("Node.js") }
        if has("Package.swift") { kinds.append("Swift Package") }
        if (ctx.children(of: root) ?? []).contains(where: { ["xcodeproj", "xcworkspace"].contains($0.pathExtension) }) { kinds.append("Xcode") }
        if has("android/build.gradle") || has("android/build.gradle.kts") || has("build.gradle") || has("build.gradle.kts") { kinds.append("Gradle") }

        let packageManager: String? = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "Yarn"
            : has("bun.lockb") || has("bun.lock") ? "Bun" : has("package-lock.json") ? "npm" : (pkg != nil ? "npm (lockfile 없음)" : nil)
        let isGit = has(".git")
        var notes: [String] = []

        let sizer = DirectorySizer()
        let total = (try? sizer.measure(path: path)) ?? .zero
        var dependencies: Int64 = 0, build: Int64 = 0, cache: Int64 = 0
        var candidates: [CleanupCandidate] = []
        let guards: [ProcessGuard] = [.commandLine(path.lowercased(), "이 프로젝트의 개발 서버·빌드")]
            + (kinds.contains("Xcode") || has("ios") ? DeveloperGuards.xcode : [])

        for item in Self.known {
            try? Task.checkCancellation()
            let target = root.appendingPathComponent(item.relativePath)
            guard ctx.isDirectory(target), item.requires.allSatisfy(has) else { continue }
            ctx.progress(ScanProgress(phase: "\((path as NSString).lastPathComponent) 분석 중", detail: item.relativePath))

            var risk: RiskLevel = item.role == .dependency ? .manual : .review
            var reason = item.role == .dependency ? "재설치가 필요한 의존성 — 직접 선택해야 정리됩니다" : "다시 만들어지는 생성 파일"
            var impact = item.impact
            if item.relativePath == "node_modules", let pm = packageManager { impact = "`\(pm.split(separator: " ").first ?? "npm") install`로 다시 설치해야 합니다." }
            if item.relativePath == "node_modules", packageManager?.contains("없음") == true {
                risk = .blocked; reason = "lockfile이 없어 같은 의존성을 다시 설치할 수 있는지 보장되지 않음"
            }
            if isGit, await isTrackedByGit(item.relativePath, in: path, runner: ctx.commandRunner) {
                risk = .blocked; reason = "Git이 추적하는 파일이 포함되어 있음"
            }
            if risk != .blocked, item.role != .dependency, let secret = Self.findSensitiveFile(in: target.path) {
                risk = .blocked; reason = "민감한 파일 포함: \(PathUtilities.abbreviated(secret))"
            }
            let spec = CandidateSpec(
                id: "project:\(path)/\(item.relativePath)", title: item.title,
                subtitle: PathUtilities.abbreviated(target.path, home: ctx.home.path),
                category: item.role == .dependency ? .projectDependencies : .projectBuild,
                ruleID: "project.\(item.relativePath)", risk: risk, riskReason: reason, impact: impact,
                regenerable: true, guards: guards, minimumSize: 1)
            guard let c = ctx.makeCandidate(at: target, root: root, spec: spec) else { continue }
            if item.relativePath == "node_modules/.cache" { cache += 0 } // already inside node_modules
            else {
                switch item.role {
                case .dependency: dependencies += c.size.allocated
                case .build: build += c.size.allocated
                case .cache: cache += c.size.allocated
                }
            }
            candidates.append(c)
        }
        if !isGit { notes.append("Git 저장소가 아니므로 추적 여부를 확인할 수 없습니다. 생성 폴더만 후보로 표시합니다.") }
        if total.inaccessibleCount > 0 { notes.append("일부 폴더에 접근할 수 없어 크기가 실제보다 작게 표시될 수 있습니다.") }

        return ProjectReport(path: path, name: root.lastPathComponent, kinds: kinds, packageManager: packageManager,
                             total: total, dependencies: dependencies, build: build, cache: cache,
                             candidates: candidates, analyzedAt: Date(), isGitRepository: isGit, notes: notes)
    }

    /// `git ls-files -z -- <path>` non-empty → something under it is tracked.
    func isTrackedByGit(_ relativePath: String, in project: String, runner: CommandRunning) async -> Bool {
        guard let result = try? await runner.run(.git, ["-C", project, "ls-files", "-z", "--", relativePath], timeout: 30) else {
            return true // fail closed
        }
        guard result.succeeded else { return true }
        return !result.stdout.isEmpty
    }

    /// First secret-looking file found (stops early). Does not descend into node_modules.
    static func findSensitiveFile(in path: String) -> String? {
        var found: String?
        try? FTSWalker(root: path).walk { entry in
            let name = (entry.path as NSString).lastPathComponent
            if entry.kind == .directoryPre, name == "node_modules", entry.level > 0 { return .skipDescendants }
            if entry.kind == .file, isSensitive(name) { found = entry.path; return .stop }
            return .continue
        }
        return found
    }
}
