import Darwin
import Foundation

/// Measures file trees without following symlinks, crossing volumes or
/// double-counting hard links.
///
/// Hard links are de-duplicated within one `DirectorySizer` instance, so the same
/// instance can be reused across sibling candidates to avoid counting a shared
/// inode twice (e.g. pnpm stores linked into several projects).
final class DirectorySizer: @unchecked Sendable {
    private struct InodeKey: Hashable { let dev: Int32; let ino: UInt64 }
    private var seenMultiLink = Set<InodeKey>()
    private let lock = NSLock()

    /// Called every ~2,000 entries with (entries visited, current path).
    var progress: (@Sendable (Int, String) -> Void)?
    /// Read APFS clone sharing so `estimatedReclaimable` excludes shared blocks.
    /// Off for pure disk-usage views, where it would only cost time.
    let checksClones: Bool

    /// Clone families seen in one measurement.
    private struct Family {
        let references: UInt32
        var seen: UInt32 = 0
        var sharedTotal: Int64 = 0
        var sharedLargest: Int64 = 0
    }

    init(checksClones: Bool = true) { self.checksClones = checksClones }

    func measure(_ url: URL) throws -> SizeInfo {
        try measure(path: url.path)
    }

    func measure(path: String) throws -> SizeInfo {
        var info = SizeInfo()
        var root = stat()
        guard lstat(path, &root) == 0 else {
            if errno == EACCES || errno == EPERM {
                info.inaccessibleCount = 1
                return info
            }
            throw FileSystemError.notFound(path)
        }
        // A symlink is measured as itself, never its target.
        if (root.st_mode & S_IFMT) == S_IFLNK {
            info.fileCount = 1
            info.logical = Int64(root.st_size)
            info.allocated = Int64(root.st_blocks) * 512
            return info
        }

        var visited = 0
        var families: [UInt64: Family] = [:]
        try FTSWalker(root: path).walk { entry in
            visited += 1
            if visited % 2000 == 0 { progress?(visited, entry.path) }
            switch entry.kind {
            case .directoryPre:
                info.directoryCount += 1
                if let st = entry.stat { info.allocated += Int64(st.st_blocks) * 512 }
            case .file, .symlink, .other:
                guard let st = entry.stat else { return .continue }
                record(st, into: &info)
                if checksClones, entry.kind == .file { recordClone(st, path: entry.path, families: &families, into: &info) }
            case .unreadableDirectory, .error:
                info.inaccessibleCount += 1
            case .directoryPost, .cycle:
                break
            }
            return .continue
        }
        // A family entirely inside the tree is freed once all its copies go;
        // only the extra copies were double-counted.
        for family in families.values {
            info.sharedCloneBytes += family.seen >= family.references
                ? family.sharedTotal - family.sharedLargest : family.sharedTotal
        }
        return info
    }

    private func recordClone(_ st: stat, path: String, families: inout [UInt64: Family], into info: inout SizeInfo) {
        let blocks = Int64(st.st_blocks) * 512
        guard st.st_nlink == 1, blocks >= CloneInfo.minimumCheckedBytes,
              let clone = CloneInfo.read(path: path), clone.privateBytes < blocks else { return }
        let shared = blocks - clone.privateBytes
        guard clone.referenceCount > 1, clone.cloneID != 0 else {
            info.sharedCloneBytes += shared   // shares some extents with files we cannot track
            return
        }
        var family = families[clone.cloneID] ?? Family(references: clone.referenceCount)
        family.seen += 1
        family.sharedTotal += shared
        family.sharedLargest = max(family.sharedLargest, shared)
        families[clone.cloneID] = family
    }

    private func record(_ st: stat, into info: inout SizeInfo) {
        info.fileCount += 1
        let blocks = Int64(st.st_blocks) * 512
        if st.st_nlink > 1 && (st.st_mode & S_IFMT) == S_IFREG {
            let key = InodeKey(dev: st.st_dev, ino: st.st_ino)
            lock.lock()
            let inserted = seenMultiLink.insert(key).inserted
            lock.unlock()
            guard inserted else { return }
            info.sharedHardLinkBytes += blocks
        }
        info.logical += Int64(st.st_size)
        info.allocated += blocks
        if st.st_flags & UInt32(SF_DATALESS) != 0 { info.datalessCount += 1 }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if info.newestModification.map({ mtime > $0 }) ?? true { info.newestModification = mtime }
        if info.oldestModification.map({ mtime < $0 }) ?? true { info.oldestModification = mtime }
    }
}
