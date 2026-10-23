import Foundation

struct ProjectFolder: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }
    var path: String
    var bookmark: Data?
    var addedAt: Date

    var name: String { (path as NSString).lastPathComponent }
}

struct LastScanSummary: Codable, Equatable, Sendable {
    var date: Date
    var cleanableBytes: Int64
    var safeBytes: Int64
    var freeBytes: Int64
    var totalBytes: Int64
}

/// User preferences. Decoding tolerates missing keys so new settings never wipe old ones.
struct AppSettings: Codable, Equatable, Sendable {
    enum Theme: String, Codable, CaseIterable, Sendable {
        case system, dark, light
        var title: String {
            switch self {
            case .system: "시스템"
            case .dark: "다크"
            case .light: "라이트"
            }
        }
    }

    var theme: Theme = .system
    var developerModeEnabled = true
    var aiToolsEnabled = true
    /// Personal folders measured for the Overview breakdown (relative to home).
    var overviewFolders: [String] = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]
    var projectFolders: [ProjectFolder] = []
    var excludedPaths: [String] = []
    var preferTrash = true
    /// 0 = keep forever.
    var historyRetentionDays = 180
    var showMenuBarIcon = true
    var autoScanEnabled = false
    var autoScanIntervalHours = 24
    var lowStorageAlertEnabled = false
    var lowStorageThresholdGB = 20
    var duplicateMinimumSizeMB = 1
    var duplicateFolders: [String] = []
    var similarPhotoThreshold: Double = 0.35
    var fullDiskAccessNoticeDismissed = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        developerModeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .developerModeEnabled)) ?? d.developerModeEnabled
        aiToolsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .aiToolsEnabled)) ?? d.aiToolsEnabled
        overviewFolders = (try? c.decodeIfPresent([String].self, forKey: .overviewFolders)) ?? d.overviewFolders
        projectFolders = (try? c.decodeIfPresent([ProjectFolder].self, forKey: .projectFolders)) ?? d.projectFolders
        excludedPaths = (try? c.decodeIfPresent([String].self, forKey: .excludedPaths)) ?? d.excludedPaths
        preferTrash = (try? c.decodeIfPresent(Bool.self, forKey: .preferTrash)) ?? d.preferTrash
        historyRetentionDays = (try? c.decodeIfPresent(Int.self, forKey: .historyRetentionDays)) ?? d.historyRetentionDays
        showMenuBarIcon = (try? c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon)) ?? d.showMenuBarIcon
        autoScanEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autoScanEnabled)) ?? d.autoScanEnabled
        autoScanIntervalHours = (try? c.decodeIfPresent(Int.self, forKey: .autoScanIntervalHours)) ?? d.autoScanIntervalHours
        lowStorageAlertEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .lowStorageAlertEnabled)) ?? d.lowStorageAlertEnabled
        lowStorageThresholdGB = (try? c.decodeIfPresent(Int.self, forKey: .lowStorageThresholdGB)) ?? d.lowStorageThresholdGB
        duplicateMinimumSizeMB = (try? c.decodeIfPresent(Int.self, forKey: .duplicateMinimumSizeMB)) ?? d.duplicateMinimumSizeMB
        duplicateFolders = (try? c.decodeIfPresent([String].self, forKey: .duplicateFolders)) ?? d.duplicateFolders
        similarPhotoThreshold = (try? c.decodeIfPresent(Double.self, forKey: .similarPhotoThreshold)) ?? d.similarPhotoThreshold
        fullDiskAccessNoticeDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .fullDiskAccessNoticeDismissed)) ?? d.fullDiskAccessNoticeDismissed
    }
}

/// Persists settings in UserDefaults as a single JSON blob.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private static let settingsKey = "clear.settings.v1"
    private static let lastScanKey = "clear.lastScan.v1"

    var settings: AppSettings {
        didSet { if settings != oldValue { persist() } }
    }

    var lastScan: LastScanSummary? {
        didSet {
            if let lastScan, let data = try? JSONEncoder().encode(lastScan) {
                defaults.set(data, forKey: Self.lastScanKey)
            } else {
                defaults.removeObject(forKey: Self.lastScanKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        if let data = defaults.data(forKey: Self.lastScanKey) {
            lastScan = try? JSONDecoder().decode(LastScanSummary.self, from: data)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    // MARK: Project folders

    func addProjectFolder(_ url: URL) {
        let path = PathUtilities.canonicalPath(url.path) ?? url.path
        guard !settings.projectFolders.contains(where: { $0.path == path }) else { return }
        // Clear runs outside the App Sandbox, so a plain bookmark is enough to follow a moved folder.
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        settings.projectFolders.append(ProjectFolder(path: path, bookmark: bookmark, addedAt: Date()))
    }

    func removeProjectFolder(_ folder: ProjectFolder) {
        settings.projectFolders.removeAll { $0.path == folder.path }
    }

    /// Resolves bookmarks, updating stored paths for folders that were moved.
    func resolvedProjectFolders() -> [ProjectFolder] {
        var changed = false
        let resolved = settings.projectFolders.map { folder -> ProjectFolder in
            guard let data = folder.bookmark else { return folder }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return folder
            }
            let path = PathUtilities.canonicalPath(url.path) ?? url.path
            if path != folder.path || stale {
                changed = true
                return ProjectFolder(path: path, bookmark: (try? url.bookmarkData()) ?? data, addedAt: folder.addedAt)
            }
            return folder
        }
        if changed { settings.projectFolders = resolved }
        return resolved
    }
}
