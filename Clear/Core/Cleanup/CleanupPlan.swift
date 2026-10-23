import Foundation

struct CleanupPlanItem: Identifiable, Hashable, Sendable {
    var id: String { candidate.id }
    let candidate: CleanupCandidate
    let method: RemovalMethod
    /// Recoverable from the Trash.
    var isRecoverable: Bool { method == .trash || isCommand }
    var isCommand: Bool { if case .command = candidate.target { true } else { false } }
}

struct CleanupPlan: Sendable, Identifiable {
    let id = UUID()
    let title: String
    let items: [CleanupPlanItem]
    /// Items dropped while planning, with the reason.
    let excluded: [(candidate: CleanupCandidate, reason: String)]
    let warnings: [String]
    let createdAt: Date

    var estimatedBytes: Int64 { items.reduce(0) { $0 + $1.candidate.estimatedBytes } }
    var trashBytes: Int64 { items.filter { $0.method == .trash && !$0.isCommand }.reduce(0) { $0 + $1.candidate.estimatedBytes } }
    var permanentBytes: Int64 { items.filter { $0.method == .permanent }.reduce(0) { $0 + $1.candidate.estimatedBytes } }
    var commandItems: [CleanupPlanItem] { items.filter(\.isCommand) }
    /// MANUAL items need an extra, explicit acknowledgement in the UI.
    var requiresExplicitAcknowledgement: Bool {
        items.contains { $0.candidate.risk == .manual || $0.candidate.risk == .review && $0.isCommand }
    }
    var isEmpty: Bool { items.isEmpty }
}

/// Turns a user selection into an executable plan:
/// drops blocked items, removes duplicates and nested paths (so nothing is counted
/// twice), decides the removal method and collects warnings.
struct CleanupPlanner: Sendable {
    var preferTrash: Bool

    func makePlan(title: String, selection: [CleanupCandidate]) -> CleanupPlan {
        var excluded: [(CleanupCandidate, String)] = []
        var seen = Set<String>()
        var unique: [CleanupCandidate] = []
        for c in selection {
            guard c.risk != .blocked else { excluded.append((c, "보호 대상")); continue }
            let key = c.path ?? c.id
            guard seen.insert(key).inserted else { continue }
            unique.append(c)
        }

        // Drop items nested inside another selected path (parent wins).
        let paths = unique.compactMap(\.path)
        var items: [CleanupPlanItem] = []
        for c in unique {
            if let p = c.path, paths.contains(where: { PathUtilities.isStrictDescendant(p, of: $0) }) {
                excluded.append((c, "상위 폴더와 함께 정리됨"))
                continue
            }
            let method: RemovalMethod
            if case .command = c.target {
                method = .permanent
            } else if c.category == .trash {
                method = .permanent
            } else if c.allowsPermanentRemoval && c.regenerable && !preferTrash && c.preferredMethod == .permanent {
                method = .permanent
            } else {
                method = .trash
            }
            items.append(CleanupPlanItem(candidate: c, method: method))
        }

        var warnings: [String] = []
        if items.contains(where: { $0.candidate.category == .trash }) {
            warnings.append("휴지통의 항목은 영구 삭제되며 되돌릴 수 없습니다.")
        }
        if items.contains(where: { !$0.candidate.regenerable && $0.method == .trash }) {
            warnings.append("재생성되지 않는 데이터가 포함되어 있습니다. 휴지통에서 복구할 수 있습니다.")
        }
        if items.contains(where: { $0.method == .trash && !$0.isCommand }) {
            warnings.append("휴지통으로 옮긴 항목은 휴지통을 비울 때까지 디스크 공간을 계속 사용합니다.")
        }
        if items.contains(where: { $0.method == .permanent && !$0.isCommand }) {
            warnings.append("즉시 삭제 항목은 복구할 수 없습니다. 재생성 가능한 캐시에만 적용됩니다.")
        }
        for item in items {
            if let w = item.candidate.warning { warnings.append("\(item.candidate.title): \(w)") }
        }
        return CleanupPlan(title: title, items: items, excluded: excluded, warnings: warnings, createdAt: Date())
    }
}
