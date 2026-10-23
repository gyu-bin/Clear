import Foundation
import Testing
@testable import Clear

@Suite("AppInventory — app leftovers by bundle identifier")
struct AppInventoryTests {
    let temp: TempDirectory
    let env: FakeEnvironment
    let app: InstalledApp

    init() throws {
        temp = try TempDirectory()
        env = try FakeEnvironment(temp)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.foo", "CFBundleName": "Foo", "CFBundleShortVersionString": "1.2"]
        try temp.file("Applications/Foo.app/Contents/Info.plist",
                      data: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        try temp.file("home/Library/Caches/com.example.foo/c", size: 1000)
        try temp.file("home/Library/Preferences/com.example.foo.plist", size: 100)
        try temp.file("home/Library/Application Support/Foo/doc.db", size: 100)
        try temp.file("home/Library/Application Support/FooBar/x", size: 100)
        try temp.file("home/Library/Caches/com.example.foobar/x", size: 100)
        let info = try #require(AppCatalog.read(appAt: temp.url.appendingPathComponent("Applications/Foo.app")))
        app = InstalledApp(info: info, size: nil, lastUsed: nil, isAppStore: false, uninstallBlockReason: nil)
    }

    @Test("Reads Info.plist metadata")
    func metadata() {
        #expect(app.info.name == "Foo" && app.info.bundleIdentifier == "com.example.foo" && app.info.version == "1.2")
    }

    @Test("Exact bundle-ID matches are linked; similar names are not")
    func related() {
        let ctx = env.context(extraRoots: [temp.url.appendingPathComponent("Applications")])
        let files = AppInventory(home: env.home).relatedFiles(for: app, ctx: ctx)
        let paths = files.compactMap(\.path)
        #expect(paths.contains { $0.hasSuffix("/Caches/com.example.foo") })
        #expect(paths.contains { $0.hasSuffix("/Preferences/com.example.foo.plist") })
        #expect(!paths.contains { $0.contains("foobar") || $0.contains("FooBar") })
        #expect(files.first { $0.path?.hasSuffix("/Caches/com.example.foo") == true }?.risk == .safe)
        #expect(files.first { $0.path?.hasSuffix("/Preferences/com.example.foo.plist") == true }?.isDefaultSelected == false)
        let byName = files.first { $0.path?.hasSuffix("/Application Support/Foo") == true }
        #expect(byName?.risk == .manual, "name-only matches need an explicit choice")
        #expect(files.allSatisfy { !$0.allowsPermanentRemoval && $0.preferredMethod == .trash })
    }

    @Test("The app bundle itself is MANUAL and guarded by its bundle ID")
    func bundle() throws {
        let ctx = env.context(extraRoots: [temp.url.appendingPathComponent("Applications")])
        let c = try #require(AppInventory(home: env.home).bundleCandidate(for: app, ctx: ctx))
        #expect(c.risk == .manual)
        #expect(c.guards.contains(.app("com.example.foo", "Foo")))
    }

    @Test("Apple apps cannot be uninstalled")
    func appleApps() {
        let info = AppBundleInfo(path: "/Applications/Safari.app", name: "Safari", bundleIdentifier: "com.apple.Safari",
                                 version: nil, executableName: nil, isAppleApp: true)
        #expect(AppInventory.blockReason(for: info) != nil)
    }
}

@Suite("Settings persistence")
struct SettingsTests {
    @Test("Old or partial settings decode with defaults instead of being discarded")
    func tolerantDecoding() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"dark","preferTrash":false,"unknownKey":1}"#.utf8))
        #expect(s.theme == .dark)
        #expect(s.preferTrash == false)
        #expect(s.autoScanEnabled == false, "auto scan stays off by default")
        #expect(s.lowStorageAlertEnabled == false)
        #expect(s.developerModeEnabled)
    }
}
