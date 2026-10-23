import Foundation

/// npm, pnpm and Yarn caches — each with its own policy.
struct NodeAdapter: ToolAdapter {
    let id = "node"
    let name = "Node.js 패키지 매니저"
    let symbol = "cube.fill"
    let kind = ToolKind.developer

    func scan(_ ctx: ScanContext) async -> ToolReport {
        let markers = [ctx.url(".npm"), ctx.url("Library/pnpm"), ctx.url("Library/Caches/Yarn"),
                       URL(fileURLWithPath: "/opt/homebrew/bin/node"), URL(fileURLWithPath: "/usr/local/bin/node")]
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: markers.contains { ctx.exists($0) })
        guard report.installed else { return report }
        report.runningProcesses = ctx.processes.runningGuards(DeveloperGuards.npm + DeveloperGuards.yarn + DeveloperGuards.pnpm)
        ctx.progress(ScanProgress(phase: "npm 캐시 분석 중"))

        let npm = ctx.url(".npm")
        let npmItems: [(String, String, RiskLevel, String, String)] = [
            ("_cacache", "npm 다운로드 캐시", .safe, "npm이 필요 시 다시 내려받는 패키지 캐시", "다음 설치 시 패키지를 다시 내려받습니다(오프라인 설치 불가)."),
            ("_npx", "npx 패키지 캐시", .safe, "npx로 실행한 일회성 패키지", "다음 npx 실행 시 다시 내려받습니다."),
            ("_logs", "npm 로그", .safe, "설치 오류 로그", "과거 npm 로그가 사라집니다."),
            ("_prebuilds", "네이티브 모듈 프리빌드", .review, "네이티브 모듈 사전 빌드 캐시", "다음 설치 시 다시 내려받거나 빌드합니다."),
        ]
        for (rel, title, risk, reason, impact) in npmItems {
            let spec = CandidateSpec(title: title, category: .node, ruleID: "dev.npm", risk: risk, riskReason: reason,
                                     impact: impact, regenerable: true, guards: DeveloperGuards.npm, minimumSize: 512 * 1024)
            if let c = ctx.makeCandidate(at: npm.appendingPathComponent(rel), root: npm, spec: spec) { report.candidates.append(c) }
        }

        let caches = ctx.url("Library/Caches")
        for (folder, title, risk, reason, guards) in [
            ("Yarn", "Yarn v1 캐시", RiskLevel.safe, "Yarn이 다시 내려받는 패키지 캐시", DeveloperGuards.yarn),
            ("node-gyp", "node-gyp 헤더", .safe, "네이티브 모듈 빌드용 Node 헤더", DeveloperGuards.npm),
            ("typescript", "TypeScript 캐시", .safe, "타입 정의 자동 다운로드 캐시", [ProcessGuard]()),
            ("ms-playwright", "Playwright 브라우저", .review, "테스트 브라우저 — 다시 설치에 시간이 걸림", [ProcessGuard]()),
        ] {
            let spec = CandidateSpec(title: title, category: .node, ruleID: "dev.node.cache", risk: risk, riskReason: reason,
                                     impact: "필요할 때 다시 내려받습니다.", regenerable: true, guards: guards,
                                     minimumSize: 512 * 1024)
            if let c = ctx.makeCandidate(at: caches.appendingPathComponent(folder), root: caches, spec: spec) {
                report.candidates.append(c)
            }
        }

        let berry = ctx.url(".yarn/berry/cache")
        if ctx.exists(berry) {
            let spec = CandidateSpec(title: "Yarn Berry 전역 캐시", category: .node, ruleID: "dev.yarn.berry", risk: .review,
                                     riskReason: "PnP 프로젝트가 참조할 수 있는 전역 캐시",
                                     impact: "프로젝트에서 `yarn install`을 다시 실행해야 할 수 있습니다.",
                                     regenerable: true, guards: DeveloperGuards.yarn)
            if let c = ctx.makeCandidate(at: berry, root: berry.deletingLastPathComponent(), spec: spec) {
                report.candidates.append(c)
            }
        }

        // pnpm store: content-addressable and hard-linked into projects. Only the
        // official prune command is offered; direct deletion frees little and breaks offline installs.
        let store = ctx.url("Library/pnpm/store")
        if let loc = ctx.location(store, title: "pnpm 저장소", role: .cache, protected: true,
                                  note: "프로젝트 node_modules와 하드 링크로 공유됩니다. `pnpm store prune`으로만 정리합니다.") {
            report.locations.append(loc)
            if ctx.commandRunner.locate(.pnpm) != nil {
                report.candidates.append(CleanupCandidate(
                    id: "pnpm:store-prune", title: "pnpm 저장소 정리", subtitle: "pnpm store prune",
                    category: .node, ruleID: "dev.pnpm.prune", risk: .review,
                    riskReason: "어떤 프로젝트도 참조하지 않는 패키지만 pnpm이 제거",
                    impact: "참조되지 않는 패키지가 제거됩니다. 실제 확보량은 pnpm이 계산합니다.",
                    regenerable: true, size: .zero, lastModified: nil,
                    target: .command(TrustedCommand(tool: .pnpm, arguments: ["store", "prune"])),
                    guards: DeveloperGuards.pnpm, preferredMethod: .permanent, allowsPermanentRemoval: true,
                    runningGuards: ctx.processes.runningGuards(DeveloperGuards.pnpm)))
            } else {
                report.notes.append("pnpm 실행 파일을 신뢰할 수 있는 위치에서 찾지 못해 저장소 정리를 제공하지 않습니다.")
            }
        }
        report.locations.append(contentsOf: report.candidates.compactMap { c in
            c.path.map { ToolLocation(path: $0, title: c.title, role: .cache, size: c.size, isProtected: false, note: nil) }
        })
        report.notes.append("프로젝트의 node_modules는 개발자 도구 › 프로젝트에서 프로젝트별로 직접 선택해 정리합니다.")
        return report
    }
}
