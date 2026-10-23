import Darwin
import Foundation
import Testing
@testable import Clear

@Suite("GeneralCleanupScanner — classification on a fake home folder")
struct GeneralCleanupScannerTests {
    let temp: TempDirectory
    let env: FakeEnvironment

    init() throws {
        temp = try TempDirectory()
        env = try FakeEnvironment(temp)
        let mb = 1024 * 1024 + 512
        try temp.file("home/Library/Caches/com.spotify.client/data", size: mb)
        try temp.file("home/Library/Caches/CloudKit/db", size: mb)
        try temp.file("home/Library/Caches/com.apple.Something/c", size: mb)
        try temp.file("home/Library/Caches/com.unknown.app/c", size: mb)
        try temp.file("home/Library/Caches/Homebrew/downloads/x", size: mb)
        try temp.file("home/Library/Caches/tiny.app/c", size: 10)
        try temp.file("home/Library/Logs/OldApp/old.log", size: 300_000, modified: .daysAgo(30))
        try temp.file("home/Library/Logs/FreshApp/now.log", size: 300_000)
        try temp.file("home/Downloads/installer.dmg", size: 50_000, modified: .daysAgo(60))
        try temp.file("home/Downloads/notes.txt", size: 50_000, modified: .daysAgo(60))
        try temp.dir("home/.Trash")
    }

    func scan(processes: ProcessSnapshot = .empty) async throws -> GeneralScanReport {
        var scanner = GeneralCleanupScanner()
        scanner.downloadsInstallerMinimum = 1024
        return try await scanner.scan(env.context(processes: processes), appNames: ["com.unknown.app": "Unknown"])
    }

    func find(_ report: GeneralScanReport, _ suffix: String) -> CleanupCandidate? {
        report.candidates.first { $0.path?.hasSuffix(suffix) == true }
    }

    @Test("Known regenerable caches are SAFE and pre-selected")
    func safe() async throws {
        let c = try #require(find(try await scan(), "/com.spotify.client"))
        #expect(c.risk == .safe && c.isDefaultSelected)
    }

    @Test("Account and sync caches are BLOCKED")
    func blocked() async throws {
        #expect(find(try await scan(), "/CloudKit")?.risk == .blocked)
    }

    @Test("Unknown and Apple caches need review — Caches is not blanket-safe")
    func review() async throws {
        let report = try await scan()
        #expect(find(report, "/com.unknown.app")?.risk == .review)
        #expect(find(report, "/com.unknown.app")?.title == "Unknown")
        #expect(find(report, "/com.apple.Something")?.category == .systemCache)
        #expect(find(report, "/com.apple.Something")?.isDefaultSelected == false)
    }

    @Test("Developer-owned caches are left to their adapters (no double counting)")
    func ownedSkipped() async throws {
        #expect(find(try await scan(), "/Homebrew") == nil)
    }

    @Test("Tiny caches are not proposed")
    func minimumSize() async throws {
        #expect(find(try await scan(), "/tiny.app") == nil)
    }

    @Test("Old logs are SAFE, logs still being written need review")
    func logs() async throws {
        let report = try await scan()
        #expect(find(report, "/OldApp")?.risk == .safe)
        #expect(find(report, "/FreshApp")?.risk == .review)
    }

    @Test("Downloads: old installers are MANUAL and trash-only; ordinary files are not proposed")
    func downloads() async throws {
        let report = try await scan()
        let dmg = try #require(find(report, "/installer.dmg"))
        #expect(dmg.risk == .manual && !dmg.allowsPermanentRemoval && dmg.preferredMethod == .trash)
        #expect(find(report, "/notes.txt") == nil)
    }

    @Test("A running app's cache is not pre-selected")
    func runningApp() async throws {
        let c = try #require(find(try await scan(processes: ProcessSnapshot(bundleIdentifiers: ["com.spotify.client"])), "/com.spotify.client"))
        #expect(!c.runningGuards.isEmpty)
        #expect(!c.isDefaultSelected)
    }

    @Test("An unreadable Downloads folder is reported as restricted")
    func restricted() async throws {
        chmod(temp.path + "/home/Downloads", 0o000)
        let report = try await scan()
        #expect(report.restrictedLocations.contains { $0.hasSuffix("/Downloads") })
    }

    @Test("The scan never modifies anything")
    func readOnly() async throws {
        _ = try await scan()
        #expect(temp.exists("home/Library/Caches/com.spotify.client/data"))
        #expect(temp.exists("home/Downloads/installer.dmg"))
    }
}
