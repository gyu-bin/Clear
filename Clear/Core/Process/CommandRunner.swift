import Darwin
import Foundation

/// External tools Clear may invoke. Each resolves only from fixed, well-known
/// locations — never from `PATH` or user input.
enum TrustedTool: String, Codable, Sendable, CaseIterable {
    case brew, docker, xcrun, git, ollama, pnpm

    var candidatePaths: [String] {
        let home = PathUtilities.realHomeDirectory.path
        switch self {
        case .brew: return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        case .docker: return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                              "/Applications/Docker.app/Contents/Resources/bin/docker",
                              home + "/.docker/bin/docker", home + "/.orbstack/bin/docker"]
        case .xcrun: return ["/usr/bin/xcrun"]
        case .git: return ["/usr/bin/git", "/opt/homebrew/bin/git"]
        case .ollama: return ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama",
                              "/Applications/Ollama.app/Contents/Resources/ollama"]
        case .pnpm: return [home + "/Library/pnpm/pnpm", "/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"]
        }
    }
}

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

enum CommandError: Error, LocalizedError, Sendable {
    case toolNotFound(TrustedTool)
    case untrustedExecutable(String)
    case timedOut(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let t): "\(t.rawValue)을(를) 찾을 수 없습니다"
        case .untrustedExecutable(let p): "신뢰할 수 없는 실행 파일: \(p)"
        case .timedOut(let c): "시간 초과: \(c)"
        case .launchFailed(let m): "실행 실패: \(m)"
        }
    }
}

protocol CommandRunning: Sendable {
    func locate(_ tool: TrustedTool) -> URL?
    func run(_ tool: TrustedTool, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

/// Runs trusted tools with `Process` (argv array, no shell), a minimal fixed
/// environment and a timeout. Output is capped to keep memory bounded.
struct CommandRunner: CommandRunning {
    var maxOutputBytes = 4 * 1024 * 1024

    func locate(_ tool: TrustedTool) -> URL? {
        for candidate in tool.candidatePaths {
            guard let resolved = PathUtilities.canonicalPath(candidate) else { continue }
            if Self.isTrustedExecutable(resolved) { return URL(fileURLWithPath: resolved) }
        }
        return nil
    }

    /// Regular file, executable, owned by root or the current user, and not writable by others.
    static func isTrustedExecutable(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        guard access(path, X_OK) == 0 else { return false }
        guard st.st_uid == 0 || st.st_uid == getuid() else { return false }
        return st.st_mode & S_IWOTH == 0
    }

    func run(_ tool: TrustedTool, _ arguments: [String], timeout: TimeInterval = 120) async throws -> CommandResult {
        guard let executable = locate(tool) else { throw CommandError.toolNotFound(tool) }
        let maxBytes = maxOutputBytes
        let display = ([tool.rawValue] + arguments).joined(separator: " ")

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let home = PathUtilities.realHomeDirectory.path
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": home,
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "DOCKER_CLI_HINTS": "false",
            "NO_COLOR": "1",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                        return
                    }
                    let timer = DispatchWorkItem { if process.isRunning { box.timedOut = true; process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                    // Drain both pipes concurrently so a full pipe never blocks the child.
                    let group = DispatchGroup()
                    let output = OutputBox()
                    group.enter()
                    DispatchQueue.global().async { output.setOut(Self.read(outPipe.fileHandleForReading, limit: maxBytes)); group.leave() }
                    group.enter()
                    DispatchQueue.global().async { output.setErr(Self.read(errPipe.fileHandleForReading, limit: maxBytes)); group.leave() }
                    group.wait()
                    let (outData, errData) = output.values
                    process.waitUntilExit()
                    timer.cancel()

                    if box.timedOut {
                        cont.resume(throwing: CommandError.timedOut(display))
                        return
                    }
                    cont.resume(returning: CommandResult(
                        exitCode: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    private static func read(_ handle: FileHandle, limit: Int) -> Data {
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
        }
        return data
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    var values: (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    var timedOut = false
    init(_ p: Process) { process = p }
    func terminate() { if process.isRunning { process.terminate() } }
}
