import Darwin
import Foundation
@testable import Clear

/// A private, canonicalised scratch directory for one test. Everything the
/// file-system tests create or delete lives inside it; it is removed on deinit.
final class TempDirectory {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ClearTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: PathUtilities.canonicalPath(base.path) ?? base.path, isDirectory: true)
    }

    deinit {
        // Restore permissions changed by access-denied tests, then remove the fixture.
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let rel as String in e { chmod(url.appendingPathComponent(rel).path, 0o755) }
        }
        chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func dir(_ relative: String) throws -> URL {
        let u = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Writes `size` bytes (non-zero pattern so blocks are really allocated).
    @discardableResult
    func file(_ relative: String, size: Int = 4096, byte: UInt8 = 0xAB, modified: Date? = nil) throws -> URL {
        let u = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: size).write(to: u)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: u.path) }
        return u
    }

    @discardableResult
    func file(_ relative: String, data: Data) throws -> URL {
        let u = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    func exists(_ relative: String) -> Bool {
        var st = stat()
        return lstat(url.appendingPathComponent(relative).path, &st) == 0
    }
}

extension Date {
    static func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }
}

/// A policy and scan context rooted in a fake home inside the fixture.
struct FakeEnvironment {
    let temp: TempDirectory
    let home: URL
    let tmp: URL

    init(_ temp: TempDirectory) throws {
        self.temp = temp
        home = try temp.dir("home")
        tmp = try temp.dir("tmp")
    }

    func policy(extraRoots: [URL] = [], exclusions: [String] = []) -> SafetyPolicy {
        SafetyPolicy(home: home, temporaryDirectory: tmp, extraAllowedRoots: extraRoots, exclusions: exclusions)
    }

    func context(processes: ProcessSnapshot = .empty, runner: CommandRunning = MockCommandRunner(),
                 extraRoots: [URL] = []) -> ScanContext {
        ScanContext(home: home, temporaryDirectory: tmp, policy: policy(extraRoots: extraRoots), processes: processes,
                    commandRunner: runner, fileSystem: LocalFileSystem())
    }
}
