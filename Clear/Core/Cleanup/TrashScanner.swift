import Foundation

enum TrashScanError: Error, LocalizedError {
    case needsFullDiskAccess

    var errorDescription: String? {
        "휴지통을 읽으려면 전체 디스크 접근 권한이 필요합니다."
    }
}

/// Lists the items in the user's Trash (`~/.Trash`) as cleanup candidates.
///
/// Emptying goes through the normal engine: confirmation, per-item re-validation
/// right before removal, descriptor-based deletion and history. Each top-level
/// entry is one candidate; symlinks and protected items (e.g. a trashed Photos
/// library) are left alone. Trashes on external volumes are not touched.
struct TrashScanner: Sendable {
    func candidates(_ ctx: ScanContext) throws -> [CleanupCandidate] {
        let trash = ctx.url(".Trash")
        guard let children = ctx.children(of: trash) else { throw TrashScanError.needsFullDiskAccess }
        var result: [CleanupCandidate] = []
        for child in children where child.lastPathComponent != ".DS_Store" {
            if Task.isCancelled { break }
            let spec = CandidateSpec(
                title: child.lastPathComponent, category: .trash, ruleID: "trash.empty",
                risk: .manual, riskReason: "휴지통에 있는 항목",
                impact: "영구 삭제되며 되돌릴 수 없습니다.",
                regenerable: false, preferredMethod: .permanent, allowsPermanentRemoval: true,
                toleratesContentChanges: true, minimumSize: 0)
            if let candidate = ctx.makeCandidate(at: child, root: trash, spec: spec) {
                result.append(candidate)
            }
        }
        return result
    }
}
