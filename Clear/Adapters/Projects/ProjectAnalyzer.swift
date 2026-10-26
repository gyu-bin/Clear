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
    var candidates: [CleanupCandidate]
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
        "pem", "p12", "p8", "key", "keystore", "jks", "mobileprovision", "cer",
    ]
    /// Databases may hold user data — but inside build output they are the build
    /// system's own caches (Xcode's build.db, test result metadata.db).
    static let databaseExtensions: Set<String> = ["sqlite", "db", "realm"]

    static func isSensitive(_ name: String, includingDatabases: Bool = true) -> Bool {
        if sensitiveNames.contains(name) { return true }
        if name == ".env" || name.hasPrefix(".env.") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return sensitiveExtensions.contains(ext) || (includingDatabases && databaseExtensions.contains(ext))
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
            if risk != .blocked, item.role != .dependency,
               let secret = Self.findSensitiveFile(in: target.path, includingDatabases: item.role != .build) {
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
        if isGit {
            for c in await ignoredOutputs(root: root, path: path, covered: candidates.compactMap(\.path), guards: guards, ctx: ctx) {
                if c.category == .projectDependencies { dependencies += c.size.allocated } else { build += c.size.allocated }
                candidates.append(c)
            }
        }
        if !isGit { notes.append("Git 저장소가 아니므로 추적 여부를 확인할 수 없습니다. 생성 폴더만 후보로 표시합니다.") }
        if total.inaccessibleCount > 0 { notes.append("일부 폴더에 접근할 수 없어 크기가 실제보다 작게 표시될 수 있습니다.") }

        return ProjectReport(path: path, name: root.lastPathComponent, kinds: kinds, packageManager: packageManager,
                             total: total, dependencies: dependencies, build: build, cache: cache,
                             candidates: candidates, analyzedAt: Date(), isGitRepository: isGit, notes: notes)
    }

    // MARK: Git-ignored outputs

    /// Ignored folders that are build output by name.
    static let buildNames: Set<String> = [
        "build", "dist", "out", ".next", ".nuxt", ".output", ".svelte-kit", ".cxx", ".gradle", ".expo",
        "DerivedData", "coverage", ".turbo", ".parcel-cache", ".cache", "target", ".build", "storybook-static", ".godot",
    ]
    /// Ignored folders that are installed dependencies.
    static let dependencyNames: Set<String> = ["node_modules", "Pods", ".venv", "venv", "vendor"]
    /// Ignored paths through these are never proposed (tool settings, secrets, history).
    static let skippedComponents: Set<String> = [
        ".git", ".claude", ".codex", ".cursor", ".gemini", ".idea", ".vscode", ".fleet", ".env", "secrets", "credentials",
    ]
    static let ignoredMinimumSize: Int64 = 20 * 1024 * 1024

    /// Large folders and files Git ignores (build output, QA reports, renders…), found
    /// anywhere in the project. Anything containing tracked files or secrets is blocked.
    func ignoredOutputs(root: URL, path: String, covered: [String], guards: [ProcessGuard], ctx: ScanContext) async -> [CleanupCandidate] {
        guard let result = try? await ctx.commandRunner.run(
            .git, ["-C", path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], timeout: 60),
              result.succeeded else { return [] }
        let entries = result.stdout.split(separator: "\0").prefix(5000).map(String.init)
        var out: [CleanupCandidate] = []
        var taken = covered
        for entry in entries {
            if Task.isCancelled { break }
            let rel = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let parts = rel.split(separator: "/").map(String.init)
            guard let name = parts.last, !rel.isEmpty, !rel.hasPrefix("../") else { continue }
            if parts.contains(where: { Self.skippedComponents.contains($0) || $0.hasPrefix(".env") }) { continue }
            if Self.isSensitive(name) { continue }
            let target = root.appendingPathComponent(rel)
            let canonical = PathUtilities.canonicalPath(target.path) ?? target.path
            if taken.contains(where: { PathUtilities.isSameOrDescendant(canonical, of: $0) || PathUtilities.isSameOrDescendant($0, of: canonical) }) { continue }

            let isDependency = parts.contains { Self.dependencyNames.contains($0) }
            let isBuild = !isDependency && (parts.contains { Self.buildNames.contains($0) } || name.hasSuffix(".noindex")
                || ["apk", "aab", "ipa", "xcarchive", "dSYM"].contains((name as NSString).pathExtension))
            let risk: RiskLevel = isBuild ? .review : .manual
            let reason = isDependency ? "Git이 제외한 설치된 의존성 — 다시 설치해야 함"
                : isBuild ? "Git이 제외한 빌드 결과물 — 다음 빌드 때 다시 만들어짐"
                : "Git이 제외한 생성 파일(보고서·스크린샷·렌더 등)로 보임 — 직접 확인하세요"
            let impact = isDependency ? "패키지 매니저로 다시 설치해야 합니다."
                : isBuild ? "다음 빌드가 처음부터 다시 수행되어 오래 걸릴 수 있습니다."
                : "휴지통으로 이동합니다. 필요하면 휴지통에서 되돌릴 수 있습니다."
            ctx.progress(ScanProgress(phase: "\(root.lastPathComponent) 분석 중", detail: rel))
            let spec = CandidateSpec(
                id: "project:\(path)/\(rel)", title: rel,
                subtitle: PathUtilities.abbreviated(target.path, home: ctx.home.path),
                category: isDependency ? .projectDependencies : .projectBuild,
                ruleID: isDependency ? "project.ignored.dependency" : isBuild ? "project.ignored.build" : "project.ignored.other",
                risk: risk, riskReason: reason, impact: impact,
                regenerable: isDependency || isBuild, guards: guards,
                preferredMethod: isBuild || isDependency ? .permanent : .trash,
                allowsPermanentRemoval: isBuild || isDependency,
                minimumSize: Self.ignoredMinimumSize)
            // Measured first (small items are dropped), then checked — git runs only for what is shown.
            guard var c = ctx.makeCandidate(at: target, root: root, spec: spec) else { continue }
            if c.risk != .blocked {
                if await isTrackedByGit(rel, in: path, runner: ctx.commandRunner) {
                    c.risk = .blocked; c.riskReason = "Git이 추적하는 파일이 포함되어 있음"
                } else if !isDependency, ctx.isDirectory(target),
                          let secret = Self.findSensitiveFile(in: target.path, includingDatabases: !isBuild) {
                    c.risk = .blocked; c.riskReason = "민감한 파일 포함: \(PathUtilities.abbreviated(secret))"
                }
            }
            taken.append(canonical)
            out.append(c)
        }
        return out.sorted { $0.estimatedBytes > $1.estimatedBytes }
    }

    /// `git ls-files -z -- <path>` non-empty → something under it is tracked.
    func isTrackedByGit(_ relativePath: String, in project: String, runner: CommandRunning) async -> Bool {
        guard let result = try? await runner.run(.git, ["-C", project, "ls-files", "-z", "--", relativePath], timeout: 30) else {
            return true // fail closed
        }
        guard result.succeeded else { return true }
        return !result.stdout.isEmpty
    }

    /// First secret-looking file found (stops early). Skips installed dependencies.
    static func findSensitiveFile(in path: String, includingDatabases: Bool = true) -> String? {
        var found: String?
        try? FTSWalker(root: path).walk { entry in
            let name = (entry.path as NSString).lastPathComponent
            // Installed packages ship public certificates and test keys; they are not the user's secrets.
            if entry.kind == .directoryPre, entry.level > 0, dependencyNames.contains(name) || name == "site-packages" {
                return .skipDescendants
            }
            if entry.kind == .file, isSensitive(name, includingDatabases: includingDatabases) { found = entry.path; return .stop }
            return .continue
        }
        return found
    }
}
