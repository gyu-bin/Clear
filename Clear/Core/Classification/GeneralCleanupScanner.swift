import Foundation

struct GeneralScanReport: Sendable {
    var candidates: [CleanupCandidate] = []
    /// Size of `~/.Trash`; nil when macOS did not allow reading it.
    var trashSize: SizeInfo?
    /// Locations that could not be read (shown as "접근 제한", never as 0 B).
    var restrictedLocations: [String] = []
    /// Readable size of /Library/Logs and /private/var/log. Shown only: removing
    /// them needs administrator rights, which Clear never uses.
    var systemLogBytes: Int64?
}

/// Rules for everyday cleanup: app caches, logs, window state, old temp items,
/// and large files in Downloads.
struct GeneralCleanupScanner: Sendable {
    var logAgeForSafe: TimeInterval = 7 * 24 * 3600
    var tempAge: TimeInterval = 3 * 24 * 3600
    var downloadsLargeFile: Int64 = 200 * 1024 * 1024
    var downloadsInstallerMinimum: Int64 = 20 * 1024 * 1024
    var downloadsInstallerAge: TimeInterval = 14 * 24 * 3600

    /// Also look for leftovers of uninstalled apps, hidden caches, broken login items.
    var includeLeftovers = true
    /// Scan other apps' containers (only with Full Disk Access, otherwise macOS prompts per app).
    var includeContainers = false
    /// Claude Code's per-session scratch folders (`/private/tmp/claude-<uid>`).
    /// Must also be an allowed root of the policy.
    var agentScratchRoot: URL?

    static var defaultAgentScratchRoot: URL { URL(fileURLWithPath: "/private/tmp/claude-\(getuid())") }
    /// The shared temp folder, where build scripts and AI agents leave Xcode build
    /// folders and project copies. macOS only empties it at restart.
    /// Must also be an allowed root of the policy.
    var sharedTempRoot: URL?
    static let defaultSharedTempRoot = URL(fileURLWithPath: "/private/tmp")
    var sharedTempMinimum: Int64 = 50 * 1024 * 1024
    /// Items written more recently than this are left alone even if no process uses them.
    var sharedTempQuietPeriod: TimeInterval = 2 * 3600

