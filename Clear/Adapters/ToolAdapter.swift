import Foundation

enum ToolKind: String, Sendable { case developer, ai }

/// A known data location of a tool, measured for display.
struct ToolLocation: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable {
        case cache, logs, build, dependencies, models, history, settings, credentials, data, simulator, other

        var title: String {
            switch self {
            case .cache: "캐시"
            case .logs: "로그"
            case .build: "빌드"
            case .dependencies: "의존성"
            case .models: "모델"
            case .history: "기록"
            case .settings: "설정"
            case .credentials: "인증 정보"
            case .data: "데이터"
            case .simulator: "시뮬레이터"
            case .other: "기타"
            }
        }
    }

    var id: String { path }
    let path: String
    let title: String
    let role: Role
    /// nil when it could not be read.
    let size: SizeInfo?
    let isProtected: Bool
    let note: String?
}

struct ToolReport: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let kind: ToolKind
    var installed: Bool
    var version: String?
    var locations: [ToolLocation] = []
    var candidates: [CleanupCandidate] = []
    var notes: [String] = []
    var runningProcesses: [String] = []
    var error: String?

    var measuredBytes: Int64 { locations.compactMap(\.size?.allocated).reduce(0, +) }
    var protectedBytes: Int64 { locations.filter(\.isProtected).compactMap(\.size?.allocated).reduce(0, +) }
    var cleanableBytes: Int64 { candidates.filter { $0.risk != .blocked }.reduce(0) { $0 + $1.estimatedBytes } }
    var safeBytes: Int64 { candidates.filter { $0.risk == .safe }.reduce(0) { $0 + $1.estimatedBytes } }
}

protocol ToolAdapter: Sendable {
    var id: String { get }
    var name: String { get }
    var symbol: String { get }
    var kind: ToolKind { get }
    func scan(_ ctx: ScanContext) async -> ToolReport
}

extension ScanContext {
    /// Measures a location for display. Returns nil if it does not exist.
    func location(_ url: URL, title: String, role: ToolLocation.Role, protected: Bool, note: String? = nil) -> ToolLocation? {
        guard let id = try? fileSystem.identity(atPath: url.path), id.kind != .symlink else { return nil }
        let size: SizeInfo?
        if id.kind == .directory {
            let measured = try? sizer.measure(path: url.path)
            size = (measured?.inaccessibleCount ?? 1) > 0 && (measured?.fileCount ?? 0) == 0 ? nil : measured
        } else {
            size = SizeInfo(logical: id.logicalSize, allocated: id.allocatedSize, fileCount: 1)
        }
        return ToolLocation(path: url.path, title: title, role: role, size: size, isProtected: protected, note: note)
    }

    func bundleVersion(ofAppAt path: String) -> String? {
        AppCatalog.read(appAt: URL(fileURLWithPath: path))?.version
    }
}

/// Declarative adapter for tools whose data layout is a list of known paths.
struct DirectoryToolAdapter: ToolAdapter {
    struct Item: Sendable {
        let relativePath: String
        let title: String
        let category: CleanupCategory
        let risk: RiskLevel
        let reason: String
        let impact: String
        var regenerable = true
        var minimumSize: Int64 = 512 * 1024
    }

    struct Protected: Sendable {
        let relativePath: String
        let title: String
        let role: ToolLocation.Role
    }

    let id: String
    let name: String
    let symbol: String
    let kind: ToolKind
    /// Any of these (relative to home, or absolute) existing means "installed".
    let detectPaths: [String]
    let appPaths: [String]
    let guards: [ProcessGuard]
    let items: [Item]
    let protectedItems: [Protected]
    var notes: [String] = []
    /// Extra scanning (models, etc).
    var extra: (@Sendable (ScanContext, inout ToolReport) async -> Void)?

    private func resolve(_ ctx: ScanContext, _ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : ctx.url(path)
    }

    func scan(_ ctx: ScanContext) async -> ToolReport {
        let installedApp = appPaths.first { ctx.exists(URL(fileURLWithPath: $0)) }
        let installed = installedApp != nil || detectPaths.contains { ctx.exists(resolve(ctx, $0)) }
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: installed,
                                version: installedApp.flatMap { ctx.bundleVersion(ofAppAt: $0) })
        guard installed else { return report }
        report.runningProcesses = ctx.processes.runningGuards(guards)
        report.notes = notes
        ctx.progress(ScanProgress(phase: "\(name) 분석 중"))

        for item in items {
            let url = resolve(ctx, item.relativePath)
            guard ctx.exists(url), let root = ctx.policy.allowedRoot(containing: PathUtilities.canonicalPath(url.path) ?? url.path) else { continue }
            let spec = CandidateSpec(
                id: "\(id):\(item.relativePath)", title: item.title, category: item.category, ruleID: "\(kind.rawValue).\(id)",
                risk: item.risk, riskReason: item.reason, impact: item.impact, regenerable: item.regenerable,
                guards: guards, minimumSize: item.minimumSize)
            if let c = ctx.makeCandidate(at: url, root: URL(fileURLWithPath: root), spec: spec) {
                report.candidates.append(c)
                report.locations.append(ToolLocation(path: c.path ?? url.path, title: item.title,
                                                     role: item.category == .aiLogs ? .logs : .cache,
                                                     size: c.size, isProtected: false, note: nil))
            }
        }
        for item in protectedItems {
            let url = resolve(ctx, item.relativePath)
            if let loc = ctx.location(url, title: item.title, role: item.role, protected: true, note: "보호됨 — 삭제하지 않음") {
                report.locations.append(loc)
            }
        }
        if let extra { await extra(ctx, &report) }
        return report
    }
}
