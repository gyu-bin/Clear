import Darwin
import Foundation

/// Removes a file or directory tree using descriptor-relative system calls.
///
/// Why not `FileManager.removeItem` / `rm -rf`:
/// * Every path component is opened with `O_NOFOLLOW`, so a symlink planted anywhere
///   in the path after validation (TOCTOU) makes the removal fail instead of
///   escaping to another location.
/// * The target is re-identified by (device, inode) *after* it is opened.
/// * Traversal never follows symlinks (links themselves are unlinked) and never
///   crosses into another volume (mount points are skipped and reported).
/// * Hard-linked files are unlinked, but their bytes are not reported as freed.
struct SafeRemover: Sendable {
    var maxDepth = 256

    func remove(canonicalPath: String, expected: FileIdentity,
                shouldCancel: @Sendable () -> Bool) throws -> RemovalStats {
        guard PathUtilities.isWellFormedAbsolutePath(canonicalPath) else {
            throw FileSystemError.pathChanged(canonicalPath)
        }
        var components = PathUtilities.components(canonicalPath)
        let name = components.removeLast()

        var parentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw FileSystemError.posix("/", errno) }
        defer { close(parentFD) }

        for component in components {
            let next = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let code = errno
                if code == ENOENT { throw FileSystemError.notFound(canonicalPath) }
                // ELOOP / ENOTDIR: a component became a symlink or a file.
                throw FileSystemError.pathChanged(canonicalPath)
            }
            close(parentFD)
            parentFD = next
        }

        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw FileSystemError.notFound(canonicalPath) }
            throw FileSystemError.posix(canonicalPath, errno)
        }
        let current = FileIdentity(stat: st)
        guard current.isSameObject(as: expected) else { throw FileSystemError.identityMismatch(canonicalPath) }

        var stats = RemovalStats()
        if current.kind == .directory {
            let dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dirFD >= 0 else { throw FileSystemError.pathChanged(canonicalPath) }
            var dst = stat()
            guard fstat(dirFD, &dst) == 0, dst.st_dev == expected.device, dst.st_ino == expected.inode else {
                close(dirFD)
                throw FileSystemError.identityMismatch(canonicalPath)
            }
            do {
                try removeContents(of: dirFD, device: dst.st_dev, displayPath: canonicalPath,
                                   depth: 0, stats: &stats, shouldCancel: shouldCancel)
            } catch {
                close(dirFD)
                throw error
            }
            close(dirFD)
            if unlinkat(parentFD, name, AT_REMOVEDIR) == 0 {
                stats.removedDirectories += 1
            } else if errno == ENOTEMPTY || errno == EEXIST {
                if stats.failures.isEmpty && stats.skippedMountPoints == 0 {
                    stats.failures.append("\(canonicalPath): 새 항목이 생겨 폴더를 비우지 못함")
                }
                throw RemovalIncomplete(stats: stats, path: canonicalPath)
            } else {
                stats.failures.append("\(canonicalPath): \(String(cString: strerror(errno)))")
                throw RemovalIncomplete(stats: stats, path: canonicalPath)
            }
        } else {
            guard unlinkat(parentFD, name, 0) == 0 else {
                let code = errno
                if code == EACCES || code == EPERM { throw FileSystemError.permissionDenied(canonicalPath) }
                throw FileSystemError.posix(canonicalPath, code)
            }
            account(st, into: &stats)
        }
        return stats
    }

    private func account(_ st: stat, into stats: inout RemovalStats) {
        stats.removedFiles += 1
        stats.logicalBytes += Int64(st.st_size)
        let blocks = Int64(st.st_blocks) * 512
        if st.st_nlink > 1 { stats.sharedBytes += blocks } else { stats.freedBytes += blocks }
    }

    private func removeContents(of dirFD: Int32, device: Int32, displayPath: String, depth: Int,
                                stats: inout RemovalStats, shouldCancel: @Sendable () -> Bool) throws {
        if depth > maxDepth {
            stats.failures.append("\(displayPath): 폴더 깊이 제한 초과")
            return
        }
        for name in try entryNames(of: dirFD, displayPath: displayPath) {
            if shouldCancel() { throw FileSystemError.cancelled }
            let childPath = displayPath + "/" + name
            var st = stat()
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { stats.failures.append("\(childPath): \(String(cString: strerror(errno)))") }
                continue
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                if st.st_dev != device {
                    stats.skippedMountPoints += 1
                    stats.failures.append("\(childPath): 다른 볼륨(마운트 지점)이라 건너뜀")
                    continue
                }
                let childFD = openat(dirFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else {
                    stats.failures.append("\(childPath): \(String(cString: strerror(errno)))")
                    continue
                }
                var cst = stat()
                if fstat(childFD, &cst) != 0 || cst.st_ino != st.st_ino || cst.st_dev != st.st_dev {
                    close(childFD)
                    stats.failures.append("\(childPath): 탐색 중 항목이 바뀜")
                    continue
                }
                do {
                    try removeContents(of: childFD, device: device, displayPath: childPath,
                                       depth: depth + 1, stats: &stats, shouldCancel: shouldCancel)
                } catch {
                    close(childFD)
                    throw error
                }
                close(childFD)
                if unlinkat(dirFD, name, AT_REMOVEDIR) == 0 {
                    stats.removedDirectories += 1
                } else {
                    stats.failures.append("\(childPath): \(String(cString: strerror(errno)))")
                }
            } else {
                if unlinkat(dirFD, name, 0) == 0 {
                    account(st, into: &stats)
                } else if errno != ENOENT {
                    stats.failures.append("\(childPath): \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    /// Reads all entry names first so that unlinking does not disturb iteration.
    private func entryNames(of dirFD: Int32, displayPath: String) throws -> [String] {
        let dupFD = dup(dirFD)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            throw FileSystemError.posix(displayPath, errno)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }
}

/// The tree was partly removed. Carries what was achieved so the report stays accurate.
struct RemovalIncomplete: Error, LocalizedError, Sendable {
    let stats: RemovalStats
    let path: String

    var errorDescription: String? {
        let first = stats.failures.first.map { " — \($0)" } ?? ""
        return "일부만 삭제됨 (\(stats.failures.count)개 실패)\(first)"
    }
}
