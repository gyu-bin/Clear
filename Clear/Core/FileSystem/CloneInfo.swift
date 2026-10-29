import Darwin

/// APFS clone details of one file. A clone (`cp -c`, Finder duplicate, many build
/// and agent tools) shares its blocks with the original, so removing it frees only
/// the bytes that are its own.
struct CloneInfo: Equatable, Sendable {
    /// Bytes not shared with any other file.
    let privateBytes: Int64
    /// Files cloned from the same data share this id.
    let cloneID: UInt64
    /// How many files share the data (1 = not cloned).
    let referenceCount: UInt32

    /// Smaller files are not checked: the extra system call costs more than the
    /// few bytes it could correct.
    static let minimumCheckedBytes: Int64 = 16 * 1024

    static func read(path: String) -> CloneInfo? { read(directory: AT_FDCWD, name: path) }

    /// `name` relative to the open directory `directory` (or a path with `AT_FDCWD`).
    /// Never follows a symlink. nil on volumes without clone information.
    static func read(directory: Int32, name: String) -> CloneInfo? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = getattrlistat(directory, name, &attrs, &buffer, buffer.count,
                                   UInt(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED))
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> CloneInfo? in
            let length = Int(raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            var offset = 4
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            let fork = returned.forkattr
            guard fork & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0, offset + 8 <= length else { return nil }
            let privateBytes = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
            var cloneID: UInt64 = 0
            var references: UInt32 = 1
            if fork & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0, offset + 8 <= length {
                cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                offset += 8
            }
            if fork & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0, offset + 4 <= length {
                references = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return CloneInfo(privateBytes: max(0, privateBytes), cloneID: cloneID, referenceCount: references)
        }
    }
}
