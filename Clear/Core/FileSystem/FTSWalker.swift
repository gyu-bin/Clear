import Darwin
import Foundation

/// Thin wrapper over `fts(3)`: physical walk (never follows symlinks), does not
/// cross devices, detects directory cycles, reports unreadable directories.
struct FTSWalker {
    enum EntryKind {
        case directoryPre
        case directoryPost
        case file
        case symlink
        case unreadableDirectory
        case cycle
        case error
        case other
    }

    struct Entry {
        let path: String
        let level: Int
        let kind: EntryKind
        let stat: stat?
        let errorCode: Int32
    }

    enum Decision { case `continue`, skipDescendants, stop }

    let root: String
    var crossDevices = false

    /// Walks the tree, calling `body` for every entry. Throws `CancellationError`
    /// if the current task is cancelled.
    func walk(_ body: (Entry) throws -> Decision) throws {
        var options = FTS_PHYSICAL | FTS_NOCHDIR
        if !crossDevices { options |= FTS_XDEV }

        let cRoot = strdup(root)
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = argv.withUnsafeMutableBufferPointer({ fts_open($0.baseAddress, options, nil) }) else {
            throw FileSystemError.posix(root, errno)
        }
        defer { fts_close(fts) }

        var counter = 0
        while let ent = fts_read(fts) {
            counter += 1
            if counter & 0x3FF == 0, Task.isCancelled { throw CancellationError() }

            let e = ent.pointee
            let path = String(cString: e.fts_path)
            let info = Int32(e.fts_info)
            let kind: EntryKind
            switch info {
            case FTS_D: kind = .directoryPre
            case FTS_DP: kind = .directoryPost
            case FTS_F: kind = .file
            case FTS_SL, FTS_SLNONE: kind = .symlink
            case FTS_DNR: kind = .unreadableDirectory
            case FTS_DC: kind = .cycle
            case FTS_ERR, FTS_NS: kind = .error
            default: kind = .other
            }
            let st: stat? = (kind == .error || e.fts_statp == nil) ? nil : e.fts_statp.pointee
            let entry = Entry(path: path, level: Int(e.fts_level), kind: kind, stat: st, errorCode: e.fts_errno)
            switch try body(entry) {
            case .continue: break
            case .skipDescendants:
                if kind == .directoryPre { fts_set(fts, ent, FTS_SKIP) }
            case .stop: return
            }
        }
    }
}
