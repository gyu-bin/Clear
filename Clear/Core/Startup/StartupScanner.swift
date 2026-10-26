import Darwin
import Foundation

/// A launchd job that starts at login or boot.
struct StartupItem: Identifiable, Hashable, Sendable {
    enum Scope: String, Sendable, CaseIterable {
        /// ~/Library/LaunchAgents — this user's agents: can be turned off, on, or removed.
        case user
        /// /Library/LaunchAgents — agents for every user: can be turned off for this user only.
        case allUsers
        /// /Library/LaunchDaemons — system daemons: view only (needs administrator rights).
        case system

        var title: String {
            switch self {
            case .user: "내 계정"
            case .allUsers: "모든 사용자"
            case .system: "시스템"
            }
        }
    }

    var id: String { plistPath }
    let label: String
    let plistPath: String
    let program: String?
    let programExists: Bool
    let appName: String?
    let appPath: String?
    let scope: Scope
    let runAtLoad: Bool
    let keepAlive: Bool
    /// Disabled through `launchctl disable` (an override, the plist stays).
    let isDisabled: Bool
    /// Loaded in this login session (nil when unknown, e.g. system daemons).
    let isLoaded: Bool?
    let pid: Int?
    let modified: Date
    let identity: FileIdentity

    var displayName: String { appName ?? label }
    var isBroken: Bool { program != nil && !programExists }
    var canToggle: Bool { scope != .system }
    var canRemove: Bool { scope == .user }

    static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.wholeMatch(of: /[A-Za-z0-9._\-]+/) != nil
    }
}

/// Reads launchd plists and their current state. Read-only.
struct StartupScanner: Sendable {
    let home: URL
    let runner: CommandRunning

    func scan() async -> [StartupItem] {
        let uid = getuid()
        let loaded = parseList((try? await runner.run(.launchctl, ["list"], timeout: 15))?.stdout ?? "")
        let userDisabled = parseDisabled((try? await runner.run(.launchctl, ["print-disabled", "gui/\(uid)"], timeout: 15))?.stdout ?? "")
        let systemDisabled = parseDisabled((try? await runner.run(.launchctl, ["print-disabled", "system"], timeout: 15))?.stdout ?? "")

        let folders: [(String, StartupItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents").path, .user),
            ("/Library/LaunchAgents", .allUsers),
            ("/Library/LaunchDaemons", .system),
        ]
        var items: [StartupItem] = []
        for (folder, scope) in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = folder + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
                      let data = FileManager.default.contents(atPath: path),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let label = (dict["Label"] as? String) ?? (name as NSString).deletingPathExtension
                let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
                let exists = program.map { !$0.hasPrefix("/") || FileManager.default.fileExists(atPath: $0) } ?? true
                let app = program.flatMap(Self.enclosingApp)
                let disabled = scope == .system ? systemDisabled[label] : userDisabled[label]
                let job = loaded[label]
                items.append(StartupItem(
                    label: label, plistPath: path, program: program, programExists: exists,
                    appName: app?.name, appPath: app?.path, scope: scope,
                    runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                    keepAlive: (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] is [String: Any]),
                    isDisabled: disabled ?? (dict["Disabled"] as? Bool ?? false),
                    isLoaded: scope == .system ? nil : job != nil,
                    pid: job ?? nil,
                    modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                    identity: FileIdentity(stat: st)))
            }
        }
        return items
    }

    /// `launchctl list` → label: pid (nil when loaded but not running).
    func parseList(_ text: String) -> [String: Int?] {
        var result: [String: Int?] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            result[String(cols[2])] = Int(cols[0])
        }
        return result
    }

    /// `launchctl print-disabled` → label: disabled.
    func parseDisabled(_ text: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            guard let m = line.firstMatch(of: /"([^"]+)"\s*=>\s*(\w+)/) else { continue }
            result[String(m.1)] = m.2 == "disabled" || m.2 == "true"
        }
        return result
    }

    /// The .app bundle that contains `program`, if any.
    static func enclosingApp(_ program: String) -> (name: String, path: String)? {
        let comps = program.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let path = "/" + comps[...index].joined(separator: "/")
        let name = AppCatalog.read(appAt: URL(fileURLWithPath: path))?.name ?? String(comps[index].dropLast(4))
        return (name, path)
    }
}
