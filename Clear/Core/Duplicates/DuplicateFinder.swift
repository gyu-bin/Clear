import CryptoKit
import Darwin
import Foundation

struct DuplicateFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let logicalSize: Int64
    let allocatedSize: Int64
    let modified: Date
    let identity: FileIdentity
    /// Other paths that are hard links to this same inode (not duplicates — same data).
    var hardLinks: [String] = []
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String // content hash
    let files: [DuplicateFile]
    /// The only file without a "copy" marker, when exactly one exists.
    let suggestedKeeper: String?

    var fileSize: Int64 { files.first?.logicalSize ?? 0 }
    /// Logical bytes consumed by the extra copies.
    var wastedBytes: Int64 { fileSize * Int64(max(0, files.count - 1)) }
}

struct DuplicateScanResult: Sendable {
    let groups: [DuplicateGroup]
    let scannedFiles: Int
    let hashedFiles: Int
    let skippedCloudOnly: Int
    let skippedProtected: [String]
    let restricted: [String]
    let hardLinkSets: Int
    let roots: [String]

    var wastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }
}

/// Exact duplicate detection: size buckets → partial SHA-256 → full streaming SHA-256.
/// Never opens iCloud placeholders (that would trigger a download) and never looks
/// inside Photos libraries or app bundles.
struct DuplicateFinder: Sendable {
    var minimumSize: Int64 = 1024 * 1024
    var includeHidden = false
    var chunkSize = 1024 * 1024
    var partialBytes = 64 * 1024

