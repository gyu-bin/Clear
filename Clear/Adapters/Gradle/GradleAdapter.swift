import Foundation

/// Gradle and Android Studio. Gradle prunes its own caches (30 days by default), so
/// Clear never removes `~/.gradle/caches` wholesale; it only offers clearly
/// version-scoped folders and the local build cache.
struct GradleAdapter: ToolAdapter {
    let id = "gradle"
    let name = "Gradle / Android"
    let symbol = "building.columns.fill"
    let kind = ToolKind.developer
    var staleDistributionAge: TimeInterval = 90 * 24 * 3600

    func scan(_ ctx: ScanContext) async -> ToolReport {
        let gradle = ctx.url(".gradle")
        let studioApp = ["/Applications/Android Studio.app"].first { ctx.exists(URL(fileURLWithPath: $0)) }
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind,
                                installed: ctx.exists(gradle) || studioApp != nil,
                                version: studioApp.flatMap { ctx.bundleVersion(ofAppAt: $0) }.map { "Android Studio \($0)" })
        guard report.installed else { return report }
        let guards = DeveloperGuards.gradle + DeveloperGuards.androidStudio
        report.runningProcesses = ctx.processes.runningGuards(guards)
        ctx.progress(ScanProgress(phase: "Gradle 캐시 분석 중"))

        let caches = gradle.appendingPathComponent("caches")
        if let loc = ctx.location(caches, title: "Gradle 캐시 전체", role: .cache, protected: true,
                                  note: "Gradle이 자체 정책으로 오래된 항목을 정리합니다. 전체 삭제는 제공하지 않습니다.") {
            report.locations.append(loc)
        }

        // Wrapper distributions: keep the newest; older and unused ones are candidates.
        let dists = gradle.appendingPathComponent("wrapper/dists")
        let distributions = (ctx.children(of: dists) ?? []).filter { ctx.isDirectory($0) }
        let versionsInUse = Set(distributions.compactMap { Self.version(fromDistribution: $0.lastPathComponent) })
        let newest = versionsInUse.max(by: Self.compareVersions)
        for dist in distributions {
            let v = Self.version(fromDistribution: dist.lastPathComponent)
            let spec = CandidateSpec(title: dist.lastPathComponent, category: .gradle, ruleID: "dev.gradle.wrapper",
                                     risk: .review, riskReason: "다른 Gradle 버전을 쓰는 프로젝트가 다시 내려받음",
                                     impact: "이 버전을 쓰는 프로젝트를 빌드할 때 다시 내려받습니다.",
                                     regenerable: true, guards: guards, minimumSize: 10 * 1024 * 1024)
            guard var c = ctx.makeCandidate(at: dist, root: gradle, spec: spec) else { continue }
            if v == newest { c.risk = .review; c.riskReason = "가장 최신 Gradle 배포판 — 사용 중일 가능성이 높음" }
            else if let last = c.size.newestModification, ctx.scannedAt.timeIntervalSince(last) > staleDistributionAge {
                c.riskReason = "90일 넘게 사용하지 않은 Gradle 배포판"
            }
            report.candidates.append(c)
        }

        // Version-scoped cache folders (caches/8.7) for versions no longer installed.
        for folder in ctx.children(of: caches) ?? [] where ctx.isDirectory(folder) {
            let name = folder.lastPathComponent
            guard name.first?.isNumber == true, name.contains("."), !versionsInUse.contains(name) else { continue }
            let spec = CandidateSpec(title: "Gradle \(name) 전용 캐시", category: .gradle, ruleID: "dev.gradle.versionCache",
                                     risk: .review, riskReason: "설치된 래퍼 배포판에 없는 Gradle 버전의 캐시",
                                     impact: "해당 버전으로 빌드할 때 다시 만들어집니다.", regenerable: true,
                                     guards: guards, minimumSize: 10 * 1024 * 1024)
            if let c = ctx.makeCandidate(at: folder, root: gradle, spec: spec) { report.candidates.append(c) }
        }
        let buildCache = caches.appendingPathComponent("build-cache-1")
        let bcSpec = CandidateSpec(title: "Gradle 로컬 빌드 캐시", category: .gradle, ruleID: "dev.gradle.buildCache",
                                   risk: .review, riskReason: "빌드 결과 재사용 캐시 — 다음 빌드가 느려짐",
                                   impact: "다음 빌드에서 작업을 다시 실행합니다.", regenerable: true, guards: guards,
                                   minimumSize: 10 * 1024 * 1024)
        if let c = ctx.makeCandidate(at: buildCache, root: gradle, spec: bcSpec) { report.candidates.append(c) }

        let daemon = gradle.appendingPathComponent("daemon")
        for folder in ctx.children(of: daemon) ?? [] where ctx.isDirectory(folder) {
            let spec = CandidateSpec(title: "Gradle 데몬 로그 \(folder.lastPathComponent)", category: .gradle,
                                     ruleID: "dev.gradle.daemon", risk: .safe, riskReason: "데몬 로그와 레지스트리",
                                     impact: "과거 데몬 로그가 사라집니다.", regenerable: true, guards: guards,
                                     minimumSize: 1024 * 1024)
            if let c = ctx.makeCandidate(at: folder, root: gradle, spec: spec) { report.candidates.append(c) }
        }

        // Android Studio caches / logs.
        for (base, title, category) in [("Library/Caches/Google", "캐시", CleanupCategory.android),
                                         ("Library/Logs/Google", "로그", .android)] {
            let dir = ctx.url(base)
            for folder in ctx.children(of: dir) ?? [] where folder.lastPathComponent.hasPrefix("AndroidStudio") {
                let root = ctx.url(base.hasPrefix("Library/Caches") ? "Library/Caches" : "Library/Logs")
                let spec = CandidateSpec(title: "\(folder.lastPathComponent) \(title)", category: category,
                                         ruleID: "dev.androidStudio", risk: .safe,
                                         riskReason: "Android Studio가 다시 만드는 \(title)",
                                         impact: "다음 실행 시 인덱스를 다시 만들어 잠시 느릴 수 있습니다.",
                                         regenerable: true, guards: DeveloperGuards.androidStudio, minimumSize: 1024 * 1024)
                if let c = ctx.makeCandidate(at: folder, root: root, spec: spec) { report.candidates.append(c) }
            }
        }

        // Emulators: display only.
        let avd = ctx.url(".android/avd")
        for device in ctx.children(of: avd) ?? [] where device.pathExtension == "avd" {
            if let loc = ctx.location(device, title: "에뮬레이터 \(device.deletingPathExtension().lastPathComponent)",
                                      role: .simulator, protected: true, note: "Android Studio의 Device Manager에서 삭제하세요.") {
                report.locations.append(loc)
            }
        }
        if let loc = ctx.location(gradle.appendingPathComponent("jdks"), title: "Gradle JDK", role: .other, protected: true,
                                  note: "툴체인 JDK — 분석만 제공") {
            report.locations.append(loc)
        }
        report.locations.append(contentsOf: report.candidates.compactMap { c in
            c.path.map { ToolLocation(path: $0, title: c.title, role: .cache, size: c.size, isProtected: false, note: nil) }
        })
        return report
    }

    /// "gradle-8.7-bin" → "8.7"
    static func version(fromDistribution name: String) -> String? {
        let parts = name.split(separator: "-")
        guard parts.count >= 3, parts.first == "gradle" else { return nil }
        return parts[1..<(parts.count - 1)].joined(separator: "-")
    }

    static func compareVersions(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}
