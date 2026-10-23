import Foundation

/// Minimal metadata read from an app bundle's Info.plist.
struct AppBundleInfo: Hashable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let executableName: String?
    let isAppleApp: Bool
}

/// Lists installed applications by reading Info.plist files directly
/// (no LaunchServices round-trips, safe off the main thread).
enum AppCatalog {
    static func searchRoots(home: URL = PathUtilities.realHomeDirectory) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/System/Applications")]
    }

    static func installedApps(home: URL = PathUtilities.realHomeDirectory, includeSystem: Bool = false) -> [AppBundleInfo] {
        var result: [AppBundleInfo] = []
        var roots = searchRoots(home: home)
        if !includeSystem { roots.removeLast() }
        for root in roots {
            collect(in: root, depth: 0, into: &result)
        }
        return result
    }

    private static func collect(in dir: URL, depth: Int, into result: inout [AppBundleInfo]) {
        guard depth <= 1, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            if name.hasSuffix(".app") {
                if let info = read(appAt: url) { result.append(info) }
            } else {
                collect(in: url, depth: depth + 1, into: &result)
            }
        }
    }

    static func read(appAt url: URL) -> AppBundleInfo? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let bundleID = plist["CFBundleIdentifier"] as? String
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppBundleInfo(
            path: url.path,
            name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
            bundleIdentifier: bundleID,
            version: (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String),
            executableName: plist["CFBundleExecutable"] as? String,
            isAppleApp: bundleID?.hasPrefix("com.apple.") ?? false
        )
    }

    /// bundle id → display name.
    static func nameIndex(home: URL = PathUtilities.realHomeDirectory) -> [String: String] {
        var index: [String: String] = [:]
        for app in installedApps(home: home, includeSystem: true) {
            if let id = app.bundleIdentifier { index[id] = app.name }
        }
        return index
    }
}
