import Darwin
import Foundation

/// Immutable node of the Disk Explorer tree. Built once on a background task, then
/// shared read-only with the UI.
final class DiskNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case directory
        case package
        case file
        case symlink
        /// Several small entries folded together to bound memory.
        case aggregate(count: Int)
        /// Could not be read; size is unknown (never shown as 0).
        case restricted
    }

    let id: Int
    let name: String
    let path: String
    let kind: Kind
    let logicalSize: Int64
    let allocatedSize: Int64
    let fileCount: Int
    let modified: Date?
    let children: [DiskNode]
    /// The subtree contains unreadable folders, so its size is a lower bound.
    let isPartial: Bool
    let fileType: FileTypeGroup

    init(id: Int, name: String, path: String, kind: Kind, logicalSize: Int64, allocatedSize: Int64,
         fileCount: Int, modified: Date?, children: [DiskNode], isPartial: Bool, fileType: FileTypeGroup) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.fileCount = fileCount
        self.modified = modified
        self.children = children
        self.isPartial = isPartial
        self.fileType = fileType
    }

    var isContainer: Bool {
        switch kind {
        case .directory, .package: !children.isEmpty
        default: false
        }
    }

    var isRestricted: Bool { kind == .restricted }

    static func == (a: DiskNode, b: DiskNode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum FileTypeGroup: String, CaseIterable, Sendable, Codable {
    case folder, image, video, audio, document, archive, installer, diskImage, code, application, developer, model, other

    var title: String {
        switch self {
        case .folder: "폴더"
        case .image: "이미지"
        case .video: "동영상"
        case .audio: "오디오"
        case .document: "문서"
        case .archive: "압축 파일"
        case .installer: "설치 파일"
        case .diskImage: "디스크·가상 머신 이미지"
        case .code: "코드"
        case .application: "앱"
        case .developer: "개발 산출물"
        case .model: "AI 모델"
        case .other: "기타"
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .archive: "archivebox"
        case .installer: "shippingbox"
        case .diskImage: "externaldrive"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app"
        case .developer: "hammer"
        case .model: "brain"
        case .other: "doc"
        }
    }

    static func classify(fileName: String) -> FileTypeGroup {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "webp", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "svg", "bmp":
            return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm", "mts", "prores":
            return .video
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "caf", "logicx":
            return .audio
        case "pdf", "doc", "docx", "pages", "key", "keynote", "numbers", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "epub":
            return .document
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst":
            return .archive
        case "dmg", "pkg", "mpkg", "iso", "xip", "ipsw":
            return .installer
        case "swift", "m", "h", "c", "cpp", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "json", "yml", "yaml", "html", "css":
            return .code
        case "app":
            return .application
        case "o", "a", "dylib", "dSYM", "xcarchive", "ipa", "apk", "aab", "class", "jar", "pcm", "swiftmodule":
            return .developer
        case "img", "qcow2", "vmdk", "vdi", "vhd", "vhdx", "sparseimage", "utm":
            return .diskImage
        case "gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "mlmodel", "mlpackage":
            return .model
        default:
            return .other
        }
    }
}

struct LargeFileEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let allocatedSize: Int64
    let logicalSize: Int64
    let modified: Date
    let type: FileTypeGroup
}

struct DiskScanResult: Sendable {
    let root: DiskNode
    let largeFiles: [LargeFileEntry]
    let oldFiles: [LargeFileEntry]
    let typeBreakdown: [FileTypeGroup: Int64]
    let restrictedPaths: [String]
    let totalEntries: Int
    let finishedAt: Date
}

/// Builds a `DiskNode` tree for Disk Explorer.
///
/// Memory is bounded: per directory only the largest files are kept as nodes and
/// the long tail is folded into one aggregate node. Directory nodes are kept so the
/// user can navigate everywhere that has meaningful size.
struct DiskTreeScanner: Sendable {
    var keepFilesPerDirectory = 120
    var minimumFileNodeSize: Int64 = 256 * 1024
    var minimumDirectoryNodeSize: Int64 = 64 * 1024
    var largeFileThreshold: Int64 = 50 * 1024 * 1024
    var oldFileThreshold: Int64 = 20 * 1024 * 1024
    var oldFileAge: TimeInterval = 365 * 24 * 3600
    var listLimit = 300

    private final class Builder {
        let name: String
        let path: String
        let isPackage: Bool
        var files: [DiskNode] = []
        var folded: (count: Int, logical: Int64, allocated: Int64) = (0, 0, 0)
        var dirs: [DiskNode] = []
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var fileCount = 0
        var partial = false
        var modified: Date?

        init(name: String, path: String, isPackage: Bool) {
            self.name = name
            self.path = path
            self.isPackage = isPackage
        }
    }

