import Darwin
import Foundation

enum PathUtilities {
    /// `realpath(3)`: resolves every symlink and `..`. Returns nil when the path does not exist.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func canonicalURL(_ url: URL) -> URL? {
        canonicalPath(url.path).map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    /// Splits an absolute path into components without resolving anything.
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when `path` lies strictly inside `ancestor`. Compares whole components, so
    /// `/a/bc` is *not* inside `/a/b`. Both paths should already be canonical.
    static func isStrictDescendant(_ path: String, of ancestor: String) -> Bool {
        let p = components(path)
        let a = components(ancestor)
        guard p.count > a.count else { return false }
        return Array(p.prefix(a.count)) == a
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        let p = components(path)
        let a = components(ancestor)
        guard p.count >= a.count else { return false }
        return Array(p.prefix(a.count)) == a
    }

    /// Rejects anything that is not a plain absolute path (relative, `.`/`..`, NUL, empty).
    static func isWellFormedAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let comps = components(path)
        guard !comps.isEmpty else { return false }
        return !comps.contains { $0 == "." || $0 == ".." }
    }

    /// `~/Library/Caches/foo` style display string.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if isStrictDescendant(path, of: home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The real (non-sandboxed) home directory even if `HOME` is overridden.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Per-user temporary directory (`/private/var/folders/xx/yyyy/T`), canonicalised.
    static var userTemporaryDirectory: URL {
        let raw = NSTemporaryDirectory()
        let canonical = canonicalPath(raw) ?? raw
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }
}
