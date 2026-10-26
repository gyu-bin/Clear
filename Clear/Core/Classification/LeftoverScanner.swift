import Foundation

/// Finds leftovers that are easy to miss: data of apps that are no longer
/// installed, hidden tool caches in dot-folders, login items whose program is
/// gone, and old iPhone/iPad software updates.
///
/// Attribution is conservative: a folder counts as an app leftover only when its
/// name is a bundle identifier, no installed app has that identifier (or a
/// parent/child identifier), and no app from the same vendor is installed.
/// Folders named after app names are never attributed. Nothing is SAFE by
/// default except clearly regenerable build-tool caches.
struct LeftoverScanner: Sendable {
    /// Bundle identifiers of installed apps (later double-checked with LaunchServices).
    let installedBundleIDs: Set<String>
    /// Reading other apps' containers needs Full Disk Access; without it macOS
    /// would prompt for each one, so containers are skipped.
    var includeContainers: Bool
    var minimumOrphanSize: Int64 = 1024 * 1024

    static func looksLikeBundleID(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9\-]+\.[A-Za-z0-9\-]+\.[A-Za-z0-9.\-_]+/) != nil
    }

    /// True when `id` belongs to an installed app, one of its helpers/extensions,
    /// or a vendor that still has an app installed.
    func isClaimed(_ rawID: String) -> Bool {
        var id = rawID
        for suffix in [".ShipIt", ".savedState", ".binarycookies", ".plist"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
        }
        let lower = id.lowercased()
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.") || lower == Bundle.main.bundleIdentifier?.lowercased() {
            return true
        }
        let vendor = lower.split(separator: ".").prefix(2).joined(separator: ".")
        for installed in installedBundleIDs {
            let i = installed.lowercased()
            if i == lower || lower.hasPrefix(i + ".") || i.hasPrefix(lower + ".") { return true }
            if i.split(separator: ".").prefix(2).joined(separator: ".") == vendor { return true }
        }
        return false
    }

    func scan(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        ctx.progress(ScanProgress(phase: "삭제된 앱의 잔여 파일 찾는 중"))
        scanOrphans(ctx, into: &report)
        ctx.progress(ScanProgress(phase: "숨겨진 캐시 폴더 찾는 중"))
        scanHiddenCaches(ctx, into: &report)
        ctx.progress(ScanProgress(phase: "로그인 항목 확인 중"))
        scanBrokenLoginItems(ctx, into: &report)
        scanSoftwareUpdates(ctx, into: &report)
    }

    // MARK: Orphaned app data

    private func scanOrphans(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        var locations: [(String, String, RiskLevel, String)] = [
            ("Library/Application Support", "앱 데이터", .manual, "삭제된 앱의 데이터 — 사용자가 만든 내용이 있을 수 있어 직접 확인 필요"),
            ("Library/HTTPStorages", "네트워크 저장소", .review, "삭제된 앱의 네트워크 캐시"),
            ("Library/WebKit", "웹 데이터", .review, "삭제된 앱의 웹 캐시·저장소"),
        ]
        if includeContainers {
            locations.append(("Library/Containers", "샌드박스 컨테이너", .manual, "삭제된 앱의 컨테이너 — 앱 안에 저장한 문서가 있을 수 있음"))
        }
        for (rel, kind, risk, reason) in locations {
            let root = ctx.url(rel)
            for child in ctx.children(of: root) ?? [] {
                let name = child.lastPathComponent
                guard Self.looksLikeBundleID(name), !isClaimed(name),
                      !CacheKnowledgeBase.ownedByAdapters.contains(name) else { continue }
                let spec = CandidateSpec(
                    id: "orphan:\(child.path)", title: "\(name) \(kind)", category: .orphanedAppData,
                    ruleID: "general.orphan", risk: risk, riskReason: reason,
                    impact: "휴지통으로 이동합니다. 같은 앱을 다시 설치하면 설정과 데이터가 처음 상태로 시작합니다.",
                    regenerable: false, preferredMethod: .trash, allowsPermanentRemoval: false,
                    toleratesContentChanges: true, minimumSize: minimumOrphanSize)
                if var c = ctx.makeCandidate(at: child, root: root, spec: spec) {
                    if let last = c.lastModified {
                        c.riskReason += " · 마지막 수정 \(last.formatted(.relative(presentation: .named)))"
                    }
                    report.candidates.append(c)
                }
            }
        }
    }

    // MARK: Hidden tool caches

    struct HiddenCache: Sendable {
        let path: String
        let title: String
        let risk: RiskLevel
        let impact: String
        var guards: [ProcessGuard] = []
    }

    static let hiddenCaches: [HiddenCache] = [
        HiddenCache(path: ".m2/repository", title: "Maven 저장소 캐시", risk: .review,
                    impact: "다음 빌드 때 의존성을 다시 내려받습니다.", guards: [.commandLine("maven", "Maven")]),
        HiddenCache(path: ".cocoapods/repos", title: "CocoaPods 스펙 저장소", risk: .review,
                    impact: "다음 `pod install` 때 다시 받습니다.", guards: [.commandLine("bin/pod", "CocoaPods")]),
        HiddenCache(path: ".cargo/registry", title: "Rust 패키지 레지스트리 캐시", risk: .review,
                    impact: "다음 빌드 때 크레이트를 다시 내려받습니다.", guards: [.process("cargo")]),
        HiddenCache(path: ".cargo/git", title: "Rust Git 의존성 캐시", risk: .review,
                    impact: "다음 빌드 때 다시 내려받습니다.", guards: [.process("cargo")]),
        HiddenCache(path: ".pub-cache/hosted", title: "Dart·Flutter 패키지 캐시", risk: .review,
                    impact: "`flutter pub get` 때 다시 받습니다.", guards: [.process("dart"), .process("flutter")]),
        HiddenCache(path: ".bun/install/cache", title: "Bun 패키지 캐시", risk: .safe,
                    impact: "다음 설치 때 다시 내려받습니다.", guards: [.process("bun")]),
        HiddenCache(path: ".node-gyp", title: "node-gyp 헤더(구버전 위치)", risk: .safe,
                    impact: "네이티브 모듈을 빌드할 때 다시 받습니다."),
        HiddenCache(path: ".electron-gyp", title: "electron-gyp 헤더", risk: .safe,
                    impact: "네이티브 모듈을 빌드할 때 다시 받습니다."),
        HiddenCache(path: ".nuget/packages", title: "NuGet 패키지 캐시", risk: .review,
                    impact: "다음 복원 때 다시 내려받습니다.", guards: [.process("dotnet")]),
        HiddenCache(path: ".composer/cache", title: "Composer 캐시", risk: .safe,
                    impact: "다음 설치 때 다시 내려받습니다.", guards: [.process("composer")]),
    ]

    /// `~/.cache` subfolders handled by other screens.
    static let ownedXDGCaches: Set<String> = ["huggingface", "claude", "codex-runtimes", "lm-studio"]

    private func scanHiddenCaches(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        for cache in Self.hiddenCaches {
            let url = ctx.url(cache.path)
            guard ctx.exists(url), let root = ctx.policy.allowedRoot(containing: PathUtilities.canonicalPath(url.path) ?? url.path) else { continue }
            let spec = CandidateSpec(
                title: cache.title, subtitle: "~/" + cache.path, category: .hiddenCache, ruleID: "general.hiddenCache",
                risk: cache.risk, riskReason: "숨김 폴더에 있는 도구 캐시 — 도구가 다시 만듭니다",
                impact: cache.impact, regenerable: true, guards: cache.guards, minimumSize: 5 * 1024 * 1024)
            if let c = ctx.makeCandidate(at: url, root: URL(fileURLWithPath: root), spec: spec) { report.candidates.append(c) }
        }
        let xdg = ctx.url(".cache")
        for child in ctx.children(of: xdg) ?? [] where ctx.isDirectory(child) {
            let name = child.lastPathComponent
            guard !Self.ownedXDGCaches.contains(name) else { continue }
            let spec = CandidateSpec(
                title: "\(name) 캐시", subtitle: "~/.cache/\(name)", category: .hiddenCache, ruleID: "general.xdgCache",
                risk: .review, riskReason: "~/.cache는 도구가 다시 만들 수 있는 캐시를 두는 표준 위치",
                impact: "해당 도구가 다음 실행 때 캐시를 다시 만들거나 내려받습니다.", regenerable: true,
                guards: [.process(name)], minimumSize: 5 * 1024 * 1024)
            if let c = ctx.makeCandidate(at: child, root: xdg, spec: spec) { report.candidates.append(c) }
        }
    }

    // MARK: Broken login items

    private func scanBrokenLoginItems(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let root = ctx.url("Library/LaunchAgents")
        for plist in ctx.children(of: root) ?? [] where plist.pathExtension == "plist" {
            guard let data = FileManager.default.contents(atPath: plist.path),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/"), !FileManager.default.fileExists(atPath: program) else { continue }
            let label = (dict["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
            let spec = CandidateSpec(
                title: label, category: .brokenLoginItem, ruleID: "general.brokenLaunchAgent",
                risk: .review, riskReason: "실행할 프로그램이 없는 로그인 항목: \(PathUtilities.abbreviated(program))",
                impact: "다음 로그인부터 실패하는 실행 시도가 없어집니다. 휴지통으로 이동합니다.",
                regenerable: false, preferredMethod: .trash, allowsPermanentRemoval: false,
                toleratesContentChanges: false, minimumSize: 0)
            if let c = ctx.makeCandidate(at: plist, root: root, spec: spec) { report.candidates.append(c) }
        }
    }

    // MARK: Device software updates

    private func scanSoftwareUpdates(_ ctx: ScanContext, into report: inout GeneralScanReport) {
        let root = ctx.url("Library/iTunes")
        for folder in ["iPhone Software Updates", "iPad Software Updates", "iPod Software Updates"] {
            for file in ctx.children(of: root.appendingPathComponent(folder)) ?? [] where file.pathExtension == "ipsw" {
                let spec = CandidateSpec(
                    title: file.lastPathComponent, category: .softwareUpdates, ruleID: "general.ipsw",
                    risk: .review, riskReason: "기기 업데이트에 쓰였던 펌웨어 파일 — 필요하면 다시 내려받을 수 있음",
                    impact: "휴지통으로 이동합니다. 기기를 복원할 때 Finder가 다시 내려받습니다.",
                    regenerable: true, preferredMethod: .trash, allowsPermanentRemoval: false,
                    toleratesContentChanges: false, minimumSize: 10 * 1024 * 1024)
                if let c = ctx.makeCandidate(at: file, root: root, spec: spec) { report.candidates.append(c) }
            }
        }
    }
}