    private static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "xcarchive", "bundle", "framework", "musiclibrary", "tvlibrary",
        "fcpbundle", "logicx", "imovielibrary", "xcodeproj", "xcworkspace", "pages", "key", "numbers", "playground", "mlpackage",
    ]

    func scan(root rootURL: URL, progress: @escaping @Sendable (ScanProgress) -> Void) throws -> DiskScanResult {
        let rootPath = rootURL.path
        var nextID = 0
        func makeID() -> Int { nextID += 1; return nextID }

        var stack: [Builder] = []
        var result: DiskNode?
        var large: [LargeFileEntry] = []
        var old: [LargeFileEntry] = []
        var types: [FileTypeGroup: Int64] = [:]
        var restricted: [String] = []
        var seenLinks = Set<UInt64>()
        let now = Date()
        var visited = 0
        let throttle = ProgressThrottle()

        func insertBounded(_ entry: LargeFileEntry, into list: inout [LargeFileEntry]) {
            if list.count >= listLimit, let last = list.last, last.allocatedSize >= entry.allocatedSize { return }
            let idx = list.firstIndex { $0.allocatedSize < entry.allocatedSize } ?? list.endIndex
            list.insert(entry, at: idx)
            if list.count > listLimit { list.removeLast() }
        }

        func finish(_ b: Builder) -> DiskNode {
            var children = b.dirs
            b.files.sort { $0.allocatedSize > $1.allocatedSize }
            if b.files.count > keepFilesPerDirectory {
                for f in b.files[keepFilesPerDirectory...] {
                    b.folded.count += 1
                    b.folded.logical += f.logicalSize
                    b.folded.allocated += f.allocatedSize
                }
                b.files.removeSubrange(keepFilesPerDirectory...)
            }
            children += b.files
            if b.folded.count > 0 {
                children.append(DiskNode(id: makeID(), name: "작은 항목 \(b.folded.count)개", path: b.path,
                                         kind: .aggregate(count: b.folded.count), logicalSize: b.folded.logical,
                                         allocatedSize: b.folded.allocated, fileCount: b.folded.count,
                                         modified: nil, children: [], isPartial: false, fileType: .other))
            }
            children.sort { $0.allocatedSize > $1.allocatedSize }
            return DiskNode(id: makeID(), name: b.name, path: b.path, kind: b.isPackage ? .package : .directory,
                            logicalSize: b.logical, allocatedSize: b.allocated, fileCount: b.fileCount,
                            modified: b.modified, children: children, isPartial: b.partial, fileType: .folder)
        }

        try FTSWalker(root: rootPath).walk { entry in
            visited += 1
            if throttle.shouldEmit() {
                progress(ScanProgress(phase: "파일 탐색 중", detail: PathUtilities.abbreviated(entry.path), itemsVisited: visited))
            }
            let name = entry.level == 0 ? (rootURL.lastPathComponent.isEmpty ? rootPath : rootURL.lastPathComponent)
                                        : (entry.path as NSString).lastPathComponent
            switch entry.kind {
            case .directoryPre:
                let ext = (name as NSString).pathExtension.lowercased()
                let b = Builder(name: name, path: entry.path, isPackage: Self.packageExtensions.contains(ext))
                if let st = entry.stat {
                    b.allocated += Int64(st.st_blocks) * 512
                    b.modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                }
                stack.append(b)

            case .directoryPost:
                guard let b = stack.popLast() else { return .continue }
                let node = finish(b)
                if let parent = stack.last {
                    parent.logical += node.logicalSize
                    parent.allocated += node.allocatedSize
                    parent.fileCount += node.fileCount
                    parent.partial = parent.partial || node.isPartial
                    if node.allocatedSize >= minimumDirectoryNodeSize || node.isPartial {
                        parent.dirs.append(node)
                    } else {
                        parent.folded.count += 1
                        parent.folded.logical += node.logicalSize
                        parent.folded.allocated += node.allocatedSize
                    }
                } else {
                    result = node
                }

            case .file, .symlink, .other:
                guard let st = entry.stat, let parent = stack.last else { return .continue }
                let blocks = Int64(st.st_blocks) * 512
                if st.st_nlink > 1 && (st.st_mode & S_IFMT) == S_IFREG {
                    guard seenLinks.insert(st.st_ino).inserted else { return .continue }
                }
                let logical = Int64(st.st_size)
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                let type: FileTypeGroup = entry.kind == .symlink ? .other : FileTypeGroup.classify(fileName: name)
                parent.logical += logical
                parent.allocated += blocks
                parent.fileCount += 1
                types[type, default: 0] += blocks
                if blocks >= minimumFileNodeSize {
                    parent.files.append(DiskNode(id: makeID(), name: name, path: entry.path,
                                                 kind: entry.kind == .symlink ? .symlink : .file,
                                                 logicalSize: logical, allocatedSize: blocks, fileCount: 1,
                                                 modified: mtime, children: [], isPartial: false, fileType: type))
                } else {
                    parent.folded.count += 1
                    parent.folded.logical += logical
                    parent.folded.allocated += blocks
                }
                if entry.kind == .file {
                    let item = LargeFileEntry(path: entry.path, name: name, allocatedSize: blocks,
                                              logicalSize: logical, modified: mtime, type: type)
                    if blocks >= largeFileThreshold { insertBounded(item, into: &large) }
                    if blocks >= oldFileThreshold, now.timeIntervalSince(mtime) > oldFileAge { insertBounded(item, into: &old) }
                }

            case .unreadableDirectory, .error:
                // fts reports an unreadable directory as FTS_D first, then FTS_DNR/FTS_ERR
                // for the same entry instead of FTS_DP. Drop the pending builder.
                let wasDirectory = stack.last?.path == entry.path
                if wasDirectory { stack.removeLast() }
                restricted.append(entry.path)
                let node = DiskNode(id: makeID(), name: name, path: entry.path, kind: .restricted,
                                    logicalSize: 0, allocatedSize: 0, fileCount: 0, modified: nil,
                                    children: [], isPartial: true, fileType: .folder)
                if let parent = stack.last {
                    parent.partial = true
                    if wasDirectory || entry.kind == .unreadableDirectory { parent.dirs.append(node) }
                } else {
                    result = node
                }

            case .cycle:
                break
            }
            return .continue
        }

        guard let root = result else { throw FileSystemError.notFound(rootPath) }
        return DiskScanResult(root: root, largeFiles: large, oldFiles: old, typeBreakdown: types,
                              restrictedPaths: restricted, totalEntries: visited, finishedAt: Date())
    }
}
