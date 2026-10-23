import Darwin
import Foundation
import Testing
@testable import Clear

@Suite("Empty Trash — only items inside a fake ~/.Trash, permanently, with confirmation")
struct TrashTests {
    let temp: TempDirectory
    let env: FakeEnvironment

    init() throws {
        temp = try TempDirectory()
        env = try FakeEnvironment(temp)
        try temp.file("home/.Trash/old.zip", size: 8192)
        try temp.file("home/.Trash/Folder/inner.txt", size: 4096)
        try temp.file("home/.Trash/Photos Library.photoslibrary/database/a", size: 4096)
        try temp.file("home/Documents/keep.txt", size: 4096)
        symlink(temp.url.appendingPathComponent("home/Documents").path,
                temp.url.appendingPathComponent("home/.Trash/link-to-documents").path)
    }

    @Test("Trash items become MANUAL candidates; symlinks are skipped and Photos libraries stay protected")
    func scanning() throws {
        let items = try TrashScanner().candidates(env.context())
        let names = Set(items.map(\.title))
        #expect(names.contains("old.zip"))
        #expect(names.contains("Folder"))
        #expect(!names.contains("link-to-documents"))
        #expect(items.allSatisfy { $0.category == .trash })
        let photos = try #require(items.first { $0.title.hasSuffix(".photoslibrary") })
        #expect(photos.risk == .blocked)
        #expect(items.filter { $0.risk != .blocked }.allSatisfy { $0.risk == .manual })
    }

    @Test("The Trash folder itself is protected")
    func rootProtected() {
        let trash = env.home.appendingPathComponent(".Trash").path
        #expect(env.policy().protectionReason(for: trash) != nil)
    }

    @Test("Planning removes trash items permanently and requires explicit acknowledgement")
    func planning() throws {
        let items = try TrashScanner().candidates(env.context()).filter { $0.risk != .blocked }
        let plan = CleanupPlanner(preferTrash: true).makePlan(title: "휴지통 비우기", selection: items)
        #expect(plan.items.allSatisfy { $0.method == .permanent })
        #expect(plan.requiresExplicitAcknowledgement)
        #expect(plan.warnings.contains { $0.contains("되돌릴 수 없") })
    }

    @Test("Emptying removes only the selected trash items; the Trash folder and the symlink target survive")
    func emptying() async throws {
        let ctx = env.context()
        let items = try TrashScanner().candidates(ctx).filter { $0.risk != .blocked }
        let plan = CleanupPlanner(preferTrash: true).makePlan(title: "휴지통 비우기", selection: items)
        let fs = LocalFileSystem()
        let executor = CleanupExecutor(
            validator: CleanupValidator(policy: env.policy(), fileSystem: fs, commandRunner: MockCommandRunner()),
            fileSystem: fs, processes: StaticProcessInspector(value: .empty), commandRunner: MockCommandRunner(),
            volumes: VolumeService(), measureVolume: false)
        let report = await executor.execute(plan) { _ in }

        #expect(report.results.allSatisfy { $0.status == .removed })
        #expect(!temp.exists("home/.Trash/old.zip"))
        #expect(!temp.exists("home/.Trash/Folder"))
        #expect(temp.exists("home/.Trash"))
        #expect(temp.exists("home/.Trash/Photos Library.photoslibrary"))
        #expect(temp.exists("home/.Trash/link-to-documents"))
        #expect(temp.exists("home/Documents/keep.txt"))
    }
}
