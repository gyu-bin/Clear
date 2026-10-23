import Darwin
import Foundation
import Testing
@testable import Clear

@Suite("SafeRemover — descriptor-based deletion inside a temp directory")
struct SafeRemoverTests {
    let temp: TempDirectory
    init() throws { temp = try TempDirectory() }

    func identity(_ rel: String) throws -> FileIdentity {
        try LocalFileSystem().identity(atPath: temp.url.appendingPathComponent(rel).path)
    }

    @Test("Removes a nested tree and reports freed blocks")
    func removesTree() throws {
        try temp.file("target/a.bin", size: 16_384)
        try temp.file("target/sub/b.bin", size: 8192)
        try temp.dir("target/empty")
        let stats = try SafeRemover().remove(canonicalPath: temp.path + "/target", expected: identity("target"), shouldCancel: { false })
        #expect(!temp.exists("target"))
        #expect(stats.removedFiles == 2)
        #expect(stats.logicalBytes == 24_576)
        #expect(stats.freedBytes >= 24_576)
    }

    @Test("Symlinks inside the tree are unlinked, never followed")
    func doesNotFollowSymlinks() throws {
        let precious = try temp.file("outside/precious.txt", size: 100)
        try temp.dir("target")
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/target/link-to-file", withDestinationPath: precious.path)
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/target/link-to-dir", withDestinationPath: temp.path + "/outside")
        _ = try SafeRemover().remove(canonicalPath: temp.path + "/target", expected: identity("target"), shouldCancel: { false })
        #expect(!temp.exists("target"))
        #expect(FileManager.default.fileExists(atPath: precious.path), "the symlink target outside must survive")
    }

    @Test("Hard-linked files are unlinked but not counted as freed space")
    func hardLinks() throws {
        let shared = try temp.file("outside/shared.bin", size: 65_536)
        try temp.dir("target")
        #expect(link(shared.path, temp.path + "/target/shared-link.bin") == 0)
        let stats = try SafeRemover().remove(canonicalPath: temp.path + "/target", expected: identity("target"), shouldCancel: { false })
        #expect(stats.sharedBytes >= 65_536)
        #expect(stats.freedBytes < 65_536)
        #expect(FileManager.default.fileExists(atPath: shared.path))
    }

    @Test("Refuses when the inode differs from the scanned one")
    func identityMismatch() throws {
        try temp.file("target/a")
        let old = try identity("target")
        try FileManager.default.removeItem(at: temp.url.appendingPathComponent("target"))
        try temp.file("target/b")
        #expect(throws: FileSystemError.identityMismatch(temp.path + "/target")) {
            try SafeRemover().remove(canonicalPath: temp.path + "/target", expected: old, shouldCancel: { false })
        }
        #expect(temp.exists("target/b"))
    }

    @Test("Refuses a path that runs through a symlinked directory")
    func symlinkedAncestor() throws {
        try temp.file("real/victim/file")
        let expected = try identity("real/victim")
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/alias", withDestinationPath: temp.path + "/real")
        #expect(throws: FileSystemError.pathChanged(temp.path + "/alias/victim")) {
            try SafeRemover().remove(canonicalPath: temp.path + "/alias/victim", expected: expected, shouldCancel: { false })
        }
        #expect(temp.exists("real/victim/file"))
    }

    @Test("Cancellation stops the walk")
    func cancellation() throws {
        for i in 0..<20 { try temp.file("target/f\(i)") }
        #expect(throws: FileSystemError.cancelled) {
            try SafeRemover().remove(canonicalPath: temp.path + "/target", expected: identity("target"), shouldCancel: { true })
        }
        #expect(temp.exists("target"))
    }

    @Test("Removes a single file")
    func singleFile() throws {
        try temp.file("one.log", size: 4096)
        let stats = try SafeRemover().remove(canonicalPath: temp.path + "/one.log", expected: identity("one.log"), shouldCancel: { false })
        #expect(stats.removedFiles == 1)
        #expect(!temp.exists("one.log"))
    }

    @Test("Relative or dotted paths are refused before any system call")
    func malformed() throws {
        let id = FileIdentity(device: 0, inode: 0, kind: .directory, modificationTime: 0, ownerUID: getuid())
        #expect(throws: FileSystemError.self) {
            try SafeRemover().remove(canonicalPath: "relative/dir", expected: id, shouldCancel: { false })
        }
        #expect(throws: FileSystemError.self) {
            try SafeRemover().remove(canonicalPath: temp.path + "/../x", expected: id, shouldCancel: { false })
        }
    }
}
