import Darwin
import Foundation
import Testing
@testable import Clear

@Suite("DirectorySizer — logical vs allocated, links, permissions")
struct DirectorySizerTests {
    let temp: TempDirectory
    init() throws { temp = try TempDirectory() }

    @Test("Sums logical sizes and counts files")
    func sums() throws {
        try temp.file("d/a", size: 1000)
        try temp.file("d/sub/b", size: 3000)
        let size = try DirectorySizer().measure(path: temp.path + "/d")
        #expect(size.logical == 4000)
        #expect(size.fileCount == 2)
        #expect(size.directoryCount == 2)
        #expect(size.allocated >= size.logical, "allocated is block-rounded")
    }

    @Test("An empty folder measures zero files")
    func empty() throws {
        try temp.dir("empty")
        let size = try DirectorySizer().measure(path: temp.path + "/empty")
        #expect(size.fileCount == 0 && size.logical == 0 && size.inaccessibleCount == 0)
    }

    @Test("Symlinks are measured as links, not as their targets")
    func symlinks() throws {
        let big = try temp.file("outside/big.bin", size: 1_000_000)
        try temp.dir("d")
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/d/link", withDestinationPath: big.path)
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/d/dirlink", withDestinationPath: temp.path + "/outside")
        let size = try DirectorySizer().measure(path: temp.path + "/d")
        #expect(size.logical < 10_000)
    }

    @Test("Hard links are counted once and reported as shared")
    func hardLinks() throws {
        let a = try temp.file("d/a.bin", size: 100_000)
        #expect(link(a.path, temp.path + "/d/b.bin") == 0)
        let size = try DirectorySizer().measure(path: temp.path + "/d")
        #expect(size.logical == 100_000)
        #expect(size.sharedHardLinkBytes > 0)
    }

    @Test("The same inode is not summed twice across measurements by one sizer")
    func dedupAcrossCalls() throws {
        let a = try temp.file("one/a.bin", size: 50_000)
        try temp.dir("two")
        #expect(link(a.path, temp.path + "/two/a.bin") == 0)
        let sizer = DirectorySizer()
        let first = try sizer.measure(path: temp.path + "/one")
        let second = try sizer.measure(path: temp.path + "/two")
        #expect(first.logical + second.logical == 50_000)
    }

    @Test("Unreadable folders are reported, never silently counted as 0 B")
    func accessDenied() throws {
        try temp.file("d/visible", size: 2000)
        try temp.file("d/locked/secret", size: 9000)
        chmod(temp.path + "/d/locked", 0o000)
        let size = try DirectorySizer().measure(path: temp.path + "/d")
        #expect(size.inaccessibleCount >= 1)
        #expect(size.isPartial)
        #expect(size.logical == 2000)
    }

    @Test("Missing paths throw")
    func missing() {
        #expect(throws: FileSystemError.self) { try DirectorySizer().measure(path: temp.path + "/nope") }
    }

