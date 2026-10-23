import Darwin
import Foundation
import Testing
@testable import Clear

/// Validation against the real file system, inside a private temp directory.
@Suite("CleanupValidator — re-verification right before removal")
struct CleanupValidatorTests {
    let temp: TempDirectory
    let env: FakeEnvironment
    let caches: URL

    init() throws {
        temp = try TempDirectory()
        env = try FakeEnvironment(temp)
        caches = try temp.dir("home/Library/Caches")
    }

    func validator(_ policy: SafetyPolicy? = nil) -> CleanupValidator {
        CleanupValidator(policy: policy ?? env.policy(), fileSystem: LocalFileSystem(), commandRunner: MockCommandRunner())
    }

    func candidate(_ relative: String, spec: CandidateSpec? = nil) throws -> CleanupCandidate {
        let ctx = env.context()
        let s = spec ?? CandidateSpec(title: "t", category: .appCache, ruleID: "test", risk: .safe, riskReason: "",
                                      impact: "", regenerable: true)
        return try #require(ctx.makeCandidate(at: temp.url.appendingPathComponent(relative), root: caches, spec: s))
    }

    @Test("A cache folder that did not change is approved")
    func approves() throws {
        try temp.file("home/Library/Caches/com.example/blob", size: 8192)
        let c = try candidate("home/Library/Caches/com.example")
        #expect(c.risk == .safe)
        #expect(validator().validate(c, processes: .empty) == .approved)
    }

    @Test("A symlink is never a candidate, so its target cannot be reached")
    func symlinkCandidate() throws {
        let outside = try temp.file("outside/precious.txt")
        try FileManager.default.createSymbolicLink(atPath: caches.appendingPathComponent("link").path, withDestinationPath: outside.path)
        let ctx = env.context()
        let spec = CandidateSpec(title: "t", category: .appCache, ruleID: "t", risk: .safe, riskReason: "", impact: "", regenerable: true)
        #expect(ctx.makeCandidate(at: caches.appendingPathComponent("link"), root: caches, spec: spec) == nil)
    }

    @Test("Replacing the item after the scan (TOCTOU) is detected")
    func replacedAfterScan() throws {
        try temp.file("home/Library/Caches/com.example/blob")
        let c = try candidate("home/Library/Caches/com.example")
        try FileManager.default.removeItem(at: caches.appendingPathComponent("com.example"))
        try temp.file("home/Library/Caches/com.example/other")
        #expect(validator().validate(c, processes: .empty).rejectionReason != nil)
    }

    @Test("A path swapped for a symlink after the scan is rejected")
    func swappedForSymlink() throws {
        try temp.file("home/Library/Caches/com.example/blob")
        let c = try candidate("home/Library/Caches/com.example")
        let elsewhere = try temp.dir("elsewhere")
        try FileManager.default.removeItem(at: caches.appendingPathComponent("com.example"))
        try FileManager.default.createSymbolicLink(atPath: caches.appendingPathComponent("com.example").path,
                                                   withDestinationPath: elsewhere.path)
        #expect(validator().validate(c, processes: .empty).rejectionReason != nil)
    }

    @Test("A user file modified after the scan is rejected")
    func modifiedFile() throws {
        try temp.file("home/Downloads/big.dmg", size: 4096, modified: .daysAgo(30))
        let downloads = temp.url.appendingPathComponent("home/Downloads")
        let ctx = env.context()
        let spec = CandidateSpec(title: "big", category: .downloads, ruleID: "t", risk: .manual, riskReason: "", impact: "",
                                 regenerable: false, preferredMethod: .trash, allowsPermanentRemoval: false,
                                 toleratesContentChanges: false)
        let c = try #require(ctx.makeCandidate(at: downloads.appendingPathComponent("big.dmg"), root: downloads, spec: spec))
        #expect(validator().validate(c, processes: .empty) == .approved)
        try Data(repeating: 1, count: 8192).write(to: downloads.appendingPathComponent("big.dmg"))
        #expect(validator().validate(c, processes: .empty).rejectionReason != nil)
    }

    @Test("An item that disappeared is reported as already gone, not as an error")
    func alreadyGone() throws {
        try temp.file("home/Library/Caches/com.example/blob")
        let c = try candidate("home/Library/Caches/com.example")
        try FileManager.default.removeItem(at: caches.appendingPathComponent("com.example"))
        #expect(validator().validate(c, processes: .empty) == .alreadyGone)
    }

