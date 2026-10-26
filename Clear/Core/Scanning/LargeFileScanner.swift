import CoreServices
import Darwin
import Foundation

struct LargeFileItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let allocatedSize: Int64
    let logicalSize: Int64
    let modified: Date
    /// Spotlight's "last opened" date. Only set when the file was opened through
    /// LaunchServices (e.g. from Finder); nil for hidden or never-opened files.
    let lastOpened: Date?
    let type: FileTypeGroup
    let isHidden: Bool
    let identity: FileIdentity

    /// The best available "last used" signal.
    var lastUsed: Date { lastOpened ?? modified }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct LargeFileScanResult: Sendable {
    let root: String
    let items: [LargeFileItem]
    let scannedFiles: Int
    let skippedCloudOnly: Int
    let restricted: [String]
}

/// Collects large files in the home folder. Folders that other screens manage
/// (Library, Trash, app bundles, Photos libraries, dependency/tool folders, AI
/// models) are skipped; iCloud placeholders are never downloaded.
struct LargeFileScanner: Sendable {
    var minimumSize: Int64 = 50 * 1024 * 1024
    var limit = 2000

    static let skippedNames: Set<String> = [
        ".Trash", "node_modules", ".git", "Pods", ".build", "DerivedData", ".gradle", ".npm", ".cargo", ".rustup",
        ".m2", ".pub-cache", ".cocoapods", ".ollama", ".lmstudio", "huggingface", ".Spotlight-V100", ".fseventsd",
        // Data of AI tools, emulators and developer tools: managed on their own screens, never "large junk".
        ".claude", ".codex", ".cursor", ".gemini", ".android", ".expo", ".vscode", ".docker", ".orbstack",
        ".colima", ".lima", ".cache", ".local", ".npm-global", ".nvm", ".pyenv", ".rbenv", ".volta",
    ]
    static let skippedPackages: Set<String> = [
        "app", "photoslibrary", "xcarchive", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
        "framework", "bundle", "photolibrary", "aplibrary",
    ]

    func scan(home: URL, progress: @escaping @Sendable (ScanProgress) -> Void) throws -> LargeFileScanResult {
        let root = PathUtilities.canonicalPath(home.path) ?? home.path
        let library = root + "/Library"
        var items: [LargeFileItem] = []
        var scanned = 0, cloudOnly = 0
        var restricted: [String] = []
        let throttle = ProgressThrottle()

        try FTSWalker(root: root).walk { entry in
            let name = (entry.path as NSString).lastPathComponent
            switch entry.kind {
            case .directoryPre where entry.level > 0:
                if entry.path == library || Self.skippedNames.contains(name)
                    || Self.skippedPackages.contains((name as NSString).pathExtension.lowercased()) {
                    return .skipDescendants
                }
            case .file:
                scanned += 1
                if throttle.shouldEmit() {
                    progress(ScanProgress(phase: "큰 파일 찾는 중", detail: PathUtilities.abbreviated(entry.path, home: root), itemsVisited: scanned))
                }
                guard let st = entry.stat else { break }
                let id = FileIdentity(stat: st)
                guard id.allocatedSize >= minimumSize || (id.logicalSize >= minimumSize && !id.isDataless) else { break }
                if id.isDataless { cloudOnly += 1; break }
                let relative = String(entry.path.dropFirst(root.count))
                items.append(LargeFileItem(
                    path: entry.path, name: name, allocatedSize: id.allocatedSize, logicalSize: id.logicalSize,
                    modified: id.modificationDate, lastOpened: Self.lastOpened(entry.path),
                    type: FileTypeGroup.classify(fileName: name),
                    isHidden: PathUtilities.components(relative).contains { $0.hasPrefix(".") },
                    identity: id))
            case .unreadableDirectory, .error:
                restricted.append(entry.path)
            default:
                break
            }
            return .continue
        }
        items.sort { $0.allocatedSize > $1.allocatedSize }
        if items.count > limit { items.removeSubrange(limit...) }
        return LargeFileScanResult(root: root, items: items, scannedFiles: scanned, skippedCloudOnly: cloudOnly, restricted: restricted)
    }

    static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
