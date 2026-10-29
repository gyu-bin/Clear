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
    /// Projects to read Gradle and NDK versions from. Empty = unknown, and
    /// installed versions are treated as in use.
    var projectFolders: [String] = []

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
        let installed = Set(distributions.compactMap { Self.version(fromDistribution: $0.lastPathComponent) })
        let newest = installed.max(by: Self.compareVersions)
        let usage = Self.projectUsage(projectFolders)
        // Versions some project needs; without known projects, everything installed counts.
        let versionsInUse = usage.gradle.isEmpty ? installed : usage.gradle
        for dist in distributions {
            let v = Self.version(fromDistribution: dist.lastPathComponent)
            let spec = CandidateSpec(title: dist.lastPathComponent, category: .gradle, ruleID: "dev.gradle.wrapper",
                                     risk: .review, riskReason: "다른 Gradle 버전을 쓰는 프로젝트가 다시 내려받음",
                                     impact: "이 버전을 쓰는 프로젝트를 빌드할 때 다시 내려받습니다.",
                                     regenerable: true, guards: guards, minimumSize: 10 * 1024 * 1024)
            guard var c = ctx.makeCandidate(at: dist, root: gradle, spec: spec) else { continue }
            if !usage.gradle.isEmpty, let v {
                c.riskReason = usage.gradle.contains(v) ? "프로젝트가 쓰는 Gradle 버전 — 지우면 다음 빌드 때 다시 내려받음"
                    : "어느 프로젝트도 쓰지 않는 Gradle 버전"
            } else if v == newest { c.risk = .review; c.riskReason = "가장 최신 Gradle 배포판 — 사용 중일 가능성이 높음" }
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
                                     risk: .review,
                                     riskReason: usage.gradle.isEmpty ? "설치된 래퍼 배포판에 없는 Gradle 버전의 캐시"
                                         : "어느 프로젝트도 쓰지 않는 Gradle 버전의 캐시",
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

        // NDK versions no project asks for (each is a few GB).
        let ndkRoot = ctx.url("Library/Android/sdk/ndk")
        if !usage.ndk.isEmpty {
            for folder in ctx.children(of: ndkRoot) ?? [] where ctx.isDirectory(folder) {
                let version = folder.lastPathComponent
                guard version.first?.isNumber == true, !usage.ndk.contains(version) else { continue }
                let spec = CandidateSpec(title: "Android NDK \(version)", category: .android, ruleID: "dev.android.ndk",
                                         risk: .review, riskReason: "어느 프로젝트도 쓰지 않는 NDK 버전",
                                         impact: "이 버전이 필요한 프로젝트를 빌드하면 Android Studio SDK Manager가 다시 설치합니다.",
                                         regenerable: true, guards: guards, minimumSize: 10 * 1024 * 1024)
                if let c = ctx.makeCandidate(at: folder, root: ndkRoot, spec: spec) { report.candidates.append(c) }
            }
        }

        scanEmulators(ctx, into: &report)
        if let loc = ctx.location(gradle.appendingPathComponent("jdks"), title: "Gradle JDK", role: .other, protected: true,
                                  note: "툴체인 JDK — 분석만 제공") {
            report.locations.append(loc)
        }
        report.locations.append(contentsOf: report.candidates.compactMap { c in
            c.path.map { ToolLocation(path: $0, title: c.title, role: .cache, size: c.size, isProtected: false, note: nil) }
        })
        return report
    }

    // MARK: Android emulators

    /// Each emulator is `<name>.avd/` plus a `<name>.ini` pointer; both go together.
    /// Quick-boot snapshots can go alone. System images no emulator uses are offered too.
    private func scanEmulators(_ ctx: ScanContext, into report: inout ToolReport) {
        let android = ctx.url(".android")
        let avdDir = android.appendingPathComponent("avd")
        var imagesInUse = Set<String>()
        for device in ctx.children(of: avdDir) ?? [] where device.pathExtension == "avd" && ctx.isDirectory(device) {
            let name = device.deletingPathExtension().lastPathComponent
            let config = Self.iniValues(at: device.appendingPathComponent("config.ini"))
            if let image = config["image.sysdir.1"] { imagesInUse.insert(Self.normalizedImage(image)) }
            let display = config["avd.ini.displayname"] ?? name
            // The emulator is started with `-avd <name>`.
            let running = ProcessGuard.commandLine("-avd \(name)", "에뮬레이터 \(display)")
            let spec = CandidateSpec(
                id: "avd:\(device.path)", title: "Android 에뮬레이터 · \(display)", category: .androidEmulator,
                ruleID: "dev.android.avd", risk: .manual,
                riskReason: "에뮬레이터 기기와 그 안의 앱·데이터가 모두 삭제됩니다",
                impact: "다시 쓰려면 Android Studio의 Device Manager에서 새로 만들어야 합니다.",
                regenerable: false, guards: [running], preferredMethod: .permanent,
                warning: "에뮬레이터 안의 앱 데이터는 복구할 수 없습니다.",
                minimumSize: 50 * 1024 * 1024, companions: [avdDir.appendingPathComponent(name + ".ini")])
            if var c = ctx.makeCandidate(at: device, root: android, spec: spec) {
                if let last = c.size.newestModification {
                    c.riskReason += " · 마지막 사용 \(GeneralCleanupScanner.idleText(ctx.scannedAt.timeIntervalSince(last)))"
                }
                report.candidates.append(c)
            }
            let snapshots = device.appendingPathComponent("snapshots")
            let snapSpec = CandidateSpec(
                id: "avd-snapshots:\(device.path)", title: "\(display) 빠른 부팅 스냅샷", category: .androidEmulator,
                ruleID: "dev.android.avdSnapshots", risk: .review,
                riskReason: "저장된 실행 상태 — 다음 실행은 처음부터 부팅(조금 느림)",
                impact: "기기 안의 앱·데이터는 그대로입니다.", regenerable: true, guards: [running],
                minimumSize: 100 * 1024 * 1024)
            if let c = ctx.makeCandidate(at: snapshots, root: android, spec: snapSpec) { report.candidates.append(c) }
        }

        // System images: <sdk>/system-images/<api>/<tag>/<abi>
        let images = ctx.url("Library/Android/sdk/system-images")
        let anyEmulator = ProcessGuard.process("qemu-system-aarch64", "Android 에뮬레이터")
        for api in ctx.children(of: images) ?? [] where ctx.isDirectory(api) {
            for tag in ctx.children(of: api) ?? [] where ctx.isDirectory(tag) {
                for abi in ctx.children(of: tag) ?? [] where ctx.isDirectory(abi) {
                    let rel = "system-images/\(api.lastPathComponent)/\(tag.lastPathComponent)/\(abi.lastPathComponent)"
                    guard !imagesInUse.contains(rel) else { continue }
                    let spec = CandidateSpec(
                        title: "시스템 이미지 \(api.lastPathComponent) · \(tag.lastPathComponent)", category: .androidEmulator,
                        ruleID: "dev.android.systemImage", risk: .review,
                        riskReason: "어느 에뮬레이터도 쓰지 않는 시스템 이미지",
                        impact: "이 이미지로 에뮬레이터를 만들 때 SDK Manager가 다시 내려받습니다.",
                        regenerable: true, guards: [anyEmulator] + DeveloperGuards.androidStudio,
                        minimumSize: 50 * 1024 * 1024)
                    if let c = ctx.makeCandidate(at: abi, root: images, spec: spec) { report.candidates.append(c) }
                }
            }
        }
    }

    static func iniValues(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// "system-images/android-37.1/google_apis/arm64-v8a/" → without the trailing slash.
    static func normalizedImage(_ value: String) -> String {
        var v = value.replacingOccurrences(of: "\\", with: "/")
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    struct ProjectUsage: Equatable {
        var gradle: Set<String> = []
        var ndk: Set<String> = []
    }

    /// Gradle versions from `gradle-wrapper.properties` and NDK versions from
    /// `ndkVersion` in build files (React Native's default included), looked up a
    /// few levels deep in each project.
    static func projectUsage(_ projects: [String]) -> ProjectUsage {
        var usage = ProjectUsage()
        let fm = FileManager.default
        let skipped: Set<String> = ["node_modules", "Pods", "build", ".git", ".gradle", "DerivedData", ".build"]
        func scanFile(_ path: String) {
            let name = (path as NSString).lastPathComponent
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            if name == "gradle-wrapper.properties" {
                for line in text.split(separator: "\n") where line.contains("distributionUrl") {
                    let file = line.split(separator: "/").last.map(String.init) ?? ""
                    if let v = version(fromDistribution: file.replacingOccurrences(of: ".zip", with: "")) { usage.gradle.insert(v) }
                }
            } else {
                for line in text.split(separator: "\n") where line.contains("ndkVersion") {
                    if let v = line.split(whereSeparator: { "\"'= :".contains($0) }).last.map(String.init),
                       v.first?.isNumber == true, v.contains(".") { usage.ndk.insert(v) }
                }
            }
        }
        func visit(_ dir: String, depth: Int) {
            guard depth <= 4, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names {
                let path = dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if !skipped.contains(name), !name.hasPrefix(".") || name == ".expo" { visit(path, depth: depth + 1) }
                } else if name == "gradle-wrapper.properties" || name.hasSuffix(".gradle") || name.hasSuffix(".gradle.kts")
                            || name == "libs.versions.toml" || name == "gradle.properties" {
                    scanFile(path)
                }
            }
        }
        for project in projects {
            visit(project, depth: 0)
            // React Native sets the NDK in its own version catalog.
            for rn in ["node_modules/react-native/gradle/libs.versions.toml", "mobile/node_modules/react-native/gradle/libs.versions.toml"] {
                scanFile(project + "/" + rn)
            }
        }
        return usage
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
