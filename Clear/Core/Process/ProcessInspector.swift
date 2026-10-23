import AppKit
import Darwin
import Foundation

/// Point-in-time view of what is running, used by the safety guards.
struct ProcessSnapshot: Sendable, Equatable {
    /// Lowercased executable names (`p_comm` and the last path component).
    var executableNames: Set<String> = []
    /// Bundle identifiers of running GUI applications.
    var bundleIdentifiers: Set<String> = []
    /// Argument vectors of interpreter processes (node, java, ruby, python), lowercased.
    var interpreterCommandLines: [String] = []
    var takenAt = Date()

    static let empty = ProcessSnapshot()

    /// Display names of guards that are currently running.
    func runningGuards(_ guards: [ProcessGuard]) -> [String] {
        var result: [String] = []
        for g in guards where isRunning(g) && !result.contains(g.displayName) {
            result.append(g.displayName)
        }
        return result
    }

    func isRunning(_ g: ProcessGuard) -> Bool {
        switch g.kind {
        case .bundleID: bundleIdentifiers.contains(g.value)
        case .processName: executableNames.contains(g.value.lowercased())
        case .commandLine: interpreterCommandLines.contains { $0.contains(g.value.lowercased()) }
        }
    }
}

protocol ProcessInspecting: Sendable {
    func snapshot() async -> ProcessSnapshot
}

/// Reads the process table with libproc and `sysctl(KERN_PROCARGS2)`. Only the
/// current user's processes expose their arguments, which is all we need.
struct ProcessInspector: ProcessInspecting {
    private static let interpreters: Set<String> = ["node", "java", "ruby", "python", "python3", "bun", "deno"]

    func snapshot() async -> ProcessSnapshot {
        var snap = Self.readProcessTable()
        snap.bundleIdentifiers = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        return snap
    }

    static func readProcessTable() -> ProcessSnapshot {
        var snap = ProcessSnapshot()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return snap }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return snap }

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var exeName: String?
            if proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                exeName = String.fromCBuffer(nameBuffer).lowercased()
                snap.executableNames.insert(exeName!)
            }
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                let last = (String.fromCBuffer(pathBuffer) as NSString).lastPathComponent.lowercased()
                snap.executableNames.insert(last)
                exeName = exeName ?? last
            }
            if let exe = exeName, interpreters.contains(exe), let args = arguments(of: pid) {
                snap.interpreterCommandLines.append(args.joined(separator: " ").lowercased())
            }
        }
        snap.takenAt = Date()
        return snap
    }

    /// Argument vector via KERN_PROCARGS2. Returns nil for other users' processes.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip executable path and padding NULs.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                if index > start, let s = String(bytes: buffer[start..<index], encoding: .utf8) { args.append(s) }
                start = index + 1
            }
            index += 1
        }
        return args
    }
}

/// Fixed snapshot for tests.
struct StaticProcessInspector: ProcessInspecting {
    var value: ProcessSnapshot
    func snapshot() async -> ProcessSnapshot { value }
}

extension String {
    /// Decodes a NUL-terminated C buffer.
    static func fromCBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
