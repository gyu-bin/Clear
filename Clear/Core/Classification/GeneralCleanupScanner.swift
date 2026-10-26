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
