import Foundation

enum DeveloperGuards {
    static let xcode: [ProcessGuard] = [
        .app("com.apple.dt.Xcode", "Xcode"), .process("xcodebuild"), .process("XCBBuildService", "Xcode 빌드 서비스"),
        .process("SWBBuildService", "Xcode 빌드 서비스"), .process("swift-build"), .process("swift-frontend", "Swift 컴파일러"),
    ]
    static let simulator: [ProcessGuard] = [.app("com.apple.iphonesimulator", "Simulator")]
    static let npm: [ProcessGuard] = [.commandLine("npm-cli.js", "npm"), .commandLine("npx-cli.js", "npx"), .process("npm")]
    static let yarn: [ProcessGuard] = [.commandLine("yarn", "Yarn")]
    static let pnpm: [ProcessGuard] = [.commandLine("pnpm", "pnpm"), .process("pnpm")]
    static let gradle: [ProcessGuard] = [.commandLine("org.gradle", "Gradle 데몬"), .commandLine("gradlewrappermain", "Gradle")]
    static let androidStudio: [ProcessGuard] = [.app("com.google.android.studio", "Android Studio")]
    static let metro: [ProcessGuard] = [.commandLine("metro", "Metro"), .commandLine("expo start", "Expo 개발 서버"),
                                        .commandLine("expo/bin/cli", "Expo CLI"), .commandLine("react-native start", "React Native")]
    static let expo: [ProcessGuard] = [.commandLine("expo/bin/cli", "Expo CLI"), .commandLine("eas-cli", "EAS CLI")]
    static let cocoapods: [ProcessGuard] = [.commandLine("bin/pod", "CocoaPods")]
    static let homebrew: [ProcessGuard] = [.commandLine("library/homebrew", "Homebrew")]
}

struct XcodeAdapter: ToolAdapter {
    let id = "xcode"
    let name = "Xcode"
    let symbol = "hammer.fill"
    let kind = ToolKind.developer
    var deviceSupportAge: TimeInterval = 180 * 24 * 3600

    func scan(_ ctx: ScanContext) async -> ToolReport {
        let devRoot = ctx.url("Library/Developer")
        let appPath = ["/Applications/Xcode.app", "/Applications/Xcode-beta.app"].first { ctx.exists(URL(fileURLWithPath: $0)) }
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind,
                                installed: appPath != nil || ctx.exists(devRoot.appendingPathComponent("Xcode")),
                                version: appPath.flatMap { ctx.bundleVersion(ofAppAt: $0) })
        guard report.installed else { return report }
        report.runningProcesses = ctx.processes.runningGuards(DeveloperGuards.xcode + DeveloperGuards.simulator)
        let guards = DeveloperGuards.xcode

        // DerivedData: one candidate per project.
        let derived = devRoot.appendingPathComponent("Xcode/DerivedData")
        ctx.progress(ScanProgress(phase: "DerivedData 분석 중"))
        if let projects = ctx.children(of: derived) {
            for folder in projects where ctx.isDirectory(folder) {
                let name = folder.lastPathComponent
                let workspace = Self.workspacePath(in: folder)
                let missing = workspace.map { !FileManager.default.fileExists(atPath: $0) } ?? false
                let title = name == "ModuleCache.noindex" ? "모듈 캐시"
                    : name.split(separator: "-").dropLast().joined(separator: "-").nilIfEmpty ?? name
                var spec = CandidateSpec(
                    title: "\(title) DerivedData", subtitle: workspace.map { "원본: " + PathUtilities.abbreviated($0) },
                    category: .xcode, ruleID: "dev.xcode.derivedData",
                    risk: .safe, riskReason: missing ? "원본 프로젝트가 더 이상 없음" : "Xcode가 다시 빌드하면 재생성",
                    impact: "다음 빌드가 처음부터 다시 빌드되어 오래 걸립니다. 인덱스도 다시 만들어집니다.",
                    regenerable: true, guards: guards, minimumSize: 1024 * 1024)
                if name == "ModuleCache.noindex" { spec.riskReason = "Clang/Swift 모듈 캐시 — 자동 재생성" }
                if let c = ctx.makeCandidate(at: folder, root: devRoot, spec: spec) { report.candidates.append(c) }
            }
        } else if ctx.exists(derived) {
            report.notes.append("DerivedData 폴더에 접근할 수 없습니다.")
        }