    static let ownedLogFolders: Set<String> = ["Claude", "Cursor", "CoreSimulator", "JetBrains", "Google", "Homebrew"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso", "ipsw"]

    func scan(_ ctx: ScanContext, appNames: [String: String]) async throws -> GeneralScanReport {
        var report = GeneralScanReport()
        ctx.progress(ScanProgress(phase: "앱 캐시 분석 중"))
        try scanCaches(ctx, appNames: appNames, into: &report)
        try Task.checkCancellation()
        ctx.progress(ScanProgress(phase: "로그 분석 중"))
        scanLogs(ctx, into: &report)
        ctx.progress(ScanProgress(phase: "창 복원 데이터 분석 중"))
        scanSavedState(ctx, appNames: appNames, into: &report)
        try Task.checkCancellation()
        ctx.progress(ScanProgress(phase: "임시 파일 분석 중"))
        scanTemporary(ctx, into: &report)
        ctx.progress(ScanProgress(phase: "다운로드 폴더 분석 중"))
        scanDownloads(ctx, into: &report)
        if includeLeftovers {
            try Task.checkCancellation()
            LeftoverScanner(installedBundleIDs: Set(appNames.keys), includeContainers: includeContainers)
                .scan(ctx, into: &report)
        }
        if includeContainers {
            try Task.checkCancellation()
            ctx.progress(ScanProgress(phase: "앱 컨테이너의 캐시 분석 중"))
            scanContainerCaches(ctx, appNames: appNames, into: &report)
        }
        if let agentScratchRoot {
            try Task.checkCancellation()
            ctx.progress(ScanProgress(phase: "AI 에이전트 작업 폴더 분석 중"))
            scanAgentScratch(ctx, root: agentScratchRoot, into: &report)
        }
        if let sharedTempRoot {
            try Task.checkCancellation()
            ctx.progress(ScanProgress(phase: "공용 임시 폴더 분석 중"))
            scanSharedTemp(ctx, root: sharedTempRoot, into: &report)
        }
        ctx.progress(ScanProgress(phase: "스크린샷 찾는 중"))
        scanScreenshots(ctx, into: &report)
        if includeContainers { scanMailDownloads(ctx, into: &report) }
        var systemLogs = SizeInfo()
        for path in ["/Library/Logs", "/private/var/log"] {
            if let size = try? ctx.sizer.measure(path: path) { systemLogs.merge(size) }
        }
        report.systemLogBytes = systemLogs.allocated
        ctx.progress(ScanProgress(phase: "휴지통 크기 확인 중"))
        let trash = ctx.url(".Trash")
        if ctx.exists(trash) {
            if let size = try? ctx.sizer.measure(path: trash.path), size.inaccessibleCount == 0 {
                report.trashSize = size
            } else {
                report.restrictedLocations.append(trash.path)
            }
        } else {
            // A missing Trash is simply empty, not a permission problem.
            report.trashSize = .zero
        }
        return report
    }

    // MARK: - Rules

    private func scanCaches(_ ctx: ScanContext, appNames: [String: String], into report: inout GeneralScanReport) throws {
        let root = ctx.url("Library/Caches")
        guard let children = ctx.children(of: root) else {
            report.restrictedLocations.append(root.path)
            return
        }
        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            if name.hasPrefix(".") || CacheKnowledgeBase.ownedByAdapters.contains(name) { continue }
            guard ctx.isDirectory(child) else { continue }
            if name == "Google" {
                // Shared vendor folder: Chrome caches here, Android Studio caches belong to the Gradle adapter.
                for sub in ctx.children(of: child) ?? [] where !sub.lastPathComponent.hasPrefix("AndroidStudio") {
                    let isChrome = sub.lastPathComponent == "Chrome"
                    let spec = CandidateSpec(
                        title: "Google \(sub.lastPathComponent) 캐시", category: isChrome ? .browserCache : .appCache, ruleID: "general.caches.google",
                        risk: isChrome ? .safe : .review,
                        riskReason: isChrome ? "Chrome이 다시 만드는 웹 캐시" : "Google 앱 캐시 — 확인 필요",
                        impact: "앱이 다음 실행 시 캐시를 다시 만듭니다.", regenerable: true,
                        guards: isChrome ? [.app("com.google.Chrome", "Google Chrome")] : [], minimumSize: 1024 * 1024)
                    if let c = ctx.makeCandidate(at: sub, root: root, spec: spec) { report.candidates.append(c) }
                }
                continue
            }
            ctx.progress(ScanProgress(phase: "앱 캐시 분석 중", detail: name))

            let baseID = name.hasSuffix(".ShipIt") ? String(name.dropLast(7)) : name
            let appName = appNames[baseID] ?? CacheKnowledgeBase.knownRegenerable[name]
            let guardEntry = CacheKnowledgeBase.guardFor(folder: name, appName: appName)
            var spec = CandidateSpec(
                title: appName.map { CacheKnowledgeBase.isUpdaterLeftover(name) ? "\($0) 업데이트 잔여 파일" : $0 } ?? name,
                category: .appCache, ruleID: "general.caches",
                risk: .review, riskReason: "알 수 없는 캐시 — 내용을 확인한 뒤 선택하세요",
                impact: "앱이 다음 실행 시 캐시를 다시 만듭니다. 처음 실행이 잠시 느려질 수 있습니다.",
                regenerable: true, guards: guardEntry.map { [$0] } ?? [], minimumSize: 1024 * 1024)

            if let reason = CacheKnowledgeBase.blocked[name] {
                spec.risk = .blocked
                spec.riskReason = "보호됨: \(reason)"
                spec.category = .systemCache
            } else if CacheKnowledgeBase.knownRegenerable[name] != nil || CacheKnowledgeBase.isUpdaterLeftover(name) {
                spec.risk = .safe
                spec.riskReason = CacheKnowledgeBase.isUpdaterLeftover(name)
                    ? "설치가 끝난 업데이트 다운로드 잔여 파일"
                    : "검증된 재생성 가능 캐시"
            } else if name.hasPrefix("com.apple.") && CacheKnowledgeBase.browsers[name] == nil {
                spec.category = .systemCache
                spec.riskReason = "macOS 구성요소 캐시 — 재생성되지만 일시적으로 느려질 수 있음"
                spec.guards = []
            }
            if let browser = CacheKnowledgeBase.browsers[name], spec.risk != .blocked {
                spec.category = .browserCache
                spec.title = "\(browser.name) 캐시"
                spec.guards = [.app(browser.bundleID, browser.name)]
                spec.risk = .safe
                spec.riskReason = "브라우저가 다시 만드는 웹 캐시 — 로그인·방문 기록에는 영향 없음"
            }
            if let c = ctx.makeCandidate(at: child, root: root, spec: spec) { report.candidates.append(c) }
        }
    }

