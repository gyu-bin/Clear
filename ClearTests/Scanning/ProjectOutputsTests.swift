import Foundation
import Testing
@testable import Clear

@Suite("Project outputs Git ignores — found anywhere, tracked or secret ones blocked")
struct IgnoredOutputTests {
    @Test("Build output, dependencies and reports are classified; tool data, tiny items and secrets are handled")
    func ignoredOutputs() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let project = try temp.dir("home/Code/Game")
        try temp.dir("home/Code/Game/.git")
        let big = 21 * 1024 * 1024
        try temp.file("home/Code/Game/mobile/dist/bundle.js", size: big)
        try temp.file("home/Code/Game/mobile/android/app/build/app.apk", size: big)
        try temp.file("home/Code/Game/mobile/Reports/qa/shot.png", size: big)
        try temp.file("home/Code/Game/mobile/node_modules/lib/index.js", size: big)
        try temp.file("home/Code/Game/renders/frame.png", size: big)
        try temp.file("home/Code/Game/mobile/out/data.bin", size: big)
        try temp.file("home/Code/Game/mobile/out/AuthKey.p8", size: 100)
        try temp.file("home/Code/Game/mobile/dist/TestResults/metadata.db", size: 100)
        try temp.file("home/Code/Game/mobile/dist/assets/expo-root.pem", size: 100)
        try temp.file("home/Code/Game/mobile/dist/SourcePackages/checkouts/Sparkle/test-key.p12", size: 100)
        try temp.file("home/Code/Game/renders/library.sqlite", size: 100)
        try temp.file("home/Code/Game/.claude/cache.bin", size: big)
        try temp.file("home/Code/Game/tiny/x", size: 1024)
        try temp.file("home/Code/Game/marketing/video.mov", size: big)
        try temp.file("home/Code/Game/marketing/promo/.venv/lib/site-packages/certifi/cacert.pem", size: 100)

        let ignored = ["mobile/dist/", "mobile/android/app/build/", "mobile/Reports/", "mobile/node_modules/",
                       "renders/", "marketing/", "mobile/out/", ".claude/", "tiny/", ".env.local"]
        let tracked: Set<String> = ["mobile/Reports"]
        let runner = MockCommandRunner(available: [.git]) { tool, args in
            guard tool == .git else { return CommandResult(exitCode: 1, stdout: "", stderr: "") }
            if args.contains("--ignored") { return CommandResult(exitCode: 0, stdout: ignored.joined(separator: "\0"), stderr: "") }
            let rel = args.last ?? ""
            return CommandResult(exitCode: 0, stdout: tracked.contains(rel) ? "\(rel)/design.md\0" : "", stderr: "")
        }
        let report = await ProjectAnalyzer().analyze(projectAt: project, ctx: env.context(runner: runner, extraRoots: [project]))
        func item(_ rel: String) -> CleanupCandidate? { report.candidates.first { $0.path?.hasSuffix("/Game/" + rel) == true } }

        #expect(item("mobile/dist")?.risk == .review)
        #expect(item("mobile/android/app/build")?.risk == .review)
        #expect(item("mobile/node_modules")?.risk == .manual)
        #expect(item("mobile/node_modules")?.category == .projectDependencies)
        // A folder holding committed files is never offered, even if .gitignore matches it.
        #expect(item("mobile/Reports")?.risk == .blocked)
        // Unknown generated folders need the user's decision and go to the Trash.
        // A database inside build output is the build system's cache; elsewhere it may be user data.
        #expect(item("renders")?.risk == .blocked)
        // Unknown generated folders need the user's decision and go to the Trash.
        let marketing = try #require(item("marketing"))
        #expect(marketing.risk == .manual)
        #expect(!marketing.allowsPermanentRemoval)
        #expect(item("mobile/out")?.risk == .blocked)
        #expect(item(".claude") == nil)
        #expect(item("tiny") == nil)
        #expect(item(".env.local") == nil)
        #expect(report.build > 0 && report.dependencies > 0)
    }

    @Test("Git repositories are discovered under home, without descending into dependencies")
    func discovery() throws {
        let temp = try TempDirectory()
        try temp.dir("home/Desktop/Coding/A/.git")
        try temp.dir("home/Desktop/Coding/A/sub/.git")
        try temp.dir("home/Documents/B/.git")
        try temp.dir("home/Documents/C/node_modules/pkg/.git")
        try temp.dir("home/Library/Thing/.git")
        try temp.dir("home/.hidden/D/.git")
        let found = ProjectDiscovery.find(home: temp.url.appendingPathComponent("home"))
        let names = Set(found.map { ($0 as NSString).lastPathComponent })
        #expect(names == ["A", "B"])
    }
}

