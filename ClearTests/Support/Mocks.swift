import Foundation
@testable import Clear

/// Command runner that never executes anything; answers come from `handler`.
struct MockCommandRunner: CommandRunning {
    var available: Set<TrustedTool> = []
    var handler: @Sendable (TrustedTool, [String]) -> CommandResult = { _, _ in
        CommandResult(exitCode: 1, stdout: "", stderr: "mock: not available")
    }

    func locate(_ tool: TrustedTool) -> URL? {
        available.contains(tool) ? URL(fileURLWithPath: "/usr/bin/true") : nil
    }

    func run(_ tool: TrustedTool, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        handler(tool, arguments)
    }
}

/// Cancels the calling task the first time it is asked for a snapshot. Lets the
/// executor tests cancel deterministically right after the first validation.
struct CancellingProcessInspector: ProcessInspecting {
    func snapshot() async -> ProcessSnapshot {
        withUnsafeCurrentTask { $0?.cancel() }
        return .empty
    }
}

/// In-memory file system: records every mutating call and can inject failures.
/// Used to prove the executor only touches what it was told to touch.
final class MockFileSystem: FileSystemOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: FileIdentity] = [:]
    private var failures: [String: FileSystemError] = [:]
    private var unwritable: Set<String> = []
    private var log: [String] = []
    private var nextInode: UInt64 = 100

    var operations: [String] { lock.withLock { log } }

    @discardableResult
    func add(_ path: String, kind: FileIdentity.Kind = .directory, size: Int64 = 4096, device: Int32 = 1,
             owner: UInt32 = getuid(), mtime: TimeInterval = 1_000) -> FileIdentity {
        lock.withLock {
            nextInode += 1
            let id = FileIdentity(device: device, inode: nextInode, kind: kind, modificationTime: mtime, ownerUID: owner,
                                  linkCount: 1, logicalSize: size, allocatedSize: size)
            nodes[path] = id
            return id
        }
    }

    func fail(_ path: String, with error: FileSystemError) { lock.withLock { failures[path] = error } }
    func makeUnwritable(_ dir: String) { lock.withLock { _ = unwritable.insert(dir) } }
    func replace(_ path: String) { lock.withLock { nodes[path] = nil }; add(path) }
    func contains(_ path: String) -> Bool { lock.withLock { nodes[path] != nil } }

    func identity(atPath path: String) throws -> FileIdentity {
        guard let id = lock.withLock({ nodes[path] }) else { throw FileSystemError.notFound(path) }
        return id
    }

    func canonicalPath(_ path: String) -> String? { lock.withLock { nodes[path] != nil ? path : nil } }

    func isWritableDirectory(_ directory: String) -> Bool { lock.withLock { !unwritable.contains(directory) } }

    func moveToTrash(atPath path: String) throws -> String? {
        try mutate(path, verb: "trash")
        return "/mock/.Trash/" + (path as NSString).lastPathComponent
    }

    func removeTree(atPath path: String, expected: FileIdentity, shouldCancel: @Sendable () -> Bool) throws -> RemovalStats {
        if let current = lock.withLock({ nodes[path] }), !current.isSameObject(as: expected) {
            throw FileSystemError.identityMismatch(path)
        }
        try mutate(path, verb: "remove")
        return RemovalStats(removedFiles: 1, logicalBytes: expected.logicalSize, freedBytes: expected.allocatedSize)
    }

    private func mutate(_ path: String, verb: String) throws {
        try lock.withLock {
            log.append("\(verb) \(path)")
            if let error = failures[path] { throw error }
            guard nodes[path] != nil else { throw FileSystemError.notFound(path) }
            for key in nodes.keys where key == path || key.hasPrefix(path + "/") { nodes[key] = nil }
        }
    }
}

enum Fixtures {
    static func candidate(path: String, identity: FileIdentity, root: String, risk: RiskLevel = .safe,
                          guards: [ProcessGuard] = [], method: RemovalMethod = .permanent, regenerable: Bool = true,
                          allowsPermanent: Bool = true, tolerates: Bool = true, size: Int64 = 4096,
                          category: CleanupCategory = .appCache, target: CleanupTarget? = nil) -> CleanupCandidate {
        CleanupCandidate(
            id: "path:" + path, title: (path as NSString).lastPathComponent, subtitle: path, category: category,
            ruleID: "test", risk: risk, riskReason: "test", impact: "test", regenerable: regenerable,
            size: SizeInfo(logical: size, allocated: size, fileCount: 1), lastModified: nil,
            target: target ?? .path(PathTarget(url: URL(fileURLWithPath: path), identity: identity,
                                               allowedRoot: URL(fileURLWithPath: root), toleratesContentChanges: tolerates,
                                               scannedAt: Date())),
            guards: guards, preferredMethod: method, allowsPermanentRemoval: allowsPermanent, warning: nil)
    }
}
