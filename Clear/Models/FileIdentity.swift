import Darwin
import Foundation

/// A snapshot of an inode taken with `lstat`. Used to detect that a path still
/// refers to the same object between scan time and deletion time.
struct FileIdentity: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file, directory, symlink, other
    }

    let device: Int32
    let inode: UInt64
    let kind: Kind
    let modificationTime: TimeInterval
    let ownerUID: UInt32
    let linkCount: UInt16
    let logicalSize: Int64
    let allocatedSize: Int64
    let flags: UInt32

    init(device: Int32, inode: UInt64, kind: Kind, modificationTime: TimeInterval, ownerUID: UInt32,
         linkCount: UInt16 = 1, logicalSize: Int64 = 0, allocatedSize: Int64 = 0, flags: UInt32 = 0) {
        self.device = device
        self.inode = inode
        self.kind = kind
        self.modificationTime = modificationTime
        self.ownerUID = ownerUID
        self.linkCount = linkCount
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.flags = flags
    }

    init(stat st: stat) {
        let mode = st.st_mode & S_IFMT
        let kind: Kind
        switch mode {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        self.init(
            device: st.st_dev,
            inode: st.st_ino,
            kind: kind,
            modificationTime: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000,
            ownerUID: st.st_uid,
            linkCount: st.st_nlink,
            logicalSize: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            flags: st.st_flags
        )
    }

    /// iCloud / File Provider placeholder whose content is not on disk.
    var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }

    var modificationDate: Date { Date(timeIntervalSince1970: modificationTime) }

    /// Same underlying object (volume + inode + type).
    func isSameObject(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode && kind == other.kind
    }
}
