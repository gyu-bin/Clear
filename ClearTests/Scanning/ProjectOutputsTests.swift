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