        // Xcode caches outside DerivedData.
        let caches = ctx.url("Library/Caches")
        for (folder, title) in [("com.apple.dt.Xcode", "Xcode 캐시"), ("com.apple.dt.xcodebuild", "xcodebuild 캐시"),
                                ("org.swift.swiftpm", "Swift Package 캐시")] {
            let spec = CandidateSpec(title: title, category: folder == "org.swift.swiftpm" ? .swiftPackages : .xcode,
                                     ruleID: "dev.xcode.cache", risk: .safe, riskReason: "Xcode가 다시 만드는 캐시",
                                     impact: folder == "org.swift.swiftpm" ? "패키지를 다시 내려받습니다." : "다시 만들어집니다.",
                                     regenerable: true, guards: guards, minimumSize: 1024 * 1024)
            if let c = ctx.makeCandidate(at: caches.appendingPathComponent(folder), root: caches, spec: spec) {
                report.candidates.append(c)
            }
        }

        // Device support: per OS version, older ones flagged.
        ctx.progress(ScanProgress(phase: "Device Support 분석 중"))
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let dir = devRoot.appendingPathComponent("Xcode/\(platform) DeviceSupport")
            for version in ctx.children(of: dir) ?? [] where ctx.isDirectory(version) {
                let spec = CandidateSpec(
                    title: "\(platform) \(version.lastPathComponent)", category: .xcode, ruleID: "dev.xcode.deviceSupport",
                    risk: .review, riskReason: "해당 OS 버전 기기를 연결해 디버깅할 때 필요",
                    impact: "해당 기기를 다시 연결하면 심볼을 다시 준비합니다(수 분 소요).",
                    regenerable: true, guards: guards, minimumSize: 10 * 1024 * 1024)
                guard var c = ctx.makeCandidate(at: version, root: devRoot, spec: spec) else { continue }
                if let newest = c.size.newestModification, ctx.scannedAt.timeIntervalSince(newest) > deviceSupportAge {
                    c.riskReason = "180일 넘게 사용하지 않은 Device Support"
                }
                report.candidates.append(c)
            }
        }

        for (rel, title, reason) in [
            ("Xcode/DeviceLogs", "기기 로그", "기기에서 가져온 로그"),
            ("XCTestDevices", "테스트용 복제 시뮬레이터", "병렬 테스트 시 다시 만들어지는 복제본"),
            ("XCPGDevices", "Playground 시뮬레이터", "Playground 실행 시 다시 만들어짐"),
            ("Xcode/UserData/Previews", "SwiftUI 미리보기 데이터", "미리보기 실행 시 다시 만들어짐"),
            ("CoreSimulator/Caches", "시뮬레이터 캐시", "시뮬레이터가 다시 만드는 dyld 캐시"),
        ] {
            let spec = CandidateSpec(title: title, category: rel.hasPrefix("CoreSimulator") ? .simulator : .xcode,
                                     ruleID: "dev.xcode.misc", risk: rel.hasPrefix("CoreSimulator") ? .safe : .review,
                                     riskReason: reason, impact: "필요할 때 다시 만들어집니다.", regenerable: true,
                                     guards: guards + DeveloperGuards.simulator, minimumSize: 5 * 1024 * 1024)
            if let c = ctx.makeCandidate(at: devRoot.appendingPathComponent(rel), root: devRoot, spec: spec) {
                report.candidates.append(c)
            }
        }

        if let loc = ctx.location(devRoot.appendingPathComponent("Xcode/Archives"), title: "Xcode 아카이브", role: .build,
                                  protected: true, note: "배포·디버깅에 필요할 수 있어 자동 삭제하지 않습니다. Xcode Organizer에서 관리하세요.") {
            report.locations.append(loc)
        }
        await scanSimulators(ctx, into: &report)
        report.locations.append(contentsOf: report.candidates.compactMap { c in
            c.path.map { ToolLocation(path: $0, title: c.title, role: .build, size: c.size, isProtected: false, note: nil) }
        })
        return report
    }

    static func workspacePath(in derivedFolder: URL) -> String? {
        let plist = derivedFolder.appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["WorkspacePath"] as? String
    }

    // MARK: Simulators (managed through `xcrun simctl`, never by deleting folders)

    struct SimDevice: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let dataPath: String?
        let availabilityError: String?
    }

    struct SimList: Decodable { let devices: [String: [SimDevice]] }

    static var udidPattern: Regex<Substring> { /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/ }

    private func scanSimulators(_ ctx: ScanContext, into report: inout ToolReport) async {
        ctx.progress(ScanProgress(phase: "시뮬레이터 목록 확인 중"))
        guard let result = try? await ctx.commandRunner.run(.xcrun, ["simctl", "list", "devices", "--json"], timeout: 30),
              result.succeeded, let list = try? JSONDecoder().decode(SimList.self, from: Data(result.stdout.utf8)) else {
            report.notes.append("시뮬레이터 목록을 가져오지 못했습니다(xcrun simctl).")
            return
        }
        var unavailableBytes: Int64 = 0
        var unavailableCount = 0
        for (runtime, devices) in list.devices {
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0"
            let runtimeName = runtime.split(separator: ".").last.map { last -> String in
                let parts = last.split(separator: "-")
                guard let platform = parts.first else { return String(last) }
                return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : String(platform)
            } ?? runtime
            for device in devices {
                guard device.udid.wholeMatch(of: Self.udidPattern) != nil else { continue }
                let deviceDir = device.dataPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                let size = deviceDir.flatMap { try? ctx.sizer.measure(path: $0.path) }
                if device.isAvailable == false {
                    unavailableCount += 1
                    unavailableBytes += size?.allocated ?? 0
                    continue
                }
                guard let size, size.allocated > 200 * 1024 * 1024 else { continue }
                let booted = device.state == "Booted"
                report.candidates.append(CleanupCandidate(
                    id: "simctl:\(device.udid)", title: "\(device.name) (\(runtimeName))",
                    subtitle: "xcrun simctl delete \(device.udid)", category: .simulator, ruleID: "dev.xcode.simulator",
                    risk: booted ? .blocked : .manual,
                    riskReason: booted ? "실행 중인 시뮬레이터"
                        : "시뮬레이터 기기와 설치된 앱·데이터가 모두 삭제됩니다"
                          + (size.newestModification.map { " · 마지막 사용 \(GeneralCleanupScanner.idleText(ctx.scannedAt.timeIntervalSince($0)))" } ?? ""),
                    impact: "기기를 다시 만들어야 하며 기기 안의 앱 데이터는 복구할 수 없습니다.",
                    regenerable: false, size: size, lastModified: size.newestModification,
                    target: .command(TrustedCommand(tool: .xcrun, arguments: ["simctl", "delete", device.udid])),
                    guards: DeveloperGuards.simulator, preferredMethod: .permanent, allowsPermanentRemoval: true,
                    warning: "시뮬레이터 안의 앱 데이터는 복구할 수 없습니다.",
                    runningGuards: ctx.processes.runningGuards(DeveloperGuards.simulator)))
            }
        }
        if unavailableCount > 0 {
            report.candidates.append(CleanupCandidate(
                id: "simctl:delete-unavailable", title: "사용할 수 없는 시뮬레이터 \(unavailableCount)개",
                subtitle: "xcrun simctl delete unavailable", category: .simulator, ruleID: "dev.xcode.simulator.unavailable",
                risk: .review, riskReason: "설치되지 않은 런타임용 기기 — Apple 공식 명령으로 제거",
                impact: "더 이상 실행할 수 없는 시뮬레이터 기기가 제거됩니다.", regenerable: false,
                size: SizeInfo(logical: unavailableBytes, allocated: unavailableBytes, fileCount: unavailableCount),
                lastModified: nil,
                target: .command(TrustedCommand(tool: .xcrun, arguments: ["simctl", "delete", "unavailable"])),
                guards: DeveloperGuards.simulator, preferredMethod: .permanent, allowsPermanentRemoval: true,
                runningGuards: ctx.processes.runningGuards(DeveloperGuards.simulator)))
        }
        if let loc = ctx.location(ctx.url("Library/Developer/CoreSimulator/Devices"), title: "시뮬레이터 기기",
                                  role: .simulator, protected: true, note: "simctl 명령으로만 제거합니다.") {
            report.locations.append(loc)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
