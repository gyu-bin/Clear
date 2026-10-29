import Foundation
import Testing
@testable import Clear

@Suite("Developer tool adapters")
struct DeveloperAdapterTests {
    let temp: TempDirectory
    let env: FakeEnvironment
    init() throws { temp = try TempDirectory(); env = try FakeEnvironment(temp) }

    @Test("Xcode DerivedData is SAFE, blocked from pre-selection while Xcode runs")
    func xcodeDerivedData() async throws {
        try temp.file("home/Library/Developer/Xcode/DerivedData/MyApp-abcdef/Build/obj.o", size: 2 * 1024 * 1024)
        try temp.file("home/Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/x", size: 4096)
        let idle = await XcodeAdapter().scan(env.context())
        let dd = try #require(idle.candidates.first { $0.ruleID == "dev.xcode.derivedData" })
        #expect(dd.risk == .safe && dd.isDefaultSelected && dd.title.hasPrefix("MyApp"))
        #expect(!idle.candidates.contains { $0.path?.contains("/Archives") == true }, "Archives are never candidates")
        #expect(idle.locations.contains { $0.title == "Xcode 아카이브" && $0.isProtected })

        let busy = await XcodeAdapter().scan(env.context(processes: ProcessSnapshot(bundleIdentifiers: ["com.apple.dt.Xcode"])))
        let busyDD = try #require(busy.candidates.first { $0.ruleID == "dev.xcode.derivedData" })
        #expect(!busyDD.isDefaultSelected)
        let validator = CleanupValidator(policy: env.policy(), fileSystem: LocalFileSystem(), commandRunner: MockCommandRunner())
        #expect(validator.validate(busyDD, processes: ProcessSnapshot(bundleIdentifiers: ["com.apple.dt.Xcode"])).rejectionReason != nil)
    }

