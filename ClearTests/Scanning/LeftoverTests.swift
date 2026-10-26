import Darwin
import Foundation
import Testing
@testable import Clear

@Suite("Leftovers — uninstalled apps, hidden caches, broken login items")
struct LeftoverTests {
    let temp: TempDirectory
    let env: FakeEnvironment
    let mb = 1024 * 1024 + 512

    init() throws {
        temp = try TempDirectory()
        env = try FakeEnvironment(temp)
        try temp.file("home/Library/Application Support/com.gone.app/data.db", size: mb)          // uninstalled
        try temp.file("home/Library/Application Support/com.present.app/data", size: mb)          // installed
        try temp.file("home/Library/Application Support/com.present.helper/data", size: mb)       // same vendor as installed
        try temp.file("home/Library/Application Support/com.apple.something/data", size: mb)      // Apple
        try temp.file("home/Library/Application Support/SomeAppName/data", size: mb)              // not a bundle id
        try temp.file("home/Library/WebKit/com.gone.app/WebsiteData/x", size: mb)
        try temp.file("home/Library/Containers/com.gone.app/Data/doc", size: mb)
        try temp.file("home/.m2/repository/org/lib.jar", size: 6 * 1024 * 1024)
        try temp.file("home/.cargo/bin/rg", size: 6 * 1024 * 1024)
        try temp.file("home/.cargo/registry/cache/x.crate", size: 6 * 1024 * 1024)
        try temp.file("home/.cache/pip/http/blob", size: 6 * 1024 * 1024)
        try temp.file("home/.cache/huggingface/hub/model.bin", size: 6 * 1024 * 1024)
        try temp.file("home/Library/iTunes/iPhone Software Updates/iPhone_18.0.ipsw", size: 11 * 1024 * 1024)
        let broken: [String: Any] = ["Label": "com.gone.agent", "ProgramArguments": ["/nonexistent/path/agent", "--run"]]
        let working: [String: Any] = ["Label": "com.ok.agent", "Program": "/bin/ls"]
        try temp.file("home/Library/LaunchAgents/com.gone.agent.plist",
                      data: try PropertyListSerialization.data(fromPropertyList: broken, format: .xml, options: 0))
        try temp.file("home/Library/LaunchAgents/com.ok.agent.plist",
                      data: try PropertyListSerialization.data(fromPropertyList: working, format: .xml, options: 0))
    }

    func scan(containers: Bool = true) -> [CleanupCandidate] {
        var report = GeneralScanReport()
        LeftoverScanner(installedBundleIDs: ["com.present.app"], includeContainers: containers).scan(env.context(), into: &report)
        return report.candidates
    }

    @Test("Only bundle-ID folders of uninstalled apps from vendors with nothing installed are leftovers")
    func orphans() {
        let orphans = scan().filter { $0.category == .orphanedAppData }
        let paths = orphans.compactMap(\.path)
        #expect(paths.contains { $0.hasSuffix("Application Support/com.gone.app") })
        #expect(paths.contains { $0.hasSuffix("WebKit/com.gone.app") })
        #expect(paths.contains { $0.hasSuffix("Containers/com.gone.app") })
        #expect(!paths.contains { $0.contains("com.present") })
        #expect(!paths.contains { $0.contains("com.apple") })
        #expect(!paths.contains { $0.contains("SomeAppName") })
        // App data is never pre-selected and always goes to the Trash.
        #expect(orphans.allSatisfy { !$0.isDefaultSelected && !$0.allowsPermanentRemoval })
    }

    @Test("Containers are skipped without Full Disk Access (macOS would prompt per app)")
    func containersNeedAccess() {
        #expect(!scan(containers: false).contains { $0.path?.contains("/Containers/") == true })
    }

    @Test("Hidden tool caches are found; installed tools and AI models are left alone")
    func hiddenCaches() {
        let hidden = scan().filter { $0.category == .hiddenCache }.compactMap(\.path)
        #expect(hidden.contains { $0.hasSuffix(".m2/repository") })
        #expect(hidden.contains { $0.hasSuffix(".cargo/registry") })
        #expect(hidden.contains { $0.hasSuffix(".cache/pip") })
        #expect(!hidden.contains { $0.contains(".cargo/bin") })
        #expect(!hidden.contains { $0.contains("huggingface") })
        #expect(env.policy().protectionReason(for: env.home.appendingPathComponent(".cargo/bin").path) != nil)
    }

    @Test("Login items whose program no longer exists are flagged; working ones are not")
    func brokenLoginItems() {
        let items = scan().filter { $0.category == .brokenLoginItem }
        #expect(items.map(\.title) == ["com.gone.agent"])
        #expect(items.allSatisfy { $0.risk == .review })
    }

    @Test("Old device software updates are offered for review")
    func softwareUpdates() {
        #expect(scan().contains { $0.category == .softwareUpdates && $0.title == "iPhone_18.0.ipsw" })
    }
}

@Suite("Large files — home folder search")
struct LargeFileScannerTests {
    @Test("Finds large files including hidden ones, skips Library, Trash, apps and dependency folders")
    func scanning() throws {
        let temp = try TempDirectory()
        let home = try temp.dir("home")
        let big = 2 * 1024 * 1024
        try temp.file("home/Movies/clip.mov", size: big)
        try temp.file("home/.hidden-tool/archive.tar", size: big)
        try temp.file("home/Library/Caches/huge.bin", size: big)
        try temp.file("home/.Trash/old.zip", size: big)
        try temp.file("home/Applications/Some.app/Contents/blob", size: big)
        try temp.file("home/Projects/web/node_modules/pkg/big.wasm", size: big)
        try temp.file("home/Documents/small.txt", size: 1000)

        let result = try LargeFileScanner(minimumSize: 1024 * 1024).scan(home: home) { _ in }
        let names = Set(result.items.map(\.name))
        #expect(names == ["clip.mov", "archive.tar"])
        #expect(result.items.first { $0.name == "archive.tar" }?.isHidden == true)
        #expect(result.items.first { $0.name == "clip.mov" }?.type == .video)
    }
}

@Suite("AI tool data is protected at any depth")
struct AIToolDataProtectionTests {
    @Test("Conversation logs and databases inside ~/.codex and ~/.claude are refused; their caches are not")
    func protectedFiles() throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let policy = env.policy()
        let home = env.home.path
        #expect(policy.protectionReason(for: home + "/.codex/thread_history_1.sqlite") != nil)
        #expect(policy.protectionReason(for: home + "/.codex/sessions/2026/10/rollout.jsonl") != nil)
        #expect(policy.protectionReason(for: home + "/.claude/projects/x/session.jsonl") != nil)
        #expect(policy.protectionReason(for: home + "/.codex/cache") == nil)
        #expect(policy.protectionReason(for: home + "/.claude/shell-snapshots") == nil)
    }

    @Test("Large-file search never lists AI tool, emulator or cache folders")
    func largeFilesSkipToolData() throws {
        let temp = try TempDirectory()
        let home = try temp.dir("home")
        let big = 2 * 1024 * 1024
        try temp.file("home/.codex/thread_history_1.sqlite", size: big)
        try temp.file("home/.claude/projects/p/s.jsonl", size: big)
        try temp.file("home/.android/avd/Phone.avd/ram.bin", size: big)
        try temp.file("home/.cache/pip/blob", size: big)
        try temp.file("home/Movies/keep.mov", size: big)
        let result = try LargeFileScanner(minimumSize: 1024 * 1024).scan(home: home) { _ in }
        #expect(result.items.map(\.name) == ["keep.mov"])
    }
}
