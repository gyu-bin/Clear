import Foundation

/// Statistics returned by a permanent removal.
struct RemovalStats: Hashable, Sendable, Codable {
    var removedFiles: Int = 0
    var removedDirectories: Int = 0
    var logicalBytes: Int64 = 0
    /// Blocks whose last link was removed — an estimate of space actually returned.
    var freedBytes: Int64 = 0
    /// Bytes of files that still have other hard links (no space freed).
    var sharedBytes: Int64 = 0
    var failures: [String] = []
    var skippedMountPoints: Int = 0

    mutating func merge(_ o: RemovalStats) {
        removedFiles += o.removedFiles
        removedDirectories += o.removedDirectories
        logicalBytes += o.logicalBytes
        freedBytes += o.freedBytes
        sharedBytes += o.sharedBytes
        failures += o.failures
        skippedMountPoints += o.skippedMountPoints
    }
}

enum FileSystemError: Error, LocalizedError, Equatable, Sendable {
    case notFound(String)
    case identityMismatch(String)
    case pathChanged(String)
    case permissionDenied(String)
    case notEmpty(String)
    case cancelled
    case posix(String, Int32)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): "더 이상 존재하지 않음: \(PathUtilities.abbreviated(p))"
        case .identityMismatch(let p): "스캔 이후 다른 항목으로 바뀜: \(PathUtilities.abbreviated(p))"
        case .pathChanged(let p): "경로 구성이 바뀌었거나 심볼릭 링크가 포함됨: \(PathUtilities.abbreviated(p))"
        case .permissionDenied(let p): "권한 없음: \(PathUtilities.abbreviated(p))"
        case .notEmpty(let p): "일부 항목을 지우지 못해 폴더가 남음: \(PathUtilities.abbreviated(p))"
        case .cancelled: "취소됨"
        case .posix(let p, let code): "\(String(cString: strerror(code))) (\(PathUtilities.abbreviated(p)))"
        case .other(let m): m
        }
    }
}

/// The only way the cleanup engine touches the disk. `LocalFileSystem` is the real
/// implementation; tests inject `MockFileSystem` to exercise failure paths without
/// risking any real data.
protocol FileSystemOperating: Sendable {
    /// `lstat` (does not follow a final symlink).
    func identity(atPath path: String) throws -> FileIdentity
    /// `realpath`; nil when missing.
    func canonicalPath(_ path: String) -> String?
    /// Whether the current user can create/remove entries in `directory`.
    func isWritableDirectory(_ directory: String) -> Bool
    /// Moves an item to the user's Trash and returns its new location.
    func moveToTrash(atPath path: String) throws -> String?
    /// Removes a file or directory tree without following symlinks or crossing volumes.
    func removeTree(atPath path: String, expected: FileIdentity,
                    shouldCancel: @Sendable () -> Bool) throws -> RemovalStats
}