    @Test("Simulators are offered only as simctl commands with validated UDIDs")
    func simulators() async throws {
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[
          {"udid":"0A1B2C3D-0000-1111-2222-333344445555","name":"Old iPhone","state":"Shutdown","isAvailable":false},
          {"udid":"not-a-uuid; rm -rf /","name":"Evil","state":"Shutdown","isAvailable":false}]}}
        """
        let runner = MockCommandRunner(available: [.xcrun]) { _, args in
            args.starts(with: ["simctl", "list"]) ? CommandResult(exitCode: 0, stdout: json, stderr: "") : CommandResult(exitCode: 1, stdout: "", stderr: "")
        }
        try temp.dir("home/Library/Developer/Xcode")
        let report = await XcodeAdapter().scan(env.context(runner: runner))
        let cmd = try #require(report.candidates.first { $0.id == "simctl:delete-unavailable" })
        #expect(cmd.risk == .review)
        if case .command(let c) = cmd.target { #expect(c.arguments == ["simctl", "delete", "unavailable"]) }
        #expect(cmd.size.fileCount == 1, "the malformed UDID is ignored")
    }

    @Test("Gradle: the caches root is protected, only version-scoped folders are offered")
    func gradle() async throws {
        try temp.file("home/.gradle/caches/modules-2/files/x.jar", size: 4096)
        try temp.file("home/.gradle/caches/7.6/old/x", size: 11 * 1024 * 1024)
        try temp.file("home/.gradle/wrapper/dists/gradle-8.7-bin/abc/gradle.zip", size: 11 * 1024 * 1024)
        let report = await GradleAdapter().scan(env.context())
        #expect(report.candidates.contains { $0.ruleID == "dev.gradle.versionCache" && $0.path?.hasSuffix("/7.6") == true })
        #expect(!report.candidates.contains { $0.path?.hasSuffix("/modules-2") == true || $0.path?.hasSuffix("/caches") == true })
        #expect(GradleAdapter.version(fromDistribution: "gradle-8.7-bin") == "8.7")
        #expect(GradleAdapter.version(fromDistribution: "gradle-8.10-rc-1-all") == "8.10-rc-1")
    }

    @Test("Gradle versions and NDKs that no project uses are offered; used ones are kept")
    func gradleProjectUsage() async throws {
        let big = 11 * 1024 * 1024
        try temp.file("home/.gradle/caches/9.3.1/x", size: big)
        try temp.file("home/.gradle/caches/9.4.1/x", size: big)
        try temp.file("home/.gradle/wrapper/dists/gradle-9.3.1-bin/abc/gradle.zip", size: big)
        try temp.file("home/.gradle/wrapper/dists/gradle-9.4.1-bin/abc/gradle.zip", size: big)
        try temp.file("home/Library/Android/sdk/ndk/27.0.12077973/x", size: big)
        try temp.file("home/Library/Android/sdk/ndk/27.1.12297006/x", size: big)
        let project = try temp.dir("home/Code/App")
        try temp.file("home/Code/App/android/gradle/wrapper/gradle-wrapper.properties",
                      data: Data("distributionUrl=https\\://services.gradle.org/distributions/gradle-9.4.1-bin.zip\n".utf8))
        try temp.file("home/Code/App/node_modules/react-native/gradle/libs.versions.toml",
                      data: Data("[versions]\nndkVersion = \"27.1.12297006\"\n".utf8))

        let usage = GradleAdapter.projectUsage([project.path])
        #expect(usage.gradle == ["9.4.1"])
        #expect(usage.ndk == ["27.1.12297006"])

        let report = await GradleAdapter(projectFolders: [project.path]).scan(env.context())
        func item(_ suffix: String) -> CleanupCandidate? { report.candidates.first { $0.path?.hasSuffix(suffix) == true } }
        #expect(item("/caches/9.3.1")?.risk == .review)
        #expect(item("/caches/9.4.1") == nil)
        #expect(item("/gradle-9.3.1-bin")?.riskReason == "어느 프로젝트도 쓰지 않는 Gradle 버전")
        #expect(item("/ndk/27.0.12077973")?.risk == .review)
        #expect(item("/ndk/27.1.12297006") == nil)

        // Without known projects, nothing about NDKs is guessed.
        let unknown = await GradleAdapter().scan(env.context())
        #expect(!unknown.candidates.contains { $0.ruleID == "dev.android.ndk" })
    }

    @Test("npm cache is SAFE and guarded by npm processes")
    func npm() async throws {
        try temp.file("home/.npm/_cacache/content-v2/sha512/x", size: 600_000)
        let report = await NodeAdapter().scan(env.context())
        let cache = try #require(report.candidates.first { $0.path?.hasSuffix("/_cacache") == true })
        #expect(cache.risk == .safe)
        #expect(cache.guards.contains { $0.kind == .commandLine && $0.value == "npm-cli.js" })
    }

    @Test("Homebrew dry-run output is parsed into a single command candidate")
    func homebrewParse() {
        let out = """
        Would remove: /opt/homebrew/Cellar/node/20.1.0 (2,345 files, 60.2MB)
        Would remove: /Users/me/Library/Caches/Homebrew/downloads/abc--x.bottle.tar.gz (1.5MB)
        ==> This operation would free approximately 61.7MB of disk space.
        """
        let dry = HomebrewAdapter.parseDryRun(out)
        #expect(dry.items.count == 2)
        #expect(dry.items[0].path == "/opt/homebrew/Cellar/node/20.1.0")
        #expect(abs(Double(dry.total) - 61.7 * 1_048_576) < 1024)
    }

    @Test("Docker `system df` JSON lines are parsed; volumes are never offered")
    func docker() {
        let rows = DockerAdapter.parse("""
        {"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"300MB (100%)","Size":"300MB","TotalCount":"3","Type":"Local Volumes"}
        not json
        """)
        #expect(rows.count == 2)
        #expect(rows[0].type == "Images")
        #expect(HumanSizeParser.bytes(from: rows[0].size, binary: false) == 2_400_000_000)
        #expect(HumanSizeParser.bytes(from: "512kB", binary: false) == 512_000)
        #expect(HumanSizeParser.bytes(from: "0B", binary: false) == 0)
        #expect(HumanSizeParser.bytes(from: "garbage", binary: false) == nil)
    }
}

@Suite("ProjectAnalyzer — registered development projects")
struct ProjectAnalyzerTests {
    let temp: TempDirectory
    let env: FakeEnvironment
    let project: URL

    init() throws {
        temp = try TempDirectory()
        env = try FakeEnvironment(temp)
        project = try temp.dir("home/Code/App")
        try temp.file("home/Code/App/package.json", data: Data(#"{"dependencies":{"expo":"~51.0.0","react-native":"0.74.0"}}"#.utf8))
        try temp.file("home/Code/App/package-lock.json", size: 100)
        try temp.file("home/Code/App/App.tsx", size: 5000)
        try temp.file("home/Code/App/.env", size: 50)
        try temp.dir("home/Code/App/.git")
        try temp.file("home/Code/App/node_modules/react/index.js", size: 300_000)
        try temp.file("home/Code/App/android/app/build/outputs/app.apk", size: 400_000)
        try temp.file("home/Code/App/android/build/tmp/x", size: 1000)
        try temp.file("home/Code/App/android/build/signing/release.keystore", size: 100)
        try temp.file("home/Code/App/.expo/devices.json", size: 100)
        try temp.file("home/Code/App/ios/Podfile", size: 10)
        try temp.file("home/Code/App/ios/Pods/Lib/a.m", size: 1000)
    }

    func analyze(tracked: Set<String> = []) async -> ProjectReport {
        let runner = MockCommandRunner(available: [.git]) { tool, args in
            guard tool == .git, let rel = args.last else { return CommandResult(exitCode: 1, stdout: "", stderr: "") }
            return CommandResult(exitCode: 0, stdout: tracked.contains(rel) ? "\(rel)/file\0" : "", stderr: "")
        }
        return await ProjectAnalyzer().analyze(projectAt: project, ctx: env.context(runner: runner, extraRoots: [project]))
    }

    func item(_ r: ProjectReport, _ rel: String) -> CleanupCandidate? { r.candidates.first { $0.path?.hasSuffix("/App/" + rel) == true } }

    @Test("Detects project kinds and package manager")
    func detection() async {
        let r = await analyze()
        #expect(r.kinds.contains("Expo") && r.kinds.contains("React Native"))
        #expect(r.packageManager == "npm")
        #expect(r.isGitRepository)
    }

    @Test("Build outputs are REVIEW, dependencies are MANUAL, source is never a candidate")
    func classification() async {
        let r = await analyze()
        #expect(item(r, "android/app/build")?.risk == .review)
        #expect(item(r, "node_modules")?.risk == .manual)
        #expect(item(r, "ios/Pods")?.risk == .manual)
        #expect(item(r, ".expo")?.risk == .review)
        #expect(!r.candidates.contains { $0.path?.hasSuffix("App.tsx") == true || $0.path?.hasSuffix(".env") == true || $0.path?.contains(".git") == true })
        #expect(r.dependencies > 0 && r.build > 0)
        #expect(r.source > 0)
    }

    @Test("A build folder containing a signing key is BLOCKED")
    func secrets() async {
        #expect(item(await analyze(), "android/build")?.risk == .blocked)
        #expect(ProjectAnalyzer.isSensitive(".env.production"))
        #expect(ProjectAnalyzer.isSensitive("AuthKey.p8"))
        #expect(!ProjectAnalyzer.isSensitive("index.js"))
    }

    @Test("Anything tracked by Git is BLOCKED — .gitignore is not proof of safety")
    func gitTracked() async {
        #expect(item(await analyze(tracked: ["android/app/build"]), "android/app/build")?.risk == .blocked)
    }

    @Test("node_modules without a lockfile cannot be reproduced and is BLOCKED")
    func noLockfile() async throws {
        try FileManager.default.removeItem(at: project.appendingPathComponent("package-lock.json"))
        #expect(item(await analyze(), "node_modules")?.risk == .blocked)
    }
}

@Suite("AI tool adapters")
struct AIToolAdapterTests {
    let temp: TempDirectory
    let env: FakeEnvironment
    init() throws { temp = try TempDirectory(); env = try FakeEnvironment(temp) }

    @Test("Claude Code: logs are cleanable, history and settings are protected")
    func claudeCode() async throws {
        try temp.file("home/Library/Caches/claude-cli-nodejs/-Users-me/mcp.log", size: 600_000)
        try temp.file("home/.claude/projects/p/session.jsonl", size: 600_000)
        try temp.file("home/.claude/settings.json", size: 100)
        let report = await AIToolAdapters.claudeCode.scan(env.context())
        #expect(report.installed)
        #expect(report.candidates.contains { $0.path?.hasSuffix("/claude-cli-nodejs") == true && $0.risk == .safe })
        #expect(!report.candidates.contains { $0.path?.contains("/.claude/projects") == true })
        #expect(report.locations.contains { $0.isProtected && $0.title == "프로젝트 대화 기록" })
    }

    @Test("Claude Code caches are not pre-selected while `claude` runs")
    func running() async throws {
        try temp.file("home/Library/Caches/claude-cli-nodejs/x/mcp.log", size: 600_000)
        try temp.dir("home/.claude")
        let report = await AIToolAdapters.claudeCode.scan(env.context(processes: ProcessSnapshot(executableNames: ["claude"])))
        #expect(report.candidates.allSatisfy { !$0.isDefaultSelected })
        #expect(report.runningProcesses == ["Claude Code"])
    }

    @Test("Local models are MANUAL and trash-only, never treated as cache")
    func models() async throws {
        try temp.file("home/.cache/huggingface/hub/models--org--tiny/blobs/w.safetensors", size: 11 * 1024 * 1024)
        let report = await AIToolAdapters.huggingFace.scan(env.context())
        let model = try #require(report.candidates.first { $0.category == .aiModels })
        #expect(model.risk == .manual && !model.allowsPermanentRemoval && model.title == "org/tiny")
    }

    @Test("Tools that are not installed report so and propose nothing")
    func notInstalled() async {
        let report = await AIToolAdapters.gemini.scan(env.context())
        #expect(!report.installed && report.candidates.isEmpty)
    }
}
