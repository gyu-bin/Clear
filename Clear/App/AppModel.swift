import AppKit
import Foundation
import os

/// Application state and service container (dependency injection root).
@MainActor
@Observable
final class AppModel {
    let settingsStore: SettingsStore
    let history: HistoryStore
    let cleanup = CleanupCoordinator()
    let diskExplorer = DiskExplorerModel()
    let applications = ApplicationsModel()
    let duplicates = DuplicatesModel()
    let freeSpace = FreeSpaceHistory()

    let fileSystem: FileSystemOperating
    let processInspector: ProcessInspecting
    let commandRunner: CommandRunning
    let volumeService = VolumeService()
    let isRunningTests: Bool

    var selection: SidebarItem? = .overview
    /// Set by the main window so AppKit code (menu bar, Dock reopen) can show it again.
    var openMainWindow: (() -> Void)?
    var volume: VolumeInfo?
    var volumeError: String?
    var storage: LoadState<StorageBreakdown> = .idle
    var general: LoadState<GeneralScanReport> = .idle
    var developer: LoadState<[ToolReport]> = .idle
    var ai: LoadState<[ToolReport]> = .idle
    var projects: [String: LoadState<ProjectReport>] = [:]
    /// Size of `~/.Trash`; nil when unknown (no Full Disk Access).
    private(set) var trashBytes: Int64?
    private var trashMeasuredAt: Date?

    var generalSelection: Set<String> = []
    var developerSelection: Set<String> = []
    var aiSelection: Set<String> = []
    var projectSelection: Set<String> = []

    private(set) var isScanningMac = false
    /// Re-checked whenever the app becomes active (the user may have just granted it).
    private(set) var hasFullDiskAccess = AppModel.checkFullDiskAccess()
    private var activationObserver: NSObjectProtocol?
    private var volumeTicker: Task<Void, Never>?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var monitor: BackgroundMonitor?
    private static let log = Logger(subsystem: "com.mungyubin.clear", category: "app")

    /// Results older than this are rescanned before Smart Clean.
    let freshness: TimeInterval = 10 * 60