@Suite("Claude Code session scratch folders")
struct AgentScratchTests {
    @Test("Idle sessions are REVIEW, recently written ones are BLOCKED, the root is never a candidate")
    func scratch() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let root = try temp.dir("claude-501")
        let old = Date().addingTimeInterval(-3 * 86_400)
        try temp.file("claude-501/-Users-x-Proj/s-old/scratchpad/build.bin", size: 11 * 1024 * 1024, modified: old)
        try temp.file("claude-501/-Users-x-Proj/s-new/scratchpad/build.bin", size: 11 * 1024 * 1024)
        try temp.file("claude-501/-Users-x-Proj/s-small/scratchpad/a", size: 1024, modified: old)

        var scanner = GeneralCleanupScanner()
        scanner.includeLeftovers = false
        scanner.agentScratchRoot = root
        let report = try await scanner.scan(env.context(extraRoots: [root]), appNames: [:])
        let items = report.candidates.filter { $0.ruleID == "general.agentScratch" }
        let byName = Dictionary(uniqueKeysWithValues: items.map { (($0.path! as NSString).lastPathComponent, $0) })
        #expect(byName["s-old"]?.risk == .review)
        #expect(byName["s-new"]?.risk == .blocked)
        #expect(byName["s-small"] == nil)
        #expect(byName["s-old"]?.title == "Claude Code 작업 폴더 · Proj")
        #expect(byName["s-old"]?.category == .aiCache)

        // Without the root in the policy nothing is offered.
        let without = try await scanner.scan(env.context(), appNames: [:])
        #expect(!without.candidates.contains { $0.ruleID == "general.agentScratch" })
    }

    @Test("Encoded project names are turned back into real folder paths")
    func decode() throws {
        let temp = try TempDirectory()
        let folder = try temp.dir("Coding/Don't Move")
        let canonical = PathUtilities.canonicalPath(folder.path)!
        let encoded = String(canonical.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        #expect(GeneralCleanupScanner.decodeAgentProjectPath(encoded) == canonical)
        #expect(GeneralCleanupScanner.agentProjectName(encoded) == "Don't Move")
        #expect(GeneralCleanupScanner.agentProjectName("-nowhere-at-all-Thing") == "Thing")
    }
}

@Suite("Projects without Git, and build output found by what it contains")
struct NonGitProjectTests {
    @Test("Folders with a project file are discovered; a stray marker directly in a home folder is ignored")
    func markerDiscovery() throws {
        let temp = try TempDirectory()
        try temp.file("home/Desktop/package.json", size: 10)
        try temp.file("home/Desktop/Coding/App/package.json", size: 10)
        try temp.file("home/Desktop/Coding/App/ios/Podfile", size: 10)
        try temp.dir("home/Desktop/Coding/Mac/Mac.xcodeproj")
        try temp.file("home/Desktop/Coding/Notes/readme.txt", size: 10)
        let found = ProjectDiscovery.find(home: temp.url.appendingPathComponent("home"))
        let names = Set(found.map { ($0 as NSString).lastPathComponent })
        #expect(names == ["App", "Mac"])
    }

    @Test("Xcode build folders of any name are REVIEW; app packages outside Git are MANUAL and go to the Trash")
    func looseOutputs() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let project = try temp.dir("home/Code/App")
        let big = 21 * 1024 * 1024
        try temp.file("home/Code/App/package.json", size: 10)
        try temp.file("home/Code/App/.app-build/ios-simulator/info.plist", size: 10)
        try temp.file("home/Code/App/.app-build/ios-simulator/Build/Products/Debug/App.app/App", size: big)
        try temp.file("home/Code/App/.app-build/ios-simulator/Build/Products/Debug/App.app/embedded.mobileprovision", size: 10)
        try temp.file("home/Code/App/artifacts/App-0.1.0.apk", size: big)
        try temp.file("home/Code/App/node_modules/x/info.plist", size: 10)
        try temp.file("home/Code/App/node_modules/x/Build/Products/a", size: big)

