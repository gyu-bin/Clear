import Foundation

/// Result of measuring a file or directory tree.
///
/// - `logical` is the sum of file lengths (what Finder calls "size").
/// - `allocated` is the space the blocks occupy on disk. Hard-linked files are
///   counted once per measurement, and `sharedHardLinkBytes` records how much of
///   `allocated` would *not* be freed by removing only this tree.
/// - `sharedCloneBytes` is the part of `allocated` that APFS clones share with
///   files outside the tree (or with each other, beyond one copy): removing the
///   tree does not free it.
/// Snapshots can still keep blocks alive; Clear re-measures the volume after cleanup.
struct SizeInfo: Hashable, Codable, Sendable {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var fileCount: Int = 0
    var directoryCount: Int = 0
    var inaccessibleCount: Int = 0
    var sharedHardLinkBytes: Int64 = 0
    var sharedCloneBytes: Int64 = 0
    var datalessCount: Int = 0
    var newestModification: Date?
    var oldestModification: Date?

    static let zero = SizeInfo()

    var itemCount: Int { fileCount + directoryCount }

    /// What removing the tree should free: its blocks minus those it shares through
    /// hard links or APFS clones.
    var estimatedReclaimable: Int64 { max(0, allocated - sharedHardLinkBytes - sharedCloneBytes) }

    var isPartial: Bool { inaccessibleCount > 0 }

    mutating func merge(_ other: SizeInfo) {
        logical += other.logical
        allocated += other.allocated
        fileCount += other.fileCount
        directoryCount += other.directoryCount
        inaccessibleCount += other.inaccessibleCount
        sharedHardLinkBytes += other.sharedHardLinkBytes
        sharedCloneBytes += other.sharedCloneBytes
        datalessCount += other.datalessCount
        if let n = other.newestModification { newestModification = max(newestModification ?? n, n) }
        if let o = other.oldestModification { oldestModification = min(oldestModification ?? o, o) }
    }
}

extension Int64 {
    var formattedBytes: String { formatted(.byteCount(style: .file)) }
}

extension Int {
    var formattedBytes: String { Int64(self).formattedBytes }
}
