import Foundation

/// Finds code projects in the places people keep code, so they show up without
/// being registered first: Git repositories, and folders with a project file
/// (package.json, Podfile, build.gradle, an Xcode project…). Only folder names are read.
enum ProjectDiscovery {
    /// Home folders never searched (system data, media libraries, tool data).
    static let skippedHomeFolders: Set<String> = [
        "Library", "Applications", "Pictures", "Music", "Movies", "Public", ".Trash",
    ]
    /// Folders never descended into.
    static let skippedNames: Set<String> = [
        "node_modules", "Pods", "build", "dist", "DerivedData", ".build", "vendor", "target",
    ]

    /// Files that make a folder a project even without Git.
    static let projectMarkers: Set<String> = [
        "package.json", "Podfile", "Package.swift", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "Cargo.toml", "go.mod", "pyproject.toml", "pubspec.yaml", "project.godot",
        "app.json", "Gemfile", "composer.json", "CMakeLists.txt",
    ]
    /// Project markers count from this depth (1 = a folder directly in home), so a
    /// stray package.json in ~/Desktop does not swallow every project under it.
    static let markerMinimumDepth = 2

    static func find(home: URL = PathUtilities.realHomeDirectory, maxDepth: Int = 4, limit: Int = 200) -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }

        func visit(_ path: String, depth: Int) {
            guard found.count < limit, !Task.isCancelled else { return }
            // A real repository has a .git folder; a .git file means a worktree or submodule.
            if isDirectory(path + "/.git") {
                found.append(PathUtilities.canonicalPath(path) ?? path)
                return
            }
            guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
            if depth >= markerMinimumDepth, names.contains(where: { name in
                projectMarkers.contains(name) || ["xcodeproj", "xcworkspace"].contains((name as NSString).pathExtension)
            }) {
                found.append(PathUtilities.canonicalPath(path) ?? path)
                return
            }
            guard depth < maxDepth else { return }
            for name in names.sorted() {
                if name.hasPrefix(".") || skippedNames.contains(name) { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                if ["app", "photoslibrary", "musiclibrary", "xcodeproj", "xcworkspace", "bundle", "framework"].contains(ext) { continue }
                let child = path + "/" + name
                // Never follow symbolic links out of the tree.
                if let type = try? fm.attributesOfItem(atPath: child)[.type] as? FileAttributeType, type != .typeDirectory { continue }
                visit(child, depth: depth + 1)
            }
        }

        let root = home.path
        for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() {
            if name.hasPrefix(".") || skippedHomeFolders.contains(name) { continue }
            let child = root + "/" + name
            if let type = try? fm.attributesOfItem(atPath: child)[.type] as? FileAttributeType, type != .typeDirectory { continue }
            visit(child, depth: 1)
        }
        return found
    }
}
