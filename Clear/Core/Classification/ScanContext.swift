import Foundation

/// Shared inputs for every scanner and adapter during one scan.
struct ScanContext: Sendable {
    let home: URL
    let temporaryDirectory: URL
    let policy: SafetyPolicy
    let processes: ProcessSnapshot
    let commandRunner: CommandRunning
    let fileSystem: FileSystemOperating
    /// Shared so a hard-linked inode is counted once across the whole scan.
    let sizer: DirectorySizer
    let scannedAt: Date
    let progress: @Sendable (ScanProgress) -> Void

    init(home: URL = PathUtilities.realHomeDirectory,
         temporaryDirectory: URL = PathUtilities.userTemporaryDirectory,
         policy: SafetyPolicy,
         processes: ProcessSnapshot,
         commandRunner: CommandRunning = CommandRunner(),
         fileSystem: FileSystemOperating = LocalFileSystem(),
         sizer: DirectorySizer = DirectorySizer(),
         scannedAt: Date = Date(),
         progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) {
        self.home = URL(fileURLWithPath: PathUtilities.canonicalPath(home.path) ?? home.path, isDirectory: true)
        self.temporaryDirectory = temporaryDirectory
        self.policy = policy
        self.processes = processes
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
        self.sizer = sizer
        self.scannedAt = scannedAt
        self.progress = progress
    }

    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    func exists(_ url: URL) -> Bool { (try? fileSystem.identity(atPath: url.path)) != nil }

    func isDirectory(_ url: URL) -> Bool { (try? fileSystem.identity(atPath: url.path))?.kind == .directory }

    /// Direct children (not following symlinks), sorted by name. Unreadable → nil.
    func children(of url: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return names.sorted().map { url.appendingPathComponent($0) }
    }
}

/// Describes a proposed candidate before it is measured.
struct CandidateSpec: Sendable {
    var id: String?
    var title: String
    var subtitle: String?
    var category: CleanupCategory
    var ruleID: String
    var risk: RiskLevel
    var riskReason: String
    var impact: String
    var regenerable: Bool
    var guards: [ProcessGuard] = []
    var preferredMethod: RemovalMethod = .permanent
    var allowsPermanentRemoval: Bool = true
    var toleratesContentChanges: Bool = true
    var warning: String?
    /// Drop the candidate if it is smaller than this.
    var minimumSize: Int64 = 1
}

extension ScanContext {
    /// Canonicalises, identifies and measures a path, then applies the policy.
    /// Returns nil for missing paths, symlinks, and items below `minimumSize`.
    func makeCandidate(at url: URL, root: URL, spec: CandidateSpec) -> CleanupCandidate? {
        // lstat the path as given: a symlink candidate is never followed to its target.
        guard let original = try? fileSystem.identity(atPath: url.path), original.kind != .symlink,
              let canonical = fileSystem.canonicalPath(url.path),
              let canonicalRoot = fileSystem.canonicalPath(root.path),
              let identity = try? fileSystem.identity(atPath: canonical),
              identity.isSameObject(as: original) else { return nil }

        let size: SizeInfo
        if identity.kind == .directory {
            guard let measured = try? sizer.measure(path: canonical) else { return nil }
            size = measured
        } else {
            size = SizeInfo(logical: identity.logicalSize, allocated: identity.allocatedSize, fileCount: 1,
                            newestModification: identity.modificationDate, oldestModification: identity.modificationDate)
        }
        guard size.allocated >= spec.minimumSize || size.inaccessibleCount > 0 else { return nil }

        var risk = spec.risk
        var reason = spec.riskReason
        if let protection = policy.protectionReason(for: canonical) {
            risk = .blocked
            reason = "보호 경로: \(protection)"
        } else if !PathUtilities.isStrictDescendant(canonical, of: canonicalRoot) || !policy.isAllowedRoot(canonicalRoot) {
            risk = .blocked
            reason = "허용 위치 밖"
        } else if identity.ownerUID != getuid() {
            risk = .blocked
            reason = "다른 사용자 소유"
        } else if size.inaccessibleCount > 0 && risk == .safe {
            risk = .review
            reason = "일부 하위 항목에 접근할 수 없음"
        }
        let running = processes.runningGuards(spec.guards)

        let target = PathTarget(url: URL(fileURLWithPath: canonical), identity: identity,
                                allowedRoot: URL(fileURLWithPath: canonicalRoot),
                                toleratesContentChanges: spec.toleratesContentChanges, scannedAt: scannedAt)
        return CleanupCandidate(
            id: spec.id ?? "path:" + canonical,
            title: spec.title,
            subtitle: spec.subtitle ?? PathUtilities.abbreviated(canonical, home: home.path),
            category: spec.category,
            ruleID: spec.ruleID,
            risk: risk,
            riskReason: running.isEmpty ? reason : "\(reason) · \(running.joined(separator: ", ")) 실행 중",
            impact: spec.impact,
            regenerable: spec.regenerable,
            size: size,
            lastModified: size.newestModification ?? identity.modificationDate,
            target: .path(target),
            guards: spec.guards,
            preferredMethod: spec.preferredMethod,
            allowsPermanentRemoval: spec.allowsPermanentRemoval,
            warning: spec.warning,
            runningGuards: running
        )
    }
}