    /// Caches of sandboxed apps (`Containers/<id>/Data/Library/Caches`) and of app
    /// groups (`Group Containers/<group>/Library/Caches`). Same rules as
    /// `~/Library/Caches`: only known caches are SAFE, Apple's are REVIEW,
    /// account/sync caches stay blocked. Needs Full Disk Access.
    private func scanContainerCaches(_ ctx: ScanContext, appNames: [String: String], into report: inout GeneralScanReport) {
        let containers = ctx.url("Library/Containers")
        for container in ctx.children(of: containers) ?? [] {
            let id = container.lastPathComponent
            guard !id.hasPrefix("."), !CacheKnowledgeBase.ownedByAdapters.contains(id) else { continue }
            let caches = container.appendingPathComponent("Data/Library/Caches")
            guard ctx.isDirectory(caches) else { continue }
            let appName = appNames[id]
            var spec = CandidateSpec(
                id: "container-cache:\(id)", title: "\(appName ?? Self.readableName(id)) 캐시",
                category: .appCache, ruleID: "general.containerCaches",
                risk: .review, riskReason: "샌드박스 앱의 캐시 — 앱이 다시 만듭니다",
                impact: "앱이 다음 실행 시 캐시를 다시 만듭니다. 처음 실행이 잠시 느려질 수 있습니다.",
                regenerable: true, guards: [.app(id, appName ?? id)], minimumSize: 1024 * 1024)
            if let reason = CacheKnowledgeBase.blocked[id] {
                spec.risk = .blocked
                spec.riskReason = "보호됨: \(reason)"
            } else if CacheKnowledgeBase.knownRegenerable[id] != nil {
                spec.risk = .safe
                spec.riskReason = "검증된 재생성 가능 캐시"
            } else if id.hasPrefix("com.apple.") {
                spec.category = .systemCache
                spec.riskReason = "macOS 구성요소의 캐시 — 다시 만들어지지만 그동안 사진 분석 등 작업이 다시 실행될 수 있음"
            }
            if let c = ctx.makeCandidate(at: caches, root: containers, spec: spec) { report.candidates.append(c) }
        }
        let groups = ctx.url("Library/Group Containers")
        for group in ctx.children(of: groups) ?? [] {
            let name = group.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let caches = group.appendingPathComponent("Library/Caches")
            guard ctx.isDirectory(caches) else { continue }
            let spec = CandidateSpec(
                id: "group-cache:\(name)", title: "\(Self.readableName(name)) 공유 캐시",
                category: name.contains("com.apple") ? .systemCache : .appCache, ruleID: "general.groupContainerCaches",
                risk: .review, riskReason: "같은 개발사의 여러 앱이 함께 쓰는 캐시",
                impact: "해당 앱들이 캐시를 다시 만듭니다.", regenerable: true, minimumSize: 1024 * 1024)
            if let c = ctx.makeCandidate(at: caches, root: groups, spec: spec) { report.candidates.append(c) }
        }
    }

