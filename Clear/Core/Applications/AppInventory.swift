import CoreServices
import Foundation
import Security

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { info.path }
    let info: AppBundleInfo
    var size: SizeInfo?
    var lastUsed: Date?
    var isAppStore: Bool
    var uninstallBlockReason: String?

    var canUninstall: Bool { uninstallBlockReason == nil }
}

/// Finds installed apps and the files that provably belong to them.
///
/// Association rules, strongest first:
/// 1. Exact bundle identifier match in the standard Library locations.
/// 2. App group identifiers declared in the app's code-signing entitlements.
/// 3. Folder named exactly like the app — **weak**, never auto-selected.
struct AppInventory: Sendable {
    let home: URL

    init(home: URL = PathUtilities.realHomeDirectory) {
        self.home = URL(fileURLWithPath: PathUtilities.canonicalPath(home.path) ?? home.path)
    }

    func listApps() -> [InstalledApp] {
        AppCatalog.installedApps(home: home).map { info in
            InstalledApp(info: info, size: nil, lastUsed: Self.lastUsedDate(path: info.path),
                         isAppStore: FileManager.default.fileExists(atPath: info.path + "/Contents/_MASReceipt/receipt"),
                         uninstallBlockReason: Self.blockReason(for: info))
        }
        .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    static func blockReason(for info: AppBundleInfo) -> String? {
        if info.isAppleApp { return "macOS 기본 앱은 제거할 수 없습니다" }
        if info.bundleIdentifier == Bundle.main.bundleIdentifier { return "Clear 자신은 제거할 수 없습니다" }
        var st = stat()
        guard lstat(info.path, &st) == 0 else { return "앱을 찾을 수 없습니다" }
        if st.st_uid != getuid() { return "관리자 소유 앱 — Finder에서 직접 삭제하세요" }
        let parent = (info.path as NSString).deletingLastPathComponent
        if access(parent, W_OK) != 0 { return "앱 폴더에 쓰기 권한이 없습니다" }
        return nil
    }

    /// Spotlight's "last opened" date, when indexing allows it.
    static func lastUsedDate(path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// `com.apple.security.application-groups` from the code signature.
    static func appGroups(ofAppAt path: String) -> [String] {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    // MARK: Candidates

    func bundleCandidate(for app: InstalledApp, ctx: ScanContext) -> CleanupCandidate? {
        let url = URL(fileURLWithPath: app.info.path)
        guard let root = ctx.policy.allowedRoot(containing: app.info.path) else { return nil }
        var guards: [ProcessGuard] = []
        if let id = app.info.bundleIdentifier { guards.append(.app(id, app.info.name)) }
        if let exe = app.info.executableName { guards.append(.process(exe, app.info.name)) }
        let spec = CandidateSpec(
            id: "app:\(app.info.path)", title: app.info.name, category: .appBundle, ruleID: "apps.bundle",
            risk: app.canUninstall ? .manual : .blocked, riskReason: app.uninstallBlockReason ?? "앱 제거는 직접 확인이 필요합니다",
            impact: "앱이 휴지통으로 이동합니다. 휴지통에서 되돌릴 수 있습니다.",
            regenerable: false, guards: guards, preferredMethod: .trash, allowsPermanentRemoval: false,
            toleratesContentChanges: true)
        return ctx.makeCandidate(at: url, root: URL(fileURLWithPath: root), spec: spec)
    }

    func relatedFiles(for app: InstalledApp, ctx: ScanContext) -> [CleanupCandidate] {
        let lib = home.appendingPathComponent("Library")
        var results: [CleanupCandidate] = []
        var seen = Set<String>()
        var guards: [ProcessGuard] = []
        if let id = app.info.bundleIdentifier { guards.append(.app(id, app.info.name)) }

        func add(_ url: URL, title: String, risk: RiskLevel, reason: String, impact: String) {
            guard let canonical = PathUtilities.canonicalPath(url.path), !seen.contains(canonical),
                  let root = ctx.policy.allowedRoot(containing: canonical) else { return }
            let spec = CandidateSpec(
                title: title, category: .appLeftover, ruleID: "apps.related", risk: risk, riskReason: reason,
                impact: impact, regenerable: false, guards: guards, preferredMethod: .trash,
                allowsPermanentRemoval: false, toleratesContentChanges: true)
            if let c = ctx.makeCandidate(at: url, root: URL(fileURLWithPath: root), spec: spec) {
                seen.insert(canonical)
                results.append(c)
            }
        }

        if let id = app.info.bundleIdentifier, !id.isEmpty, !id.contains("/") {
            let regen = "앱을 다시 설치하면 다시 만들어집니다."
            add(lib.appendingPathComponent("Caches/\(id)"), title: "캐시", risk: .safe, reason: "번들 ID 일치 — 캐시", impact: regen)
            add(lib.appendingPathComponent("Caches/\(id).ShipIt"), title: "업데이트 잔여 파일", risk: .safe, reason: "번들 ID 일치", impact: regen)
            add(lib.appendingPathComponent("HTTPStorages/\(id)"), title: "HTTP 저장소", risk: .safe, reason: "번들 ID 일치 — 네트워크 캐시", impact: regen)
            add(lib.appendingPathComponent("HTTPStorages/\(id).binarycookies"), title: "쿠키", risk: .safe, reason: "번들 ID 일치", impact: "로그인 세션이 사라질 수 있습니다.")
            add(lib.appendingPathComponent("WebKit/\(id)"), title: "WebKit 데이터", risk: .safe, reason: "번들 ID 일치 — 웹 캐시", impact: regen)
            add(lib.appendingPathComponent("Saved Application State/\(id).savedState"), title: "창 복원 정보", risk: .safe, reason: "번들 ID 일치", impact: regen)
            add(lib.appendingPathComponent("Logs/\(id)"), title: "로그", risk: .safe, reason: "번들 ID 일치", impact: "과거 로그가 사라집니다.")
            add(lib.appendingPathComponent("Cookies/\(id).binarycookies"), title: "쿠키", risk: .safe, reason: "번들 ID 일치", impact: "로그인 세션이 사라질 수 있습니다.")
            add(lib.appendingPathComponent("Preferences/\(id).plist"), title: "환경설정", risk: .review, reason: "번들 ID 일치 — 앱 설정",
                impact: "다시 설치하면 설정이 초기화됩니다.")
            for byHost in ctx.children(of: lib.appendingPathComponent("Preferences/ByHost")) ?? []
            where byHost.lastPathComponent.hasPrefix(id + ".") && byHost.pathExtension == "plist" {
                add(byHost, title: "기기별 환경설정", risk: .review, reason: "번들 ID 일치", impact: "다시 설치하면 설정이 초기화됩니다.")
            }
            add(lib.appendingPathComponent("Application Support/\(id)"), title: "앱 데이터", risk: .review,
                reason: "번들 ID 일치 — 사용자가 만든 데이터가 있을 수 있음", impact: "앱 데이터가 휴지통으로 이동합니다.")
            add(lib.appendingPathComponent("Containers/\(id)"), title: "샌드박스 컨테이너", risk: .review,
                reason: "번들 ID 일치 — 앱의 문서와 설정 전체", impact: "앱 안에 저장한 문서가 함께 이동합니다. 내용을 확인하세요.")
            for agent in ctx.children(of: lib.appendingPathComponent("LaunchAgents")) ?? []
            where agent.lastPathComponent.hasPrefix(id) && agent.pathExtension == "plist" {
                add(agent, title: "로그인 시 실행 항목", risk: .review, reason: "번들 ID로 시작하는 LaunchAgent",
                    impact: "로그아웃 후 다시 로그인할 때 적용됩니다.")
            }
        }
        for group in Self.appGroups(ofAppAt: app.info.path) where !group.isEmpty && !group.contains("/") {
            add(lib.appendingPathComponent("Group Containers/\(group)"), title: "공유 그룹 컨테이너 \(group)", risk: .manual,
                reason: "같은 개발사의 다른 앱과 공유할 수 있음", impact: "다른 앱의 데이터가 함께 사라질 수 있습니다.")
        }
        // Weak: same-name folders.
        let name = app.info.name
        if !name.isEmpty, !name.contains("/") {
            for base in ["Application Support", "Caches", "Logs"] {
                add(lib.appendingPathComponent("\(base)/\(name)"), title: "\(base)/\(name)", risk: .manual,
                    reason: "이름만 일치 — 다른 앱의 데이터일 수 있음", impact: "내용을 확인한 뒤 선택하세요.")
            }
        }
        return results.sorted { $0.estimatedBytes > $1.estimatedBytes }
    }
}