        let report = await ProjectAnalyzer().analyze(projectAt: project, ctx: env.context(extraRoots: [project]))
        func item(_ rel: String) -> CleanupCandidate? { report.candidates.first { $0.path?.hasSuffix("/App/" + rel) == true } }
        let build = try #require(item(".app-build/ios-simulator"))
        #expect(build.risk == .review)
        #expect(build.category == .projectBuild)
        let apk = try #require(item("artifacts/App-0.1.0.apk"))
        #expect(apk.risk == .manual)
        #expect(!apk.allowsPermanentRemoval)
        #expect(item("node_modules/x") == nil)
    }
}

@Suite("Shared temp folder (/private/tmp)")
struct SharedTempTests {
    @Test("Build folders, project copies and Git copies are named and graded; recent, small and agent items are handled")
    func sharedTemp() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let root = try temp.dir("sharedtmp")
        let old = Date().addingTimeInterval(-3 * 86_400)
        let big = 51 * 1024 * 1024
        try temp.file("sharedtmp/qa-derived/info.plist", size: 10, modified: old)
        try temp.file("sharedtmp/qa-derived/Build/Products/a.bin", size: big, modified: old)
        try temp.file("sharedtmp/app-copy/package.json", size: 10, modified: old)
        try temp.file("sharedtmp/app-copy/node_modules/a.bin", size: big, modified: old)
        try temp.file("sharedtmp/worktree/.git/HEAD", size: 10, modified: old)
        try temp.file("sharedtmp/worktree/a.bin", size: big, modified: old)
        try temp.file("sharedtmp/fresh/a.bin", size: big)
        let recent = Date().addingTimeInterval(-5 * 3600)
        try temp.file("sharedtmp/yesterday/a.bin", size: big, modified: recent)
        try temp.file("sharedtmp/emulator-home/avd/a.img", size: big, modified: old)
        try temp.file("sharedtmp/shell-cwd/a.bin", size: big, modified: old)
        try temp.file("sharedtmp/small/a.bin", size: 1024, modified: old)
        try temp.file("sharedtmp/claude-501/p/s/a.bin", size: big, modified: old)

        var scanner = GeneralCleanupScanner()
        scanner.includeLeftovers = false
        scanner.sharedTempRoot = root
        let canonicalRoot = PathUtilities.canonicalPath(root.path)!
        var processes = ProcessSnapshot()
        // An emulator started with the folder (spelled via /tmp-style path fragment) and a shell inside another.
        processes.interpreterCommandLines = ["qemu-system-aarch64 -avd test -datadir \(canonicalRoot.lowercased())/emulator-home/avd"]
        processes.workingDirectories = ["\(canonicalRoot.lowercased())/shell-cwd/sub"]
        let report = try await scanner.scan(env.context(processes: processes, extraRoots: [root]), appNames: [:])
        let items = report.candidates.filter { $0.category == .sharedTemporary }
        let byName = Dictionary(uniqueKeysWithValues: items.map { (($0.path! as NSString).lastPathComponent, $0) })

        let build = try #require(byName["qa-derived"])
        #expect(build.risk == .review)
        #expect(build.title == "Xcode 빌드 폴더 · qa-derived")
        #expect(build.allowsPermanentRemoval)
        let copy = try #require(byName["app-copy"])
        #expect(copy.risk == .review)
        #expect(!copy.allowsPermanentRemoval)
        #expect(byName["worktree"]?.risk == .manual)
        #expect(byName["fresh"]?.risk == .blocked)
        // Written hours ago and not in use: offered, with when it was last used.
        #expect(byName["yesterday"]?.risk == .review)
        #expect(byName["yesterday"]?.riskReason.contains("5시간 전") == true)
        #expect(byName["emulator-home"]?.risk == .blocked)
        #expect(byName["emulator-home"]?.title == "Android 테스트 환경 · emulator-home")
        #expect(byName["shell-cwd"]?.risk == .blocked)
        #expect(byName["shell-cwd"]?.riskReason == "실행 중인 프로세스가 이 폴더를 쓰고 있음")
        #expect(byName["small"] == nil)
        #expect(byName["claude-501"] == nil)
        #expect(!items.contains { $0.isDefaultSelected })

        // Without the root in the policy nothing is offered.
        let without = try await scanner.scan(env.context(), appNames: [:])
        #expect(!without.candidates.contains { $0.category == .sharedTemporary })
    }
}