    init(settingsStore: SettingsStore = SettingsStore(),
         history: HistoryStore = HistoryStore(),
         fileSystem: FileSystemOperating = LocalFileSystem(),
         processInspector: ProcessInspecting = ProcessInspector(),
         commandRunner: CommandRunning = CommandRunner()) {
        self.settingsStore = settingsStore
        self.history = history
        self.fileSystem = fileSystem
        self.processInspector = processInspector
        self.commandRunner = commandRunner
        self.isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

        cleanup.makeExecutor = { [unowned self] in self.makeExecutor() }
        cleanup.preferTrash = { [unowned self] in self.settings.preferTrash }
        cleanup.processes = processInspector
        cleanup.onFinished = { [unowned self] report in self.didFinishCleanup(report) }

        diskExplorer.environment = self
        applications.environment = self
        duplicates.environment = self
        history.prune(retentionDays: settingsStore.settings.historyRetentionDays)
        refreshVolume()
        if !isRunningTests {
            monitor = BackgroundMonitor(model: self)
            monitor?.start()
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions()
                self?.refreshVolume()
                self?.refreshTrash()
            }
        }
        if !isRunningTests {
            startVolumeTicker()
            refreshTrash()
        }
    }

    /// Keeps free space current. Reading volume capacity is a single cheap
    /// `URLResourceValues` query (no file walking): every 5 s while Clear is
    /// active, every 60 s in the background.
    private func startVolumeTicker() {
        volumeTicker?.cancel()
        volumeTicker = Task { @MainActor [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let interval: TimeInterval = (NSApp?.isActive ?? false) ? 5 : 60
                if Date().timeIntervalSince(last) >= interval {
                    self.refreshVolume()
                    last = Date()
                }
            }
        }
    }

    // MARK: Permissions

    /// Full Disk Access cannot be queried directly; reading a protected folder that
    /// every account has is the standard probe. Reading does not trigger a prompt.
    static func checkFullDiskAccess() -> Bool {
        let home = PathUtilities.realHomeDirectory
        for probe in [".Trash", "Library/Safari", "Library/Containers/com.apple.stocks"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(probe).path)) != nil { return true }
        }
        return false
    }

    func refreshPermissions() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Trash

    /// Lists the Trash and opens the normal confirmation flow. Nothing is removed
    /// until the user confirms (with an extra acknowledgement, since it is permanent).
    func emptyTrash() {
        guard !cleanup.isRunning else { return }
        Task { @MainActor in
            let ctx = await makeContext()
            do {
                let items = try await runOffMain { try TrashScanner().candidates(ctx) }
                if items.isEmpty {
                    cleanup.showMessage("휴지통이 비어 있습니다.")
                } else {
                    cleanup.review(title: "휴지통 비우기", candidates: items)
                }
            } catch {
                cleanup.showMessage("휴지통을 읽을 수 없습니다. 시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근에서 Clear를 허용한 뒤 다시 시도하세요.")
            }
        }
    }

    /// Measures `~/.Trash` off the main thread (at most once a minute unless forced).
    func refreshTrash(force: Bool = false) {
        if !force, let at = trashMeasuredAt, Date().timeIntervalSince(at) < 60 { return }
        trashMeasuredAt = Date()
        Task { @MainActor in
            let path = PathUtilities.realHomeDirectory.appendingPathComponent(".Trash").path
            let size = await runOffMain { () -> Int64? in
                guard let s = try? DirectorySizer().measure(path: path), s.inaccessibleCount == 0 else { return nil }
                return s.allocated
            }
            trashBytes = size
        }
    }

    private func refreshTrashSize() {
        refreshTrash(force: true)
        guard case .loaded(var report, let date) = general else { return }
        let trash = PathUtilities.realHomeDirectory.appendingPathComponent(".Trash").path
        if let size = try? DirectorySizer().measure(path: trash), size.inaccessibleCount == 0 {
            report.trashSize = size
            general = .loaded(report, date)
        }
    }

    var settings: AppSettings { settingsStore.settings }

    // MARK: Services

    func makePolicy() -> SafetyPolicy {
        var policy = SafetyPolicy(exclusions: settings.excludedPaths)
        policy.addAllowedRoots(settings.projectFolders.map { URL(fileURLWithPath: $0.path) })
        policy.addAllowedRoots(duplicates.activeRoots)
        return policy
    }

    func makeContext(progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async -> ScanContext {
        let snapshot = await processInspector.snapshot()
        return ScanContext(policy: makePolicy(), processes: snapshot, commandRunner: commandRunner,
                           fileSystem: fileSystem, progress: progress)
    }

    func makeExecutor() -> CleanupExecutor {
        let validator = CleanupValidator(policy: makePolicy(), fileSystem: fileSystem, commandRunner: commandRunner)
        return CleanupExecutor(validator: validator, fileSystem: fileSystem, processes: processInspector,
                               commandRunner: commandRunner, volumes: volumeService)
    }

    /// Converts background progress callbacks into throttled main-actor updates.
    func progressHandler(_ apply: @escaping @MainActor (ScanProgress) -> Void) -> @Sendable (ScanProgress) -> Void {
        let throttle = ProgressThrottle(interval: 0.1)
        return { progress in
            guard throttle.shouldEmit() else { return }
            Task { @MainActor in apply(progress) }
        }
    }

    // MARK: Task bookkeeping

    @discardableResult
    func run(_ key: String, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        tasks[key]?.cancel()
        let task = Task { @MainActor in
            await operation()
        }
        tasks[key] = task
        return task
    }

    func cancel(_ key: String) { tasks[key]?.cancel() }

    func isRunning(_ key: String) -> Bool { tasks[key] != nil }

    private func finish(_ key: String, _ task: Task<Void, Never>) async {
        await task.value
        if tasks[key] == task { tasks[key] = nil }
    }

    // MARK: Volume

    func refreshVolume() {
        do {
            let fresh = try volumeService.volume()
            // Assign only on change so observing views do not re-render needlessly.
            if !isRunningTests { freeSpace.record(available: fresh.availableForImportantUsage, total: fresh.totalCapacity) }
            if fresh != volume {
                volume = fresh
                Self.log.debug("free space now \(fresh.availableForImportantUsage, privacy: .public)")
            }
            volumeError = nil
        } catch {
            volumeError = error.localizedDescription
        }
    }

    // MARK: Scans

    func scanMac() {
        guard !isScanningMac else { return }
        isScanningMac = true
        refreshVolume()
        Task { @MainActor in
            var started: [(String, Task<Void, Never>)] = [("storage", scanStorage()), ("general", scanGeneral())]
            if settings.developerModeEnabled { started.append(("developer", scanDeveloper())) }
            if settings.aiToolsEnabled { started.append(("ai", scanAI())) }
            for (_, task) in started { await task.value }
            isScanningMac = false
            refreshVolume()
            updateLastScanSummary()
        }
    }

    func cancelMacScan() {
        for key in ["storage", "general", "developer", "ai"] { cancel(key) }
    }

    @discardableResult
    func scanStorage() -> Task<Void, Never> {
        let task = run("storage") { [self] in
            storage = .loading(ScanProgress(phase: "저장공간 분류 준비 중"))
            refreshVolume()
            guard let volume else {
                storage = .failed(volumeError ?? "볼륨 정보를 읽지 못했습니다")
                return
            }
            let categories = StorageBreakdownScanner.categories(home: PathUtilities.realHomeDirectory,
                                                                personalFolders: settings.overviewFolders)
            let progress = progressHandler { [weak self] p in if self?.storage.isLoading == true { self?.storage = .loading(p) } }
            let result = await StorageBreakdownScanner().scan(categories: categories, volume: volume, progress: progress)
            if Task.isCancelled { storage = .idle; return }
            storage = .loaded(result, Date())
            settingsStore.lastBreakdown = StoredBreakdown(
                date: Date(),
                categories: result.segments.map { .init(id: $0.id, title: $0.title, bytes: $0.bytes) },
                unattributed: result.unattributed)
        }
        Task { await finish("storage", task) }
        return task
    }

    @discardableResult
    func scanGeneral() -> Task<Void, Never> {
        let task = run("general") { [self] in
            general = .loading(ScanProgress(phase: "스캔 준비 중"))
            let ctx = await makeContext(progress: progressHandler { [weak self] p in
                if self?.general.isLoading == true { self?.general = .loading(p) }
            })
            do {
                let names = await runOffMain { AppCatalog.nameIndex() }
                let report = try await GeneralCleanupScanner().scan(ctx, appNames: names)
                general = .loaded(report, Date())
                generalSelection = Set(report.candidates.filter(\.isDefaultSelected).map(\.id))
            } catch is CancellationError {
                general = .idle
            } catch {
                general = .failed(error.localizedDescription)
            }
            updateLastScanSummary()
        }
        Task { await finish("general", task) }
        return task
    }

    static func developerAdapters() -> [any ToolAdapter] {
        [XcodeAdapter(), NodeAdapter(), ExpoAdapter(), GradleAdapter(), HomebrewAdapter(), DockerAdapter()]
    }

    @discardableResult
    func scanDeveloper() -> Task<Void, Never> {
        let task = run("developer") { [self] in
            developer = .loading(ScanProgress(phase: "개발 도구 감지 중"))
            let ctx = await makeContext(progress: progressHandler { [weak self] p in
                if self?.developer.isLoading == true { self?.developer = .loading(p) }
            })
            let reports = await Self.scanAdapters(Self.developerAdapters(), ctx: ctx)
            if Task.isCancelled { developer = .idle; return }
            developer = .loaded(reports, Date())
            developerSelection = Set(reports.flatMap(\.candidates).filter(\.isDefaultSelected).map(\.id))
            updateLastScanSummary()
        }
        Task { await finish("developer", task) }
        return task
    }

    @discardableResult
    func scanAI() -> Task<Void, Never> {
        let task = run("ai") { [self] in
            ai = .loading(ScanProgress(phase: "AI 도구 감지 중"))
            let ctx = await makeContext(progress: progressHandler { [weak self] p in
                if self?.ai.isLoading == true { self?.ai = .loading(p) }
            })
            let reports = await Self.scanAdapters(AIToolAdapters.all(), ctx: ctx)
            if Task.isCancelled { ai = .idle; return }
            ai = .loaded(reports, Date())
            aiSelection = Set(reports.flatMap(\.candidates).filter(\.isDefaultSelected).map(\.id))
            updateLastScanSummary()
        }
        Task { await finish("ai", task) }
        return task
    }

    /// Adapters run one after another: they share the hard-link-aware sizer, and
    /// running them serially keeps disk I/O polite.
    nonisolated static func scanAdapters(_ adapters: [any ToolAdapter], ctx: ScanContext) async -> [ToolReport] {
        var reports: [ToolReport] = []
        for adapter in adapters {
            if Task.isCancelled { break }
            reports.append(await adapter.scan(ctx))
        }
        return reports.sorted { a, b in
            if a.installed != b.installed { return a.installed }
            return a.measuredBytes > b.measuredBytes
        }
    }

    func analyzeProject(_ folder: ProjectFolder) {
        let key = "project:\(folder.path)"
        let task = run(key) { [self] in
            projects[folder.path] = .loading(ScanProgress(phase: "\(folder.name) 분석 중"))
            guard FileManager.default.fileExists(atPath: folder.path) else {
                projects[folder.path] = .failed("폴더를 찾을 수 없습니다. 이동되었거나 삭제되었을 수 있습니다.")
                return
            }
            let ctx = await makeContext(progress: progressHandler { [weak self] p in
                if self?.projects[folder.path]?.isLoading == true { self?.projects[folder.path] = .loading(p) }
            })
            let report = await ProjectAnalyzer().analyze(projectAt: URL(fileURLWithPath: folder.path), ctx: ctx)
            projects[folder.path] = Task.isCancelled ? .idle : .loaded(report, Date())
        }
        Task { await finish(key, task) }
    }

    func analyzeAllProjects() {
        for folder in settingsStore.resolvedProjectFolders() { analyzeProject(folder) }
    }

    // MARK: Aggregates

    var allScanCandidates: [CleanupCandidate] {
        (general.value?.candidates ?? []) + (developer.value?.flatMap(\.candidates) ?? []) + (ai.value?.flatMap(\.candidates) ?? [])
    }

    /// SAFE path items only — what one-click Smart Clean is allowed to touch.
    var smartCleanCandidates: [CleanupCandidate] {
        var items = general.value?.candidates.filter(\.isDefaultSelected) ?? []
        if settings.developerModeEnabled {
            items += developer.value?.flatMap(\.candidates).filter { $0.isDefaultSelected && $0.target.pathTarget != nil } ?? []
        }
        if settings.aiToolsEnabled {
            items += ai.value?.flatMap(\.candidates).filter { $0.isDefaultSelected && $0.target.pathTarget != nil } ?? []
        }
        return items
    }

    func cleanableBytes(_ candidates: [CleanupCandidate]) -> Int64 {
        candidates.filter { $0.risk != .blocked }.reduce(0) { $0 + $1.estimatedBytes }
    }

    var hasFreshScan: Bool {
        guard let date = general.date else { return false }
        return Date().timeIntervalSince(date) < freshness
    }

    /// One-click cleanup of SAFE items. Rescans first when results are missing or stale.
    func smartClean() {
        guard !cleanup.isRunning else { return }
        Task { @MainActor in
            if !hasFreshScan {
                var pending = [scanGeneral()]
                if settings.developerModeEnabled { pending.append(scanDeveloper()) }
                if settings.aiToolsEnabled { pending.append(scanAI()) }
                for t in pending { await t.value }
            }
            let items = smartCleanCandidates
            if items.isEmpty {
                cleanup.showMessage("지금은 안전하게 자동 정리할 항목이 없습니다. 스마트 청소 화면에서 확인이 필요한 항목을 직접 검토할 수 있습니다.")
            } else {
                cleanup.review(title: "스마트 정리", candidates: items)
            }
        }
    }

    // MARK: After cleanup

    private func didFinishCleanup(_ report: CleanupReport) {
        history.append(report, retentionDays: settings.historyRetentionDays)
        let done = Set(report.results.filter { $0.status.isSuccess }.map(\.candidateID))
        if case .loaded(var r, let d) = general {
            r.candidates.removeAll { done.contains($0.id) }
            general = .loaded(r, d)
        }
        if case .loaded(var reports, let d) = developer {
            for i in reports.indices { reports[i].candidates.removeAll { done.contains($0.id) } }
            developer = .loaded(reports, d)
        }
        if case .loaded(var reports, let d) = ai {
            for i in reports.indices { reports[i].candidates.removeAll { done.contains($0.id) } }
            ai = .loaded(reports, d)
        }
        for (key, state) in projects {
            if case .loaded(let r, let d) = state, r.candidates.contains(where: { done.contains($0.id) }) {
                projects[key] = .loaded(r, d)
                if let folder = settings.projectFolders.first(where: { $0.path == key }) { analyzeProject(folder) }
            }
        }
        generalSelection.subtract(done)
        developerSelection.subtract(done)
        aiSelection.subtract(done)
        projectSelection.subtract(done)
        if report.results.contains(where: { $0.category == .trash }) || report.trashedBytes > 0 { refreshTrashSize() }
        applications.didFinishCleanup(done)
        duplicates.didFinishCleanup(done)
        refreshVolume()
        updateLastScanSummary()
    }

    func updateLastScanSummary() {
        guard general.value != nil, let volume else { return }
        let all = allScanCandidates
        settingsStore.lastScan = LastScanSummary(
            date: general.date ?? Date(),
            cleanableBytes: cleanableBytes(all),
            safeBytes: smartCleanCandidates.reduce(0) { $0 + $1.estimatedBytes },
            freeBytes: volume.availableForImportantUsage,
            totalBytes: volume.totalCapacity)
    }

    // MARK: Appearance

    func applyTheme() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}