    @Test("A guarded app that is running blocks removal")
    func runningGuard() throws {
        try temp.file("home/Library/Caches/com.example/blob")
        var spec = CandidateSpec(title: "t", category: .appCache, ruleID: "t", risk: .safe, riskReason: "", impact: "", regenerable: true)
        spec.guards = [.app("com.example", "Example")]
        let c = try candidate("home/Library/Caches/com.example", spec: spec)
        let running = ProcessSnapshot(bundleIdentifiers: ["com.example"])
        #expect(validator().validate(c, processes: running).rejectionReason?.contains("Example") == true)
        #expect(validator().validate(c, processes: .empty) == .approved)
    }

    @Test("Roots that are not registered with the policy are refused")
    func unregisteredRoot() throws {
        let outside = try temp.dir("random")
        try temp.file("random/thing/file")
        let id = try LocalFileSystem().identity(atPath: outside.appendingPathComponent("thing").path)
        let c = Fixtures.candidate(path: outside.appendingPathComponent("thing").path, identity: id, root: outside.path)
        #expect(validator().validate(c, processes: .empty).rejectionReason != nil)
    }

    @Test("A candidate that escapes its root with '..' is refused")
    func dotDot() throws {
        try temp.file("home/Library/Caches/a/file")
        let id = try LocalFileSystem().identity(atPath: caches.appendingPathComponent("a").path)
        let c = Fixtures.candidate(path: caches.path + "/a/../../../Documents", identity: id, root: caches.path)
        #expect(validator().validate(c, processes: .empty).rejectionReason != nil)
    }

    @Test("Blocked risk is never approved, even if everything else checks out")
    func blockedRisk() throws {
        try temp.file("home/Library/Caches/com.example/blob")
        var c = try candidate("home/Library/Caches/com.example")
        c.risk = .blocked
        #expect(validator().validate(c, processes: .empty).rejectionReason != nil)
    }

    @Test("Excluded paths are refused at execution time too")
    func exclusionAtExecution() throws {
        try temp.file("home/Library/Caches/com.example/blob")
        let c = try candidate("home/Library/Caches/com.example")
        let policy = env.policy(exclusions: [caches.appendingPathComponent("com.example").path])
        #expect(validator(policy).validate(c, processes: .empty).rejectionReason != nil)
    }
}

/// Validation logic with a mock file system: volumes, ownership, permissions.
@Suite("CleanupValidator with MockFileSystem")
struct CleanupValidatorMockTests {
    let fs = MockFileSystem()
    let root = "/mock/home/Library/Caches"
    var policy: SafetyPolicy { SafetyPolicy(home: URL(fileURLWithPath: "/mock/home"), temporaryDirectory: URL(fileURLWithPath: "/mock/tmp")) }
    var validator: CleanupValidator { CleanupValidator(policy: policy, fileSystem: fs, commandRunner: MockCommandRunner()) }

    init() { fs.add(root, device: 1) }

    @Test("An item on another volume than its root (mount point / external drive) is refused")
    func otherVolume() {
        let id = fs.add(root + "/mounted", device: 7)
        #expect(validator.validate(Fixtures.candidate(path: root + "/mounted", identity: id, root: root), processes: .empty)
            .rejectionReason != nil)
    }

    @Test("Items owned by another user are refused")
    func otherOwner() {
        let id = fs.add(root + "/rootowned", owner: 0)
        #expect(validator.validate(Fixtures.candidate(path: root + "/rootowned", identity: id, root: root), processes: .empty)
            .rejectionReason != nil)
    }

    @Test("A parent without write permission is refused")
    func noPermission() {
        let id = fs.add(root + "/locked")
        fs.makeUnwritable(root)
        #expect(validator.validate(Fixtures.candidate(path: root + "/locked", identity: id, root: root), processes: .empty)
            .rejectionReason != nil)
    }

    @Test("Commands need a trusted executable")
    func commands() {
        let c = Fixtures.candidate(path: "", identity: FileIdentity(device: 0, inode: 0, kind: .other, modificationTime: 0, ownerUID: 0),
                                   root: root, target: .command(TrustedCommand(tool: .brew, arguments: ["cleanup"])))
        #expect(CleanupValidator(policy: policy, fileSystem: fs, commandRunner: MockCommandRunner()).validate(c, processes: .empty)
            .rejectionReason != nil)
        #expect(CleanupValidator(policy: policy, fileSystem: fs, commandRunner: MockCommandRunner(available: [.brew]))
            .validate(c, processes: .empty) == .approved)
    }
}
