import Foundation

enum CleanupItemStatus: String, Codable, Sendable {
    case removed, trashed, commandSucceeded, alreadyGone, skipped, failed, cancelled

    var title: String {
        switch self {
        case .removed: "삭제됨"
        case .trashed: "휴지통으로 이동"
        case .commandSucceeded: "명령 완료"
        case .alreadyGone: "이미 없음"
        case .skipped: "건너뜀"
        case .failed: "실패"
        case .cancelled: "취소됨"
        }
    }

    var isSuccess: Bool { self == .removed || self == .trashed || self == .commandSucceeded || self == .alreadyGone }
}

struct CleanupItemResult: Identifiable, Codable, Sendable, Hashable {
    var id: String { candidateID }
    let candidateID: String
    let title: String
    let path: String?
    let category: CleanupCategory
    let method: RemovalMethod
    let status: CleanupItemStatus
    /// Size estimated at scan time.
    let estimatedBytes: Int64
    /// Blocks whose last link was removed (permanent removals only).
    let freedBytes: Int64
    let message: String?
    let trashLocation: String?
}

struct CleanupReport: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let finishedAt: Date
    let results: [CleanupItemResult]
    let freeSpaceBefore: Int64?
    let freeSpaceAfter: Int64?
    let wasCancelled: Bool

    var succeeded: [CleanupItemResult] { results.filter { $0.status.isSuccess } }
    var failed: [CleanupItemResult] { results.filter { $0.status == .failed } }
    var skipped: [CleanupItemResult] { results.filter { $0.status == .skipped || $0.status == .cancelled } }

    var trashedBytes: Int64 { results.filter { $0.status == .trashed }.reduce(0) { $0 + $1.estimatedBytes } }
    var removedBytes: Int64 { results.filter { $0.status == .removed }.reduce(0) { $0 + $1.freedBytes } }
    /// Measured change of raw free space. May differ from `removedBytes` on APFS
    /// (clones, snapshots, other processes writing at the same time).
    var measuredFreedBytes: Int64? {
        guard let b = freeSpaceBefore, let a = freeSpaceAfter else { return nil }
        return a - b
    }
}
