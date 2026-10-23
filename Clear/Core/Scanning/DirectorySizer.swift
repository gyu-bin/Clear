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

    init() {}

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
            case .unreadableDirectory, .error:
                info.inaccessibleCount += 1
            case .directoryPost, .cycle:
                break
            }
            return .continue
        }
        return info
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