    @Test("Large directory performance: 5,000 files measured quickly")
    func performance() throws {
        for d in 0..<50 {
            try temp.dir("big/d\(d)")
            for f in 0..<100 { FileManager.default.createFile(atPath: temp.path + "/big/d\(d)/f\(f)", contents: Data([1, 2, 3])) }
        }
        let start = Date()
        let size = try DirectorySizer().measure(path: temp.path + "/big")
        #expect(size.fileCount == 5000)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite("DiskTreeScanner — Disk Explorer tree")
struct DiskTreeScannerTests {
    let temp: TempDirectory
    init() throws { temp = try TempDirectory() }

    @Test("Builds a tree whose folder sizes add up and flags restricted folders")
    func tree() throws {
        try temp.file("root/big/movie.mov", size: 2_000_000)
        try temp.file("root/small/a.txt", size: 100)
        try temp.file("root/locked/x", size: 100)
        chmod(temp.path + "/root/locked", 0o000)
        var scanner = DiskTreeScanner()
        scanner.largeFileThreshold = 1_000_000
        let result = try scanner.scan(root: temp.url.appendingPathComponent("root")) { _ in }
        let big = try #require(result.root.children.first { $0.name == "big" })
        #expect(big.allocatedSize >= 2_000_000)
        #expect(result.root.allocatedSize >= big.allocatedSize)
        #expect(result.root.isPartial)
        #expect(result.restrictedPaths.contains { $0.hasSuffix("/locked") })
        #expect(result.root.children.contains { $0.kind == .restricted && $0.name == "locked" })
        #expect(result.largeFiles.first?.name == "movie.mov")
        #expect(result.typeBreakdown[.video, default: 0] >= 2_000_000)
    }

    @Test("Small files are folded into one aggregate node to bound memory")
    func folding() throws {
        for i in 0..<30 { try temp.file("root/f\(i).txt", size: 10) }
        let result = try DiskTreeScanner().scan(root: temp.url.appendingPathComponent("root")) { _ in }
        #expect(result.root.children.count == 1)
        if case .aggregate(let count) = result.root.children[0].kind { #expect(count == 30) } else { Issue.record("expected aggregate") }
        #expect(result.root.fileCount == 30)
    }

    @Test("Treemap layout fills the rectangle without overlaps")
    func treemap() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rects = TreemapLayout.squarify([60, 25, 10, 5], in: rect)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(area - 120_000) < 1)
        for i in rects.indices { for j in rects.indices where i < j {
            #expect(rects[i].intersection(rects[j]).width * rects[i].intersection(rects[j]).height < 0.5)
        } }
        #expect(rects[0].width * rects[0].height > rects[1].width * rects[1].height)
    }
}

@Suite("APFS clones — what removing a tree really frees")
struct CloneSharingTests {
    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test("A clone of a file outside the tree frees nothing; clones that all sit inside free one copy")
    func clones() throws {
        let temp = try TempDirectory()
        let original = try temp.file("keep/original.bin", data: randomData(1024 * 1024))
        let inside = temp.url.appendingPathComponent("tree/copy.bin")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(clonefile(original.path, inside.path, 0) == 0)   // the test volume is APFS
        try temp.file("tree/own.bin", data: randomData(512 * 1024))

        let tree = try DirectorySizer().measure(path: temp.url.appendingPathComponent("tree").path)
        #expect(tree.sharedCloneBytes >= 1024 * 1024)
        #expect(tree.estimatedReclaimable < 700 * 1024)
        #expect(tree.estimatedReclaimable >= 512 * 1024)

        // Both copies inside: removing the folder frees one copy.
        let both = try DirectorySizer().measure(path: temp.url.path)
        #expect(both.estimatedReclaimable >= (1024 + 512) * 1024)
        #expect(both.estimatedReclaimable < (2 * 1024 + 512) * 1024)

        // Disk-usage mode skips the check.
        #expect(try DirectorySizer(checksClones: false).measure(path: temp.url.appendingPathComponent("tree").path).sharedCloneBytes == 0)
        #expect(CloneInfo.read(path: inside.path)?.referenceCount == 2)
    }

    @Test("Removal counts a clone's shared blocks as not freed, and the last copy as freed")
    func removal() throws {
        let temp = try TempDirectory()
        let original = try temp.file("keep/original.bin", data: randomData(1024 * 1024))
        let copy = temp.url.appendingPathComponent("tree/copy.bin")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(clonefile(original.path, copy.path, 0) == 0)

        var st = stat()
        #expect(lstat(copy.path, &st) == 0)
        #expect(SafeRemover.ownBytes(st, directory: AT_FDCWD, name: copy.path) == 0)
        try FileManager.default.removeItem(at: copy)
        #expect(lstat(original.path, &st) == 0)
        // The remaining copy now owns all of its blocks.
        #expect((SafeRemover.ownBytes(st, directory: AT_FDCWD, name: original.path) ?? 0) >= 1024 * 1024)
    }
}
