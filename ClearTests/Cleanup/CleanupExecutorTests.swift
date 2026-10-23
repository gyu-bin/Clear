import Foundation
import Testing
@testable import Clear

/// The executor runs against MockFileSystem: nothing on disk is touched.
@Suite("CleanupExecutor — execution, isolation of failures, cancellation")
struct CleanupExecutorTests {
    let fs = MockFileSystem()
    let root = "/mock/home/Library/Caches"
    var policy: SafetyPolicy { SafetyPolicy(home: URL(fileURLWithPath: "/mock/home"), temporaryDirectory: URL(fileURLWithPath: "/mock/tmp")) }

    init() { fs.add(root) }

    func executor(processes: ProcessInspecting = StaticProcessInspector(value: .empty),
                  runner: MockCommandRunner = MockCommandRunner()) -> CleanupExecutor {
        CleanupExecutor(validator: CleanupValidator(policy: policy, fileSystem: fs, commandRunner: runner),
                        fileSystem: fs, processes: processes, commandRunner: runner, volumes: VolumeService(),
                        measureVolume: false)
    }

    func plan(_ names: [String], preferTrash: Bool = false) -> CleanupPlan {
        let candidates = names.map { name in
            Fixtures.candidate(path: root + "/" + name, identity: (try? fs.identity(atPath: root + "/" + name))
                ?? FileIdentity(device: 1, inode: 999_999, kind: .directory, modificationTime: 0, ownerUID: getuid()), root: root)
        }
        return CleanupPlanner(preferTrash: preferTrash).makePlan(title: "test", selection: candidates)
    }

    @Test("One failing item does not stop the others")
    func isolatesFailures() async {
        fs.add(root + "/a"); fs.add(root + "/b"); fs.add(root + "/c")
        fs.fail(root + "/b", with: .permissionDenied(root + "/b"))
        let report = await executor().execute(plan(["a", "b", "c"])) { _ in }
        #expect(report.results.map(\.status) == [.removed, .failed, .removed])
        #expect(!fs.contains(root + "/a") && fs.contains(root + "/b") && !fs.contains(root + "/c"))
        #expect(report.failed.first?.message != nil)
    }

    @Test("Only planned paths are touched")
    func touchesOnlyPlanned() async {
        fs.add(root + "/a"); fs.add(root + "/keep")
        _ = await executor().execute(plan(["a"])) { _ in }
        #expect(fs.operations == ["remove \(root)/a"])
        #expect(fs.contains(root + "/keep"))
    }

    @Test("Items changed since the scan are skipped, not removed")
    func skipsChanged() async {
        fs.add(root + "/a")
        let p = plan(["a"])
        fs.replace(root + "/a") // new inode
        let report = await executor().execute(p) { _ in }
        #expect(report.results.first?.status == .skipped)
        #expect(fs.operations.isEmpty)
    }

    @Test("Running guarded apps cause a skip")
    func skipsRunning() async {
        fs.add(root + "/a")
        let c = Fixtures.candidate(path: root + "/a", identity: try! fs.identity(atPath: root + "/a"), root: root,
                                   guards: [.app("com.example", "Example")])
        let p = CleanupPlanner(preferTrash: false).makePlan(title: "t", selection: [c])
        let report = await executor(processes: StaticProcessInspector(value: ProcessSnapshot(bundleIdentifiers: ["com.example"])))
            .execute(p) { _ in }
        #expect(report.results.first?.status == .skipped)
        #expect(fs.contains(root + "/a"))
    }

    @Test("Cancellation stops before the next item")
    func cancellation() async {
        fs.add(root + "/a"); fs.add(root + "/b"); fs.add(root + "/c")
        let exec = executor(processes: CancellingProcessInspector())
        let p = plan(["a", "b", "c"])
        // Run in a child task so the cancellation does not hit the test's own task.
        let report = await Task { await exec.execute(p) { _ in } }.value
        #expect(report.wasCancelled)
        #expect(report.results.map(\.status) == [.removed, .cancelled, .cancelled])
        #expect(fs.contains(root + "/b") && fs.contains(root + "/c"))
    }

    @Test("Trash moves are reported separately from freed space")
    func trashAccounting() async {
        fs.add(root + "/a", size: 10_000)
        let report = await executor().execute(plan(["a"], preferTrash: true)) { _ in }
        #expect(report.results.first?.status == .trashed)
        #expect(report.trashedBytes == 4096)
        #expect(report.removedBytes == 0, "trashed bytes are not freed until the Trash is emptied")
    }

    @Test("Commands run through the runner with fixed arguments")
    func commands() async {
        let calls = CallRecorder()
        let runner = MockCommandRunner(available: [.brew]) { tool, args in
            calls.record("\(tool.rawValue) \(args.joined(separator: " "))")
            return CommandResult(exitCode: 0, stdout: "Removing: x\n", stderr: "")
        }
        let c = Fixtures.candidate(path: "", identity: FileIdentity(device: 0, inode: 0, kind: .other, modificationTime: 0, ownerUID: 0),
                                   root: root, risk: .review, target: .command(TrustedCommand(tool: .brew, arguments: ["cleanup"])))
        let report = await executor(runner: runner).execute(CleanupPlanner(preferTrash: true).makePlan(title: "t", selection: [c])) { _ in }
        #expect(report.results.first?.status == .commandSucceeded)
        #expect(calls.values == ["brew cleanup"])
    }

    @Test("Progress reaches completion")
    func progress() async {
        fs.add(root + "/a"); fs.add(root + "/b")
        let seen = CallRecorder()
        _ = await executor().execute(plan(["a", "b"])) { seen.record("\($0.completed)/\($0.total)") }
        #expect(seen.values.last == "2/2")
    }
}

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ s: String) { lock.withLock { items.append(s) } }
    var values: [String] { lock.withLock { items } }
}
