import Foundation

struct StorageSegment: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let paths: [String]
    /// nil when the location could not be read at all.
    let bytes: Int64?
    let isPartial: Bool
}

struct StorageBreakdown: Sendable {
    let segments: [StorageSegment]
    let volume: VolumeInfo
    /// Used space not attributed to any measured category (system, other users, snapshots…).
    var unattributed: Int64 { max(0, volume.used - segments.compactMap(\.bytes).reduce(0, +)) }
}

/// Measures well-known locations for the Overview breakdown. Locations the user has
/// not granted access to are reported as restricted rather than as 0 bytes.
struct StorageBreakdownScanner: Sendable {
    struct Category: Sendable {
        let id: String
        let title: String
        let symbol: String
        let paths: [String]
    }

    static func categories(home: URL, personalFolders: [String]) -> [Category] {
        let h = home.path
        var list: [Category] = [
            Category(id: "apps", title: "응용 프로그램", symbol: "square.grid.2x2", paths: ["/Applications", h + "/Applications"]),
            Category(id: "developer", title: "개발자 데이터", symbol: "hammer",
                     paths: [h + "/Library/Developer", h + "/.gradle", h + "/.npm", h + "/Library/pnpm", h + "/.android", h + "/.expo"]),
            Category(id: "caches", title: "캐시", symbol: "square.stack.3d.up", paths: [h + "/Library/Caches"]),
            Category(id: "ai", title: "AI 도구·모델", symbol: "sparkles",
                     paths: [h + "/.ollama", h + "/.lmstudio", h + "/.cache/huggingface", h + "/.claude", h + "/.codex"]),
            Category(id: "icloud", title: "iCloud Drive(로컬 사본)", symbol: "icloud", paths: [h + "/Library/Mobile Documents"]),
            Category(id: "trash", title: "휴지통", symbol: "trash", paths: [h + "/.Trash"]),
            Category(id: "appdata", title: "앱 데이터", symbol: "shippingbox",
                     paths: [h + "/Library/Application Support", h + "/Library/Containers", h + "/Library/Group Containers"]),
            Category(id: "tmp", title: "임시 작업 폴더", symbol: "tray.full", paths: ["/private/tmp"]),
        ]
        let personal: [(String, String, String)] = [
            ("Documents", "문서", "doc.text"), ("Desktop", "데스크탑", "menubar.dock.rectangle"),
            ("Downloads", "다운로드", "arrow.down.circle"), ("Pictures", "사진", "photo"),
            ("Movies", "동영상", "film"), ("Music", "음악", "music.note"),
        ]
        for (folder, title, symbol) in personal where personalFolders.contains(folder) {
            list.append(Category(id: folder.lowercased(), title: title, symbol: symbol, paths: [h + "/" + folder]))
        }
        return list
    }

    func scan(categories: [Category], volume: VolumeInfo, progress: @escaping @Sendable (ScanProgress) -> Void) async -> StorageBreakdown {
        let sizer = DirectorySizer(checksClones: false)
        var segments: [StorageSegment] = []
        for (index, category) in categories.enumerated() {
            if Task.isCancelled { break }
            progress(ScanProgress(phase: "저장공간 분류 중", detail: category.title,
                                  fraction: Double(index) / Double(categories.count)))
            var total = SizeInfo()
            var anyReadable = false
            for path in category.paths where FileManager.default.fileExists(atPath: path) {
                if let size = try? sizer.measure(path: path) {
                    if size.inaccessibleCount == 0 || size.fileCount > 0 { anyReadable = true }
                    total.merge(size)
                }
            }
            segments.append(StorageSegment(id: category.id, title: category.title, symbol: category.symbol,
                                           paths: category.paths, bytes: anyReadable ? total.allocated : nil,
                                           isPartial: total.inaccessibleCount > 0))
        }
        return StorageBreakdown(segments: segments.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }, volume: volume)
    }
}
