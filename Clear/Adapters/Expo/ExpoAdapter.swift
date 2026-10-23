import Foundation

/// Global Expo / React Native / CocoaPods data. Per-project folders are handled by `ProjectAnalyzer`.
struct ExpoAdapter: ToolAdapter {
    let id = "expo"
    let name = "Expo / React Native"
    let symbol = "atom"
    let kind = ToolKind.developer

    func scan(_ ctx: ScanContext) async -> ToolReport {
        let expo = ctx.url(".expo")
        let pods = ctx.url("Library/Caches/CocoaPods")
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind,
                                installed: ctx.exists(expo) || ctx.exists(pods))
        guard report.installed else { return report }
        report.runningProcesses = ctx.processes.runningGuards(DeveloperGuards.metro + DeveloperGuards.expo)
        ctx.progress(ScanProgress(phase: "Expo 캐시 분석 중"))

        for (rel, title, risk, reason) in [
            ("android-apk-cache", "Expo Go APK 캐시", RiskLevel.safe, "필요 시 다시 내려받는 Expo Go 앱"),
            ("ios-simulator-app-cache", "Expo Go 시뮬레이터 앱 캐시", .safe, "필요 시 다시 내려받는 Expo Go 앱"),
            ("versions-cache", "SDK 버전 메타데이터", .safe, "Expo 서버에서 다시 받는 메타데이터"),
            ("schema-cache", "설정 스키마 캐시", .safe, "Expo 서버에서 다시 받는 스키마"),
            ("native-modules-cache", "네이티브 모듈 캐시", .review, "Expo CLI 내부 캐시"),
        ] {
            let spec = CandidateSpec(title: title, category: .expo, ruleID: "dev.expo.global", risk: risk,
                                     riskReason: reason, impact: "필요할 때 Expo CLI가 다시 받습니다.",
                                     regenerable: true, guards: DeveloperGuards.expo, minimumSize: 256 * 1024)
            if let c = ctx.makeCandidate(at: expo.appendingPathComponent(rel), root: expo, spec: spec) { report.candidates.append(c) }
        }
        for (rel, title, role) in [("state.json", "Expo 로그인 정보", ToolLocation.Role.credentials),
                                   ("codesigning", "코드 서명", .credentials)] {
            if let loc = ctx.location(expo.appendingPathComponent(rel), title: title, role: role, protected: true, note: "보호됨") {
                report.locations.append(loc)
            }
        }

        // Metro bundler caches in the per-user temp directory.
        let tmp = ctx.temporaryDirectory
        for child in ctx.children(of: tmp) ?? [] {
            let name = child.lastPathComponent
            guard name.hasPrefix("metro-") || name.hasPrefix("haste-map") else { continue }
            let spec = CandidateSpec(title: "Metro 캐시 (\(name))", category: .expo, ruleID: "dev.metro.cache", risk: .safe,
                                     riskReason: "Metro가 다시 만드는 번들러 캐시",
                                     impact: "다음 번들링이 처음부터 다시 수행됩니다.", regenerable: true,
                                     guards: DeveloperGuards.metro, minimumSize: 256 * 1024)
            if let c = ctx.makeCandidate(at: child, root: tmp, spec: spec) { report.candidates.append(c) }
        }

        let caches = ctx.url("Library/Caches")
        for (folder, title, guards) in [("CocoaPods", "CocoaPods 다운로드 캐시", DeveloperGuards.cocoapods),
                                        ("eas-cli", "EAS CLI 캐시", DeveloperGuards.expo)] {
            let spec = CandidateSpec(title: title, category: .expo, ruleID: "dev.expo.cache", risk: .safe,
                                     riskReason: "다시 내려받을 수 있는 캐시", impact: "다음 설치 시 다시 내려받습니다.",
                                     regenerable: true, guards: guards, minimumSize: 512 * 1024)
            if let c = ctx.makeCandidate(at: caches.appendingPathComponent(folder), root: caches, spec: spec) {
                report.candidates.append(c)
            }
        }
        report.locations.append(contentsOf: report.candidates.compactMap { c in
            c.path.map { ToolLocation(path: $0, title: c.title, role: .cache, size: c.size, isProtected: false, note: nil) }
        })
        report.notes.append("프로젝트의 .expo, android/build, ios/build 등은 개발자 도구 › 프로젝트에서 관리합니다. ios/Pods는 자동 선택하지 않습니다.")
        return report
    }
}
