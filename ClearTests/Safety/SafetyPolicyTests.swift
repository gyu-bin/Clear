import Foundation
import Testing
@testable import Clear

@Suite("SafetyPolicy — protected locations and allowed roots")
struct SafetyPolicyTests {
    let home = "/mock/home"
    var policy: SafetyPolicy { SafetyPolicy(home: URL(fileURLWithPath: home), temporaryDirectory: URL(fileURLWithPath: "/mock/tmp")) }

    @Test("System, home and Library roots are never removable")
    func protectsRoots() {
        for path in ["/", "/System/Library", "/usr/bin", "/Applications", "/Library", home, home + "/Library",
                     home + "/Library/Caches", home + "/Documents", home + "/Downloads"] {
            #expect(policy.protectionReason(for: path) != nil, "\(path) must be protected")
        }
    }

    @Test("Children of a cache root are not protected, but sensitive subtrees are")
    func childrenVsSubtrees() {
        #expect(policy.protectionReason(for: home + "/Library/Caches/com.example.app") == nil)
        #expect(policy.protectionReason(for: home + "/Library/Keychains/login.keychain-db") != nil)
        #expect(policy.protectionReason(for: home + "/.ssh/id_ed25519") != nil)
        #expect(policy.protectionReason(for: home + "/Library/Mobile Documents/com~apple~CloudDocs/a.txt") != nil)
        #expect(policy.protectionReason(for: home + "/.claude/projects/x/session.jsonl") != nil)
        #expect(policy.protectionReason(for: home + "/.codex/auth.json") != nil)
        #expect(policy.protectionReason(for: home + "/Library/Application Support/Cursor/User/globalStorage") != nil)
        #expect(policy.protectionReason(for: home + "/Library/Application Support/Cursor/Cache") == nil)
    }

    @Test("Removing an ancestor of a protected location is refused")
    func protectsAncestors() {
        // Application Support contains MobileSync (protected) and is protected itself.
        #expect(policy.protectionReason(for: home + "/Library/Application Support") != nil)
        // Xcode/UserData contains protected snippets/themes.
        #expect(policy.protectionReason(for: home + "/Library/Developer/Xcode/UserData") != nil)
        #expect(policy.protectionReason(for: home + "/Library/Developer/Xcode/UserData/Previews") == nil)
    }

    @Test("Protected path components are matched anywhere", arguments: [
        "/mock/home/Projects/app/.git/objects",
        "/mock/home/Pictures/Photos Library.photoslibrary/originals/a.heic",
        "/Volumes/Backup/Backups.backupdb/Mac/Latest",
        "/mock/home/Library/Caches/x/login.keychain",
    ])
    func protectsComponents(path: String) {
        #expect(policy.protectionReason(for: path) != nil)
    }

    @Test("User exclusions protect the folder, its contents and its ancestors")
    func exclusions() {
        let p = SafetyPolicy(home: URL(fileURLWithPath: home), temporaryDirectory: URL(fileURLWithPath: "/mock/tmp"),
                             exclusions: [home + "/Library/Caches/keep"])
        #expect(p.protectionReason(for: home + "/Library/Caches/keep") != nil)
        #expect(p.protectionReason(for: home + "/Library/Caches/keep/inner") != nil)
        #expect(p.protectionReason(for: home + "/Library/Caches/keeper") == nil)
    }

    @Test("Descendant checks compare whole components, not string prefixes")
    func componentComparison() {
        #expect(PathUtilities.isStrictDescendant("/a/b/c", of: "/a/b"))
        #expect(!PathUtilities.isStrictDescendant("/a/bc", of: "/a/b"))
        #expect(!PathUtilities.isStrictDescendant("/a/b", of: "/a/b"))
        #expect(PathUtilities.isSameOrDescendant("/a/b", of: "/a/b"))
        #expect(!PathUtilities.isWellFormedAbsolutePath("relative/path"))
        #expect(!PathUtilities.isWellFormedAbsolutePath("/a/../etc"))
        #expect(!PathUtilities.isWellFormedAbsolutePath("/a/./b"))
        #expect(!PathUtilities.isWellFormedAbsolutePath("/"))
    }

    @Test("The most specific allowed root wins")
    func allowedRoot() {
        #expect(policy.allowedRoot(containing: home + "/Library/Caches/foo") == home + "/Library/Caches")
        #expect(policy.allowedRoot(containing: home + "/Library/Developer/Xcode/DerivedData/x") == home + "/Library/Developer")
        #expect(policy.allowedRoot(containing: home + "/Documents/report.pdf") == nil)
        #expect(policy.allowedRoot(containing: home + "/Library/Caches") == nil, "a root itself is not inside a root")
    }

    @Test("Registered project and duplicate folders become allowed roots")
    func dynamicRoots() {
        var p = policy
        p.addAllowedRoots([URL(fileURLWithPath: home + "/Code/App")])
        #expect(p.allowedRoot(containing: home + "/Code/App/android/build") == home + "/Code/App")
    }
}

@Suite("ProcessSnapshot guards")
struct ProcessGuardTests {
    @Test func matching() {
        let snap = ProcessSnapshot(executableNames: ["xcodebuild", "claude"], bundleIdentifiers: ["com.apple.dt.Xcode"],
                                   interpreterCommandLines: ["node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js install"])
        #expect(snap.isRunning(.app("com.apple.dt.Xcode", "Xcode")))
        #expect(!snap.isRunning(.app("com.figma.Desktop", "Figma")))
        #expect(snap.isRunning(.process("XcodeBuild")), "process names are case-insensitive")
        #expect(snap.isRunning(.commandLine("npm-cli.js", "npm")))
        #expect(!snap.isRunning(.commandLine("yarn", "Yarn")))
        #expect(snap.runningGuards(DeveloperGuards.xcode) == ["Xcode", "xcodebuild"])
    }
}
