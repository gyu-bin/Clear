import Foundation
import Testing
@testable import Clear

@Suite("CleanupPlanner — selection to executable plan")
struct CleanupPlannerTests {
    let root = "/mock/home/Library/Caches"
    func id(_ n: UInt64) -> FileIdentity { FileIdentity(device: 1, inode: n, kind: .directory, modificationTime: 0, ownerUID: getuid()) }

    @Test("Blocked items are dropped and reported")
    func dropsBlocked() {
        let plan = CleanupPlanner(preferTrash: false).makePlan(title: "t", selection: [
            Fixtures.candidate(path: root + "/a", identity: id(1), root: root),
            Fixtures.candidate(path: root + "/b", identity: id(2), root: root, risk: .blocked),
        ])
        #expect(plan.items.map(\.candidate.path) == [root + "/a"])
        #expect(plan.excluded.count == 1)
    }

    @Test("Nested and duplicate selections are counted once")
    func nested() {
        let plan = CleanupPlanner(preferTrash: false).makePlan(title: "t", selection: [
            Fixtures.candidate(path: root + "/app", identity: id(1), root: root, size: 1000),
            Fixtures.candidate(path: root + "/app/sub", identity: id(2), root: root, size: 400),
            Fixtures.candidate(path: root + "/app", identity: id(1), root: root, size: 1000),
        ])
        #expect(plan.items.count == 1)
        #expect(plan.estimatedBytes == 1000)
    }

    @Test("Prefer-trash moves even regenerable caches to the Trash")
    func preferTrash() {
        let c = Fixtures.candidate(path: root + "/a", identity: id(1), root: root)
        #expect(CleanupPlanner(preferTrash: true).makePlan(title: "t", selection: [c]).items[0].method == .trash)
        #expect(CleanupPlanner(preferTrash: false).makePlan(title: "t", selection: [c]).items[0].method == .permanent)
    }

    @Test("User files are always trashed, whatever the setting")
    func userFilesAlwaysTrash() {
        let c = Fixtures.candidate(path: "/mock/home/Downloads/a.dmg", identity: id(1), root: "/mock/home/Downloads",
                                   risk: .manual, method: .trash, regenerable: false, allowsPermanent: false)
        let plan = CleanupPlanner(preferTrash: false).makePlan(title: "t", selection: [c])
        #expect(plan.items[0].method == .trash)
        #expect(plan.items[0].isRecoverable)
        #expect(plan.requiresExplicitAcknowledgement, "MANUAL items need an explicit acknowledgement")
    }

    @Test("Plans with only SAFE path items do not need the extra acknowledgement")
    func safeOnly() {
        let plan = CleanupPlanner(preferTrash: true).makePlan(title: "t", selection: [Fixtures.candidate(path: root + "/a", identity: id(1), root: root)])
        #expect(!plan.requiresExplicitAcknowledgement)
        #expect(plan.warnings.contains { $0.contains("휴지통") })
    }
}
