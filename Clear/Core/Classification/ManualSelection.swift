import Foundation

/// Items the user picks by hand (Disk Explorer). They go to the Trash only, and
/// every safety rule still applies: protected paths, allowed roots, ownership,
/// and processes using them.
enum ManualSelection {
    static func candidate(path: String, ctx: ScanContext) -> CleanupCandidate? {
        let canonical = PathUtilities.canonicalPath(path) ?? path
        let url = URL(fileURLWithPath: canonical)
        let spec = CandidateSpec(
            id: "explorer:\(canonical)", title: url.lastPathComponent, category: .largeFile, ruleID: "explorer.manual",
            risk: .manual, riskReason: "디스크 분석에서 직접 고른 항목",
            impact: "휴지통으로 이동합니다. 휴지통을 비우기 전까지 되돌릴 수 있습니다.",
            regenerable: false, guards: [.pathInUse(canonical)], preferredMethod: .trash,
            allowsPermanentRemoval: false, minimumSize: 0)
        // Outside every allowed root, makeCandidate marks it blocked ("허용 위치 밖").
        let root = ctx.policy.allowedRoot(containing: canonical).map { URL(fileURLWithPath: $0) } ?? url.deletingLastPathComponent()
        guard var c = ctx.makeCandidate(at: url, root: root, spec: spec) else { return nil }
        if c.risk != .blocked, !c.runningGuards.isEmpty {
            c.risk = .blocked
            c.riskReason = "실행 중인 프로세스가 이 항목을 쓰고 있음"
        }
        return c
    }
}
