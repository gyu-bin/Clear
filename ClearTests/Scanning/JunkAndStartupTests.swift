import Foundation
import Testing
@testable import Clear

@Suite("Junk categories — browsers, screenshots, mail attachments")
struct JunkCategoryTests {
    @Test("Screenshot names in Korean and English are recognised; other files are not")
    func screenshots() {
        #expect(ScreenshotLocator.isScreenshot("스크린샷 2026-10-26 오후 3.12.45.png"))
        #expect(ScreenshotLocator.isScreenshot("Screenshot 2026-10-26 at 15.12.45.png"))
        #expect(ScreenshotLocator.isScreenshot("화면 기록 2026-10-26 오후 3.00.00.mov"))
        #expect(!ScreenshotLocator.isScreenshot("스크린샷 메모.txt"))
        #expect(!ScreenshotLocator.isScreenshot("vacation.png"))
    }

    @Test("Browser caches are their own SAFE category; Mail attachment copies are allowed but Mail data stays protected")
    func browsersAndMail() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let mb = 1024 * 1024 + 512
        try temp.file("home/Library/Caches/com.brave.Browser/Cache/data", size: mb)
        try temp.file("home/Library/Caches/com.apple.Safari/WebKitCache/x", size: mb)
        try temp.file("home/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A1/report.pdf", size: mb)
        try temp.file("home/Library/Containers/com.apple.mail/Data/Library/Mail/V10/msg", size: mb)
        var scanner = GeneralCleanupScanner()
        scanner.includeContainers = true
        let report = try await scanner.scan(env.context(), appNames: [:])

        let browsers = report.candidates.filter { $0.category == .browserCache }
        #expect(Set(browsers.map(\.title)) == ["Brave 캐시", "Safari 캐시"])
        #expect(browsers.allSatisfy { $0.risk == .safe })

        let mail = try #require(report.candidates.first { $0.category == .mailAttachments })
        #expect(mail.risk == .review)
        let policy = env.policy()
        #expect(policy.protectionReason(for: mail.path!) == nil)
        #expect(policy.protectionReason(for: env.home.path + "/Library/Containers/com.apple.mail/Data/Library/Mail/V10") != nil)
    }
}

@Suite("Sandboxed app caches")
struct ContainerCacheTests {
    @Test("Container and group-container caches are found only with Full Disk Access; app data and Mail stay out")
    func containerCaches() async throws {
        let temp = try TempDirectory()
        let env = try FakeEnvironment(temp)
        let mb = 2 * 1024 * 1024
        try temp.file("home/Library/Containers/com.example.Notes/Data/Library/Caches/img/a", size: mb)
        try temp.file("home/Library/Containers/com.example.Notes/Data/Documents/note.txt", size: mb)
        try temp.file("home/Library/Containers/com.example.Tiny/Data/Library/Caches/x", size: 1024)
        try temp.file("home/Library/Containers/com.apple.mail/Data/Library/Caches/m", size: mb)
        try temp.file("home/Library/Group Containers/ABCDE.com.example.shared/Library/Caches/s", size: mb)

        var scanner = GeneralCleanupScanner()
        let without = try await scanner.scan(env.context(), appNames: [:])
        #expect(!without.candidates.contains { $0.id.hasPrefix("container-cache:") || $0.id.hasPrefix("group-cache:") })

        scanner.includeContainers = true
        let report = try await scanner.scan(env.context(), appNames: ["com.example.Notes": "Notes Pro"])
        let notes = try #require(report.candidates.first { $0.id == "container-cache:com.example.Notes" })
        #expect(notes.title == "Notes Pro 캐시")
        #expect(notes.risk == .review)
        #expect(notes.path?.hasSuffix("/Data/Library/Caches") == true)
        let group = try #require(report.candidates.first { $0.id == "group-cache:ABCDE.com.example.shared" })
        #expect(group.title == "shared 공유 캐시")
        #expect(GeneralCleanupScanner.readableName("com.apple.mediaanalysisd") == "mediaanalysisd")
        // Under 1 MB is ignored; Mail's container is protected.
        #expect(!report.candidates.contains { $0.id == "container-cache:com.example.Tiny" })
        let mail = report.candidates.first { $0.id == "container-cache:com.apple.mail" }
        #expect(mail == nil || mail?.risk == .blocked)
        // Nothing outside a Caches folder is ever offered.
        #expect(!report.candidates.contains { $0.path?.contains("/Data/Documents") == true })
    }
}

@Suite("Startup items — launchctl output parsing")
struct StartupParsingTests {
    let scanner = StartupScanner(home: URL(fileURLWithPath: "/tmp"), runner: MockCommandRunner())

    @Test("launchctl list gives running and loaded jobs")
    func list() {
        let parsed = scanner.parseList("PID\tStatus\tLabel\n-\t0\tcom.a.idle\n7433\t-9\tcom.b.running\n")
        #expect(parsed["com.a.idle"] == .some(nil))
        #expect(parsed["com.b.running"] == .some(7433))
        #expect(parsed["com.c.absent"] == nil)
    }

    @Test("print-disabled is parsed for both 'disabled' and 'true' spellings")
    func disabled() {
        let text = """
        disabled services = {
            "com.x.on" => enabled
            "com.x.off" => disabled
            "com.x.legacy" => true
        }
        """
        let parsed = scanner.parseDisabled(text)
        #expect(parsed == ["com.x.on": false, "com.x.off": true, "com.x.legacy": true])
    }

    @Test("Labels used in launchctl arguments are validated")
    func labels() {
        #expect(StartupItem.isValidLabel("com.google.keystone.agent"))
        #expect(!StartupItem.isValidLabel("bad label; rm -rf"))
        #expect(!StartupItem.isValidLabel(""))
    }

    @Test("The owning app is found from the program path")
    func owningApp() {
        #expect(StartupScanner.enclosingApp("/Applications/Zoom.us.app/Contents/MacOS/zoom")?.path == "/Applications/Zoom.us.app")
        #expect(StartupScanner.enclosingApp("/usr/local/bin/tool") == nil)
    }
}
