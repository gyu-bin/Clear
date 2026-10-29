import Foundation

/// How a path is removed.
enum RemovalMethod: String, Codable, Sendable {
    /// `FileManager.trashItem`. Recoverable; space is only freed after the Trash is emptied.
    case trash
    /// Descriptor-based removal (`SafeRemover`). Not recoverable; only offered for regenerable data.
    case permanent

    var title: String {
        switch self {
        case .trash: "휴지통으로 이동"
        case .permanent: "즉시 삭제"
        }
    }
}

/// A process that must not be running while an item is removed.
struct ProcessGuard: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Matches `NSRunningApplication.bundleIdentifier`.
        case bundleID
        /// Matches the executable name (`p_comm` / last path component).
        case processName
        /// Matches a substring of the argument vector of interpreter processes (node, java, ruby).
        case commandLine
        /// A process works inside the folder (current directory) or names it in its arguments.
        case pathInUse
    }

    let kind: Kind
    let value: String
    let displayName: String

    static func app(_ bundleID: String, _ name: String) -> ProcessGuard {
        ProcessGuard(kind: .bundleID, value: bundleID, displayName: name)
    }

    static func process(_ executable: String, _ name: String? = nil) -> ProcessGuard {
        ProcessGuard(kind: .processName, value: executable, displayName: name ?? executable)
    }

    static func commandLine(_ fragment: String, _ name: String) -> ProcessGuard {
        ProcessGuard(kind: .commandLine, value: fragment, displayName: name)
    }

    static func pathInUse(_ path: String, _ name: String = "이 폴더를 쓰는 프로세스") -> ProcessGuard {
        ProcessGuard(kind: .pathInUse, value: path.lowercased(), displayName: name)
    }
}

/// Everything the safety engine needs to re-verify a path before removing it.
struct PathTarget: Hashable, Sendable {
    /// Canonical (realpath'd) location at scan time.
    let url: URL
    /// `lstat` snapshot at scan time.
    let identity: FileIdentity
    /// The directory inside which removal is permitted. Must be registered with `SafetyPolicy`.
    let allowedRoot: URL
    /// Directories such as caches change all the time; for those a newer mtime is fine
    /// as long as the inode is unchanged. Files and user data must be unchanged.
    let toleratesContentChanges: Bool
    let scannedAt: Date

    var path: String { url.path }
}

/// A fixed command run through a trusted executable (never via a shell).
struct TrustedCommand: Hashable, Codable, Sendable {
    let tool: TrustedTool
    let arguments: [String]
    /// Text shown to the user, e.g. "brew cleanup".
    var displayCommand: String { ([tool.rawValue] + arguments).joined(separator: " ") }
}

enum CleanupTarget: Hashable, Sendable {
    case path(PathTarget)
    case command(TrustedCommand)

    var pathTarget: PathTarget? {
        if case .path(let p) = self { return p }
        return nil
    }
}

/// One thing Clear proposes to clean.
struct CleanupCandidate: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var subtitle: String
    var category: CleanupCategory
    /// Identifier of the rule or adapter that produced it (for history and debugging).
    var ruleID: String
    var risk: RiskLevel
    /// Why the item got its risk level.
    var riskReason: String
    /// What happens after removal.
    var impact: String
    /// The data is rebuilt automatically by its owner.
    var regenerable: Bool
    var size: SizeInfo
    var lastModified: Date?
    var target: CleanupTarget
    var guards: [ProcessGuard]
    /// Default removal method; `CleanupPlanner` may downgrade it to `.trash`.
    var preferredMethod: RemovalMethod
    /// When false the item is always moved to the Trash (user-created data).
    var allowsPermanentRemoval: Bool
    /// Extra caution shown in the confirmation sheet.
    var warning: String?
    /// Guards found running at scan time (display only; re-checked at execution).
    var runningGuards: [String] = []

    var estimatedBytes: Int64 { size.estimatedReclaimable }
    var isDefaultSelected: Bool { risk == .safe && runningGuards.isEmpty }
    var domain: CleanupDomain { category.domain }

    var path: String? { target.pathTarget?.path }
}
