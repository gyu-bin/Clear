import Darwin
import Foundation

struct LocalFileSystem: FileSystemOperating {
    func identity(atPath path: String) throws -> FileIdentity {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw FileSystemError.notFound(path) }
            if code == EACCES || code == EPERM { throw FileSystemError.permissionDenied(path) }
            throw FileSystemError.posix(path, code)
        }
        return FileIdentity(stat: st)
    }

    func canonicalPath(_ path: String) -> String? {
        PathUtilities.canonicalPath(path)
    }

    func isWritableDirectory(_ directory: String) -> Bool {
        access(directory, W_OK | X_OK) == 0
    }

    func moveToTrash(atPath path: String) throws -> String? {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            throw FileSystemError.permissionDenied(path)
        } catch {
            throw FileSystemError.other(error.localizedDescription)
        }
        return resulting?.path
    }

    func removeTree(atPath path: String, expected: FileIdentity,
                    shouldCancel: @Sendable () -> Bool) throws -> RemovalStats {
        try SafeRemover().remove(canonicalPath: path, expected: expected, shouldCancel: shouldCancel)
    }
}