    /// Each Claude Code session gets `<root>/<encoded project path>/<session id>/`.
    /// A session is offered only when nothing in it changed for a day, so a
    /// running session's work is never proposed.
    private func scanAgentScratch(_ ctx: ScanContext, root: URL, into report: inout GeneralScanReport) {
        guard let canonical = PathUtilities.canonicalPath(root.path), ctx.policy.isAllowedRoot(canonical) else { return }
        let base = URL(fileURLWithPath: canonical)
        for project in ctx.children(of: base) ?? [] where ctx.isDirectory(project) {
            let name = Self.agentProjectName(project.lastPathComponent)
            for session in ctx.children(of: project) ?? [] where ctx.isDirectory(session) {
                let spec = CandidateSpec(
                    id: "agent-scratch:\(session.path)", title: "Claude Code 작업 폴더 · \(name)",
                    category: .aiCache, ruleID: "general.agentScratch",
                    risk: .review, riskReason: "끝난 Claude Code 세션이 남긴 임시 작업 파일",
                    impact: "세션이 만든 복사본·빌드·실험 데이터가 사라집니다. 대화 기록(~/.claude)과 프로젝트 파일은 그대로입니다.",
                    regenerable: false, preferredMethod: .trash, allowsPermanentRemoval: true,
                    minimumSize: 10 * 1024 * 1024)
                guard var c = ctx.makeCandidate(at: session, root: base, spec: spec) else { continue }
                let newest = c.size.newestModification ?? c.lastModified
                if c.risk != .blocked, newest.map({ ctx.scannedAt.timeIntervalSince($0) < 86_400 }) ?? true {
                    c.risk = .blocked
                    c.riskReason = "최근 24시간 안에 쓰인 폴더 — 진행 중인 세션일 수 있음"
                }
                report.candidates.append(c)
            }
        }
    }

    /// Top-level items in the shared temp folder that belong to the user. Each is named
    /// by what it holds; anything written in the last day is blocked as possibly in use.
    private func scanSharedTemp(_ ctx: ScanContext, root: URL, into report: inout GeneralScanReport) {
        guard let canonical = PathUtilities.canonicalPath(root.path), ctx.policy.isAllowedRoot(canonical) else { return }
        let base = URL(fileURLWithPath: canonical)
        let children = ctx.children(of: base) ?? []
        for (index, child) in children.enumerated() {
            if Task.isCancelled { return }
            let name = child.lastPathComponent
            ctx.progress(ScanProgress(phase: "공용 임시 폴더 분석 중", detail: name,
                                      fraction: Double(index) / Double(max(1, children.count))))
            // Claude Code's folder is offered per session; system items are never touched.
            if name.hasPrefix(".") || name.hasPrefix("claude-") || name.hasPrefix("com.apple.") { continue }
            guard let id = try? ctx.fileSystem.identity(atPath: child.path), id.ownerUID == getuid(),
                  id.kind == .directory || id.kind == .file else { continue }
            let kind = TempKind.of(child.path, isDirectory: id.kind == .directory)
            let canonicalChild = PathUtilities.canonicalPath(child.path) ?? child.path
            let spec = CandidateSpec(
                id: "shared-tmp:\(child.path)", title: "\(kind.title) · \(name)",
                category: .sharedTemporary, ruleID: "general.sharedTmp.\(kind.rawValue)",
                risk: kind.risk, riskReason: kind.reason, impact: kind.impact,
                regenerable: kind.regenerable, guards: [.pathInUse(canonicalChild)],
                preferredMethod: kind.allowsPermanentRemoval ? .permanent : .trash,
                allowsPermanentRemoval: kind.allowsPermanentRemoval, minimumSize: sharedTempMinimum)
            guard var c = ctx.makeCandidate(at: child, root: base, spec: spec) else { continue }
            let newest = c.size.newestModification ?? c.lastModified
            let idle = newest.map { ctx.scannedAt.timeIntervalSince($0) }
            if c.risk != .blocked {
                // In use = a running process works in it or was started with it
                // (emulator, Gradle daemon, xcodebuild, a shell or agent's current folder).
                if !c.runningGuards.isEmpty {
                    c.risk = .blocked
                    c.riskReason = "실행 중인 프로세스가 이 폴더를 쓰고 있음"
                } else if (idle ?? 0) < sharedTempQuietPeriod {
                    c.risk = .blocked
                    c.riskReason = "최근 2시간 안에 쓰인 항목 — 작업 중일 수 있음"
                } else if let idle {
                    c.riskReason += " · 마지막 사용 \(Self.idleText(idle))"
                }
            }
            report.candidates.append(c)
        }
    }