    static let skippedPackages: Set<String> = ["photoslibrary", "app", "framework", "xcarchive", "musiclibrary",
                                               "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "bundle"]
    static let skippedDirectories: Set<String> = ["node_modules", ".git", "DerivedData", "Pods", ".Trash", ".build"]

    func scan(roots: [URL], progress: @escaping @Sendable (ScanProgress) -> Void) throws -> DuplicateScanResult {
        struct Key: Hashable { let dev: Int32; let ino: UInt64 }
        var bySize: [Int64: [DuplicateFile]] = [:]
        var seenInodes: [Key: Int] = [:] // → index in bySize bucket for hard-link bookkeeping
        var scanned = 0, cloudOnly = 0, hardLinkSets = 0
        var protected: [String] = [], restricted: [String] = []
        let throttle = ProgressThrottle()

        for root in roots {
            let rootPath = PathUtilities.canonicalPath(root.path) ?? root.path
            try FTSWalker(root: rootPath).walk { entry in
                let name = (entry.path as NSString).lastPathComponent
                switch entry.kind {
                case .directoryPre:
                    if entry.level > 0 {
                        let ext = (name as NSString).pathExtension.lowercased()
                        if ext == "photoslibrary" { protected.append(entry.path); return .skipDescendants }
                        if Self.skippedPackages.contains(ext) || Self.skippedDirectories.contains(name) { return .skipDescendants }
                        if !includeHidden && name.hasPrefix(".") { return .skipDescendants }
                    }
                case .file:
                    guard let st = entry.stat else { break }
                    scanned += 1
                    if throttle.shouldEmit() {
                        progress(ScanProgress(phase: "파일 목록 수집 중", detail: PathUtilities.abbreviated(entry.path), itemsVisited: scanned))
                    }
                    if !includeHidden && name.hasPrefix(".") { break }
                    let id = FileIdentity(stat: st)
                    guard id.logicalSize >= minimumSize else { break }
                    if id.isDataless { cloudOnly += 1; break }
                    let key = Key(dev: id.device, ino: id.inode)
                    if let idx = seenInodes[key], var bucket = bySize[id.logicalSize] {
                        if bucket[idx].hardLinks.isEmpty { hardLinkSets += 1 }
                        bucket[idx].hardLinks.append(entry.path)
                        bySize[id.logicalSize] = bucket
                        break
                    }
                    let file = DuplicateFile(path: entry.path, name: name, logicalSize: id.logicalSize,
                                             allocatedSize: id.allocatedSize, modified: id.modificationDate, identity: id)
                    seenInodes[key] = bySize[id.logicalSize, default: []].count
                    bySize[id.logicalSize, default: []].append(file)
                case .unreadableDirectory, .error:
                    restricted.append(entry.path)
                default:
                    break
                }
                return .continue
            }
        }

        let candidates = bySize.values.filter { $0.count > 1 }
        let totalToHash = candidates.reduce(0) { $0 + $1.count }
        var hashed = 0
        var groups: [DuplicateGroup] = []

        for bucket in candidates.sorted(by: { ($0.first?.logicalSize ?? 0) > ($1.first?.logicalSize ?? 0) }) {
            try Task.checkCancellation()
            // Stage 1: partial hash (head + tail).
            var byPartial: [String: [DuplicateFile]] = [:]
            for file in bucket {
                hashed += 1
                progress(ScanProgress(phase: "내용 비교 중", detail: file.name,
                                      fraction: Double(hashed) / Double(max(1, totalToHash)), itemsVisited: hashed))
                guard let h = try? hash(file, partial: true) else { continue }
                byPartial[h, default: []].append(file)
            }
            // Stage 2: full hash where partial matches.
            for (partialDigest, sameStart) in byPartial where sameStart.count > 1 {
                var byFull: [String: [DuplicateFile]] = [:]
                if sameStart[0].logicalSize <= Int64(partialBytes * 2) {
                    // The "partial" hash already covered the whole file.
                    byFull[partialDigest] = sameStart
                } else {
                    for file in sameStart {
                        try Task.checkCancellation()
                        guard let h = try? hash(file, partial: false) else { continue }
                        byFull[h, default: []].append(file)
                    }
                }
                for (digest, files) in byFull where files.count > 1 {
                    let sorted = files.sorted { $0.modified < $1.modified }
                    groups.append(DuplicateGroup(id: digest, files: sorted, suggestedKeeper: Self.suggestKeeper(sorted)))
                }
            }
        }
        groups.sort { $0.wastedBytes > $1.wastedBytes }
        return DuplicateScanResult(groups: groups, scannedFiles: scanned, hashedFiles: hashed, skippedCloudOnly: cloudOnly,
                                   skippedProtected: protected, restricted: restricted, hardLinkSets: hardLinkSets,
                                   roots: roots.map(\.path))
    }

    /// SHA-256 of the head+tail (partial) or the whole file, read in chunks with
    /// `F_NOCACHE` so large scans do not evict the user's page cache.
    func hash(_ file: DuplicateFile, partial: Bool) throws -> String {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileSystemError.posix(file.path, errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_ino == file.identity.inode, st.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw FileSystemError.identityMismatch(file.path)
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        func readRange(offset: off_t, length: Int) throws {
            var remaining = length
            var position = offset
            while remaining > 0 {
                let want = min(remaining, buffer.count)
                let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, position) }
                if n < 0 { throw FileSystemError.posix(file.path, errno) }
                if n == 0 { break }
                hasher.update(data: buffer[0..<n])
                remaining -= n
                position += off_t(n)
                if !partial && position % off_t(chunkSize * 64) == 0, Task.isCancelled { throw CancellationError() }
            }
        }

        let size = Int64(st.st_size)
        if partial && size > Int64(partialBytes * 2) {
            try readRange(offset: 0, length: partialBytes)
            try readRange(offset: off_t(size - Int64(partialBytes)), length: partialBytes)
        } else {
            try readRange(offset: 0, length: Int(size))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static var copyMarker: Regex<(Substring, Substring, Substring?, Substring?)> {
        /(?i)(\s+copy(\s+\d+)?|\s+\(\d+\)|\s+복사본(\s+\d+)?|\s+\d+|-\d+)$/
    }

    /// Suggests a keeper only when exactly one file lacks a copy-like suffix.
    static func suggestKeeper(_ files: [DuplicateFile]) -> String? {
        let originals = files.filter { file in
            let stem = (file.name as NSString).deletingPathExtension
            return stem.firstMatch(of: copyMarker) == nil
        }
        return originals.count == 1 ? originals[0].path : nil
    }
}
