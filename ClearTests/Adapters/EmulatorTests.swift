import Foundation
import Testing
@testable import Clear

@Suite("Emulators, system images and virtual machines")
struct EmulatorTests {
    let big = 60 * 1024 * 1024

    private func makeAVD(_ temp: TempDirectory, name: String, image: String) throws {
        try temp.file("home/.android/avd/\(name).avd/userdata-qemu.img.qcow2", size: big)
        try temp.file("home/.android/avd/\(name).avd/snapshots/default_boot/ram.img", size: 110 * 1024 * 1024)
        try temp.file("home/.android/avd/\(name).avd/config.ini",
                      data: Data("avd.ini.displayname=\(name) Phone\nimage.sysdir.1=\(image)/\n".utf8))
        try temp.file("home/.android/avd/\(name).ini", data: Data("path=x\n".utf8))
    }

    @Test("An emulator is offered with its .ini, snapshots alone, and only unused system images")
    func scan() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        try makeAVD(temp, name: "Pixel", image: "system-images/android-35/google_apis/arm64-v8a")
        try temp.file("home/Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img", size: big)
        try temp.file("home/Library/Android/sdk/system-images/android-33/default/arm64-v8a/system.img", size: big)

        let report = await GradleAdapter().scan(env.context())
        let avd = try #require(report.candidates.first { $0.ruleID == "dev.android.avd" })
        #expect(avd.risk == .manual)
        #expect(avd.title == "Android 에뮬레이터 · Pixel Phone")
        #expect(avd.target.pathTarget?.companions.map { ($0.path as NSString).lastPathComponent } == ["Pixel.ini"])
        #expect(report.candidates.first { $0.ruleID == "dev.android.avdSnapshots" }?.risk == .review)
        let images = report.candidates.filter { $0.ruleID == "dev.android.systemImage" }
        #expect(images.count == 1)
        #expect(images.first?.path?.contains("android-33") == true)

        // A running emulator for this device is reported.
        var processes = ProcessSnapshot()
        processes.interpreterCommandLines = ["qemu-system-aarch64 -avd pixel -no-window"]
        let running = await GradleAdapter().scan(env.context(processes: processes))
        #expect(running.candidates.first { $0.ruleID == "dev.android.avd" }?.runningGuards.isEmpty == false)
    }

    @Test("Removing an emulator also removes its .ini pointer (temp fixture)")
    func removal() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        try makeAVD(temp, name: "Pixel", image: "system-images/android-35/google_apis/arm64-v8a")
        let report = await GradleAdapter().scan(env.context())
        let avd = try #require(report.candidates.first { $0.ruleID == "dev.android.avd" })

        let fs = LocalFileSystem()
        let executor = CleanupExecutor(validator: CleanupValidator(policy: env.policy(), fileSystem: fs, commandRunner: MockCommandRunner()),
                                       fileSystem: fs, processes: StaticProcessInspector(value: .empty),
                                       commandRunner: MockCommandRunner(), volumes: VolumeService(), measureVolume: false)
        // Real use sends emulators to the Trash; the test removes permanently so that
        // nothing leaves the temp fixture.
        #expect(CleanupPlanner(preferTrash: false).makePlan(title: "t", selection: [avd]).items.first?.method == .trash)
        let plan = CleanupPlan(title: "test", items: [CleanupPlanItem(candidate: avd, method: .permanent)],
                               excluded: [], warnings: [], createdAt: Date())
        let result = await executor.execute(plan) { _ in }
        #expect(result.results.first?.status == .removed, "\(String(describing: result.results.first))")
        #expect(result.results.first?.message == nil)
        let avdDir = env.home.appendingPathComponent(".android/avd")
        #expect(!FileManager.default.fileExists(atPath: avdDir.appendingPathComponent("Pixel.avd").path))
        #expect(!FileManager.default.fileExists(atPath: avdDir.appendingPathComponent("Pixel.ini").path))
        #expect(FileManager.default.fileExists(atPath: avdDir.path))
    }

    @Test("Virtual machines are manual, go to the Trash, and are blocked while their app runs")
    func virtualMachines() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        try temp.file("home/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img", size: 110 * 1024 * 1024)
        try temp.file("home/Parallels/Windows.pvm/disk.hdd", size: 110 * 1024 * 1024)

        let report = await VirtualMachineAdapter().scan(env.context())
        let claude = try #require(report.candidates.first { $0.ruleID == "vm.claude" })
        #expect(claude.risk == .manual)
        #expect(!claude.allowsPermanentRemoval)
        #expect(report.candidates.first { $0.ruleID == "vm.parallels" }?.title == "Parallels · Windows")

        var processes = ProcessSnapshot()
        processes.bundleIdentifiers = ["com.anthropic.claudefordesktop"]
        let running = await VirtualMachineAdapter().scan(env.context(processes: processes))
        #expect(running.candidates.first { $0.ruleID == "vm.claude" }?.risk == .blocked)
    }
}
