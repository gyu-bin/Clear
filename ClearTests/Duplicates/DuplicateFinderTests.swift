import Darwin
import Foundation
import Testing
@testable import Clear

@Suite("DuplicateFinder — verified-identical files only")
struct DuplicateFinderTests {
    let temp: TempDirectory
    init() throws { temp = try TempDirectory() }

    func scan() throws -> DuplicateScanResult {
        try DuplicateFinder(minimumSize: 1).scan(roots: [temp.url.appendingPathComponent("scan")]) { _ in }
    }

    @Test("Identical content is grouped, and the original is suggested as keeper")
    func identical() throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try temp.file("scan/photo.jpg", data: payload)
        try temp.file("scan/sub/photo copy.jpg", data: payload)
        let result = try scan()
        #expect(result.groups.count == 1)
        #expect(result.groups[0].files.count == 2)
        #expect(result.groups[0].wastedBytes == 300_000)
        #expect(result.groups[0].suggestedKeeper?.hasSuffix("/photo.jpg") == true)
    }

    @Test("Same size and same head/tail but different middle is NOT a duplicate")
    func sameEndsDifferentMiddle() throws {
        var a = Data(repeating: 7, count: 400_000)
        var b = a
        a[200_000] = 1
        b[200_000] = 2
        try temp.file("scan/a.bin", data: a)
        try temp.file("scan/b.bin", data: b)
        #expect(try scan().groups.isEmpty)
    }

    @Test("Hard links are the same file, not duplicates")
    func hardLinks() throws {
        let a = try temp.file("scan/a.bin", size: 10_000)
        #expect(link(a.path, temp.path + "/scan/b.bin") == 0)
        let result = try scan()
        #expect(result.groups.isEmpty)
        #expect(result.hardLinkSets == 1)
    }

    @Test("Symlinks are ignored")
    func symlinks() throws {
        let a = try temp.file("scan/a.bin", size: 10_000)
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/scan/link.bin", withDestinationPath: a.path)
        #expect(try scan().groups.isEmpty)
    }

    @Test("Photos libraries and app bundles are not searched")
    func packages() throws {
        try temp.file("scan/Photos Library.photoslibrary/originals/a.jpg", size: 10_000)
        try temp.file("scan/Photos Library.photoslibrary/originals/b.jpg", size: 10_000)
        try temp.file("scan/Tool.app/Contents/x", size: 10_000)
        try temp.file("scan/Tool.app/Contents/y", size: 10_000)
        let result = try scan()
        #expect(result.groups.isEmpty)
        #expect(result.skippedProtected.count == 1)
    }

    @Test("No keeper is suggested when the original is ambiguous")
    func ambiguous() {
        func f(_ name: String) -> DuplicateFile {
            DuplicateFile(path: "/x/" + name, name: name, logicalSize: 1, allocatedSize: 1, modified: Date(),
                          identity: FileIdentity(device: 1, inode: UInt64(name.hashValue.magnitude), kind: .file, modificationTime: 0, ownerUID: 0))
        }
        #expect(DuplicateFinder.suggestKeeper([f("a.jpg"), f("b.jpg")]) == nil)
        #expect(DuplicateFinder.suggestKeeper([f("a.jpg"), f("a (1).jpg"), f("a 2.jpg")]) == "/x/a.jpg")
        #expect(DuplicateFinder.suggestKeeper([f("a copy.jpg"), f("a 복사본.jpg")]) == nil)
    }

    @Test("Large files are hashed in a streaming fashion")
    func streamingHash() throws {
        let big = try temp.file("scan/big.bin", size: 5 * 1024 * 1024)
        let id = try LocalFileSystem().identity(atPath: big.path)
        let file = DuplicateFile(path: big.path, name: "big.bin", logicalSize: id.logicalSize, allocatedSize: id.allocatedSize,
                                 modified: id.modificationDate, identity: id)
        let finder = DuplicateFinder(minimumSize: 1, chunkSize: 64 * 1024)
        #expect(try finder.hash(file, partial: false) == finder.hash(file, partial: false))
        #expect(try finder.hash(file, partial: true).count == 64)
    }
}