    static func idleText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours < 1 { return "방금" }
        return hours < 24 ? "\(hours)시간 전" : "\(hours / 24)일 전"
    }

    enum TempKind: String {
        case xcodeBuild, testResult, gitCopy, projectCopy, androidTest, cache, other

        static func of(_ path: String, isDirectory: Bool) -> TempKind {
            guard isDirectory else { return .other }
            let fm = FileManager.default
            let name = (path as NSString).lastPathComponent
            if ProjectAnalyzer.isXcodeBuildFolder(path) || name.hasSuffix(".noindex") { return .xcodeBuild }
            if (name as NSString).pathExtension == "xcresult" { return .testResult }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path + "/.git", isDirectory: &isDir) { return .gitCopy }
            let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            if names.contains(where: { ProjectDiscovery.projectMarkers.contains($0) || ["xcodeproj", "xcworkspace"].contains(($0 as NSString).pathExtension) }) {
                return .projectCopy
            }
            // Per-task Android emulators and Gradle homes made for app testing.
            if names.contains(where: { ["avd", "gradle-home", "android-build", "android-user"].contains($0) }) { return .androidTest }
            if name.lowercased().contains("cache") { return .cache }
            return .other
        }

        var title: String {
            switch self {
            case .xcodeBuild: "Xcode 빌드 폴더"
            case .testResult: "Xcode 테스트 결과"
            case .gitCopy: "Git 저장소 사본"
            case .projectCopy: "프로젝트 사본"
            case .androidTest: "Android 테스트 환경"
            case .cache: "캐시"
            case .other: "임시 항목"
            }
        }
        var risk: RiskLevel { self == .gitCopy ? .manual : .review }
        var reason: String {
            switch self {
            case .xcodeBuild: "임시 위치에 만든 빌드 결과 — 다시 빌드하면 생김"
            case .testResult: "지난 테스트 실행 결과"
            case .gitCopy: "커밋하지 않았거나 올리지 않은 작업이 남아 있을 수 있음 — 직접 확인하세요"
            case .projectCopy: "실험·검증용으로 복사한 프로젝트로 보임 — 원본은 그대로 있음"
            case .androidTest: "테스트용으로 따로 만든 에뮬레이터·Gradle 캐시 — QA 기록이 들어 있을 수 있음"
            case .cache: "도구가 임시로 쓴 캐시"
            case .other: "하루 넘게 쓰이지 않은 임시 항목"
            }
        }
        var impact: String {
            allowsPermanentRemoval ? "필요하면 도구가 다시 만듭니다. Mac을 재시동해도 지워지는 위치입니다."
                : "휴지통으로 이동합니다. 필요하면 휴지통에서 되돌릴 수 있습니다."
        }
        var regenerable: Bool { self == .xcodeBuild || self == .cache }
        var allowsPermanentRemoval: Bool { self == .xcodeBuild || self == .cache || self == .testResult }
    }

    /// Claude Code names the folder after the project path with every character
    /// other than ASCII letters and digits turned into "-". Rebuild the real path by
    /// matching existing folders; fall back to the last part of the name.
    static func agentProjectName(_ encoded: String) -> String {
        if let path = decodeAgentProjectPath(encoded) {
            return path == PathUtilities.realHomeDirectory.path ? "홈 폴더" : (path as NSString).lastPathComponent
        }
        return encoded.split(separator: "-").last.map(String.init) ?? encoded
    }

    static func decodeAgentProjectPath(_ encoded: String) -> String? {
        func encode(_ s: String) -> String {
            String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        }
        func walk(_ dir: String, _ rest: Substring, depth: Int) -> String? {
            if rest.isEmpty { return dir }
            guard depth < 16, rest.hasPrefix("-") else { return nil }
            let remaining = rest.dropFirst()
            let children = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .sorted { $0.count > $1.count }
            for child in children {
                let e = encode(child)
                guard !e.isEmpty, remaining.hasPrefix(e) else { continue }
                let after = remaining.dropFirst(e.count)
                guard after.isEmpty || after.hasPrefix("-") else { continue }
                let next = dir == "/" ? "/" + child : dir + "/" + child
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: next, isDirectory: &isDir), isDir.boolValue else { continue }
                if let found = walk(next, after, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk("/", Substring(encoded), depth: 0)
    }

    /// "com.apple.mediaanalysisd" → "mediaanalysisd", "ABCDE.com.example.shared" → "shared".
    static func readableName(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return last.isEmpty ? identifier : last
    }

    /// Screenshots and screen recordings in the folder macOS saves them to.
    private func scanScreenshots(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let folder = ScreenshotLocator.folder(home: ctx.home)
        guard let canonical = PathUtilities.canonicalPath(folder.path), ctx.policy.isAllowedRoot(canonical) else { return }
        for file in ctx.children(of: folder) ?? [] where ScreenshotLocator.isScreenshot(file.lastPathComponent) {
            guard let id = try? ctx.fileSystem.identity(atPath: file.path), id.kind == .file, !id.isDataless else { continue }
            let age = ctx.scannedAt.timeIntervalSince(id.modificationDate)
            let spec = CandidateSpec(
                title: file.lastPathComponent, category: .screenshots, ruleID: "general.screenshots",
                risk: .manual,
                riskReason: age > 30 * 86_400 ? "한 달 넘게 지난 스크린샷" : "최근 스크린샷 — 필요한지 확인하세요",
                impact: "휴지통으로 이동합니다. 휴지통에서 되돌릴 수 있습니다.",
                regenerable: false, preferredMethod: .trash, allowsPermanentRemoval: false,
                toleratesContentChanges: false, minimumSize: 0)
            if let c = ctx.makeCandidate(at: file, root: URL(fileURLWithPath: canonical), spec: spec) { report.candidates.append(c) }
        }
    }

    /// Copies of attachments that Mail saved when they were opened. Mail
    /// re-downloads them from the message when needed; mail data itself stays protected.
    private func scanMailDownloads(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let root = ctx.url("Library/Containers/com.apple.mail/Data/Library")
        let folder = root.appendingPathComponent("Mail Downloads")
        guard ctx.exists(folder) else { return }
        let spec = CandidateSpec(
            title: "메일 첨부파일 사본", category: .mailAttachments, ruleID: "general.mailDownloads",
            risk: .review, riskReason: "메일에서 연 첨부파일의 임시 사본 — 원본은 메일에 남아 있음",
            impact: "메일 앱이 첨부파일을 다시 열 때 다시 내려받습니다.", regenerable: true,
            guards: [.app("com.apple.mail", "Mail")], preferredMethod: .trash, minimumSize: 1024 * 1024)
        if let c = ctx.makeCandidate(at: folder, root: ctx.url("Library/Containers"), spec: spec) { report.candidates.append(c) }
    }

    private func scanLogs(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let root = ctx.url("Library/Logs")
        guard let children = ctx.children(of: root) else {
            report.restrictedLocations.append(root.path)
            return
        }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || Self.ownedLogFolders.contains(name) { continue }
            var spec = CandidateSpec(
                title: name == "DiagnosticReports" ? "충돌 보고서" : "\(name) 로그",
                category: .logs, ruleID: "general.logs",
                risk: .review, riskReason: "최근 기록 중인 로그",
                impact: "과거 로그 기록이 사라집니다. 앱은 새 로그를 다시 기록합니다.",
                regenerable: true, minimumSize: 256 * 1024)
            if name == "DiagnosticReports" {
                spec.riskReason = "문제 진단에 필요할 수 있는 충돌 보고서"
                spec.preferredMethod = .trash
            }
            guard var c = ctx.makeCandidate(at: child, root: root, spec: spec) else { continue }
            if c.risk == .review, name != "DiagnosticReports",
               let newest = c.size.newestModification, ctx.scannedAt.timeIntervalSince(newest) > logAgeForSafe {
                c.risk = .safe
                c.riskReason = "7일 넘게 기록되지 않은 로그"
            }
            report.candidates.append(c)
        }
    }

    private func scanSavedState(_ ctx: ScanContext, appNames: [String: String], into report: inout GeneralScanReport) {
        let root = ctx.url("Library/Saved Application State")
        guard let children = ctx.children(of: root) else { return }
        for child in children where child.pathExtension == "savedState" {
            let bundleID = child.deletingPathExtension().lastPathComponent
            let name = appNames[bundleID] ?? bundleID
            let spec = CandidateSpec(
                title: "\(name) 창 복원 정보", category: .savedState, ruleID: "general.savedState",
                risk: .review, riskReason: "앱을 다시 열 때 이전 창 배치가 복원되지 않음",
                impact: "다음 실행 시 창이 기본 위치로 열립니다.", regenerable: true,
                guards: [.app(bundleID, name)], minimumSize: 512 * 1024)
            if let c = ctx.makeCandidate(at: child, root: root, spec: spec) { report.candidates.append(c) }
        }
    }

    private func scanTemporary(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let root = ctx.temporaryDirectory
        guard let children = ctx.children(of: root) else { return }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("metro-") || name.hasPrefix("haste-map") { continue }
            guard let id = try? ctx.fileSystem.identity(atPath: child.path),
                  id.kind == .directory || id.kind == .file else { continue }
            let spec = CandidateSpec(
                title: "임시 항목 \(name)", category: .temporary, ruleID: "general.tmp",
                risk: .review, riskReason: "3일 이상 사용되지 않은 임시 항목 — 실행 중인 앱이 쓰고 있을 수 있음",
                impact: "앱이 필요하면 다시 만듭니다.", regenerable: true,
                toleratesContentChanges: false, minimumSize: 1024 * 1024)
            guard let c = ctx.makeCandidate(at: child, root: root, spec: spec),
                  let newest = c.size.newestModification,
                  ctx.scannedAt.timeIntervalSince(newest) > tempAge else { continue }
            report.candidates.append(c)
        }
    }

    private func scanDownloads(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let root = ctx.url("Downloads")
        guard let children = ctx.children(of: root) else {
            report.restrictedLocations.append(root.path)
            return
        }
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), let id = try? ctx.fileSystem.identity(atPath: child.path),
                  id.kind == .file, !id.isDataless else { continue }
            let ext = child.pathExtension.lowercased()
            let age = ctx.scannedAt.timeIntervalSince(id.modificationDate)
            let isOldInstaller = Self.installerExtensions.contains(ext) && id.allocatedSize >= downloadsInstallerMinimum
                && age > downloadsInstallerAge
            guard id.allocatedSize >= downloadsLargeFile || isOldInstaller else { continue }
            let spec = CandidateSpec(
                title: name, category: .downloads, ruleID: "general.downloads",
                risk: .manual,
                riskReason: isOldInstaller ? "설치가 끝났을 수 있는 오래된 설치 파일" : "큰 파일 — 직접 확인 필요",
                impact: "휴지통으로 이동합니다. 필요하면 휴지통에서 복구할 수 있습니다.",
                regenerable: false, preferredMethod: .trash, allowsPermanentRemoval: false,
                toleratesContentChanges: false)
            if let c = ctx.makeCandidate(at: child, root: root, spec: spec) { report.candidates.append(c) }
        }
    }
}
