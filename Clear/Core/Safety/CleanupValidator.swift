import Darwin
import Foundation

enum ValidationOutcome: Equatable, Sendable {
    case approved
    /// Nothing to do; already removed by someone else.
    case alreadyGone
    case rejected(String)

    var rejectionReason: String? {
        if case .rejected(let r) = self { return r }
        return nil
    }
}

/// Re-verifies a candidate immediately before it is removed.
///
/// String prefix checks are never enough on their own; this validator compares
/// canonical paths component-wise, re-reads the inode, checks the volume, owner and
/// permissions, and asks the process table whether a guarded tool is running.
struct CleanupValidator: Sendable {
    let policy: SafetyPolicy
    let fileSystem: FileSystemOperating
    let commandRunner: CommandRunning
    var currentUID: UInt32 = getuid()

    func validate(_ candidate: CleanupCandidate, processes: ProcessSnapshot) -> ValidationOutcome {
        if candidate.risk == .blocked { return .rejected("보호 대상 항목") }
        let running = processes.runningGuards(candidate.guards)
        if !running.isEmpty { return .rejected("\(running.joined(separator: ", ")) 실행 중") }

        switch candidate.target {
        case .command(let command):
            guard commandRunner.locate(command.tool) != nil else {
                return .rejected("\(command.tool.rawValue) 실행 파일을 신뢰할 수 있는 위치에서 찾지 못함")
            }
            return .approved
        case .path(let target):
            return validatePath(target)
        }
    }

    func validatePath(_ target: PathTarget) -> ValidationOutcome {
        let path = target.path
        guard PathUtilities.isWellFormedAbsolutePath(path) else { return .rejected("잘못된 경로 형식") }

        // 1. Root must be a registered root, canonical, and not itself protected-from-traversal.
        let root = target.allowedRoot.path
        guard policy.isAllowedRoot(root) else { return .rejected("허용되지 않은 위치") }
        guard fileSystem.canonicalPath(root) == root else { return .rejected("허용 위치의 경로가 바뀜") }
        guard PathUtilities.isStrictDescendant(path, of: root) else { return .rejected("허용 위치 밖의 경로") }

        // 2. Still exists, and resolving it gives the very same path (no symlinked ancestor).
        guard let canonical = fileSystem.canonicalPath(path) else {
            return (try? fileSystem.identity(atPath: path)) == nil ? .alreadyGone : .rejected("경로를 확인할 수 없음")
        }
        let current: FileIdentity
        do { current = try fileSystem.identity(atPath: path) } catch FileSystemError.notFound {
            return .alreadyGone
        } catch {
            return .rejected(error.localizedDescription)
        }
        if current.kind == .symlink { return .rejected("심볼릭 링크는 삭제 대상이 아님") }
        guard canonical == path else { return .rejected("경로에 심볼릭 링크가 포함됨") }

        // 3. Protected locations (including user exclusions).
        if let reason = policy.protectionReason(for: path) { return .rejected("보호 경로: \(reason)") }

        // 4. Same object as at scan time, on the same volume as the root.
        guard current.isSameObject(as: target.identity) else { return .rejected("스캔 이후 다른 항목으로 바뀜") }
        if let rootIdentity = try? fileSystem.identity(atPath: root), rootIdentity.device != current.device {
            return .rejected("다른 볼륨에 있는 항목")
        }
        if !target.toleratesContentChanges || current.kind != .directory {
            if abs(current.modificationTime - target.identity.modificationTime) > 0.001
                || (current.kind == .file && current.logicalSize != target.identity.logicalSize) {
                return .rejected("스캔 이후 수정됨 — 다시 스캔하세요")
            }
        }

        // 5. Ownership and permission.
        guard current.ownerUID == currentUID else { return .rejected("다른 사용자 소유 항목") }
        let parent = (path as NSString).deletingLastPathComponent
        guard fileSystem.isWritableDirectory(parent) else { return .rejected("상위 폴더에 쓰기 권한 없음") }
        return .approved
    }
}
