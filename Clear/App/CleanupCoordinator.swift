import AppKit
import Foundation

/// Drives the shared Confirm → Execute → Verify flow. No screen removes files
/// directly; every cleanup goes through `review` (plan + confirmation sheet) and
/// then `confirm`, which hands the plan to `CleanupExecutor`.
@MainActor
@Observable
final class CleanupCoordinator {
    enum Phase {
        case idle
        case reviewing(CleanupPlan)
        case running(CleanupPlan, CleanupProgress)
        case finished(CleanupReport)
        case message(String)
    }

    private(set) var phase: Phase = .idle
    /// Required for plans that contain MANUAL items or commands.
    var acknowledged = false
    var onFinished: (@MainActor (CleanupReport) -> Void)?

    /// Injected by `AppModel`: builds an executor with the current policy.
    var makeExecutor: (@MainActor () -> CleanupExecutor)?
    var preferTrash: @MainActor () -> Bool = { true }
    var processes: ProcessInspecting = ProcessInspector()

    /// Live check while the confirmation sheet is open: candidate id → running guard names.
    /// Those items would be skipped by the executor, so the sheet says so up front.
    private(set) var runningByItem: [String: [String]] = [:]
    private(set) var isQuittingApps = false
    private(set) var quitFailures: [String] = []

    private var task: Task<Void, Never>?
    /// Extra pre-flight check (e.g. duplicates must keep one copy per group).
    private var preflight: (@MainActor (CleanupPlan) -> String?)?

    init() {}

    var isPresented: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func review(title: String, candidates: [CleanupCandidate], preflight: (@MainActor (CleanupPlan) -> String?)? = nil) {
        guard !isRunning else { return }
        let plan = CleanupPlanner(preferTrash: preferTrash()).makePlan(title: title, selection: candidates)
        acknowledged = false
        quitFailures = []
        self.preflight = preflight
        runningByItem = Dictionary(uniqueKeysWithValues: plan.items.compactMap { item in
            item.candidate.runningGuards.isEmpty ? nil : (item.id, item.candidate.runningGuards)
        })
        phase = plan.isEmpty ? .message("정리할 수 있는 항목이 없습니다. 보호 대상이거나 이미 정리된 항목만 선택되었습니다.") : .reviewing(plan)
        Task { await refreshRunning() }
    }

    /// Items that will actually run (not blocked by a running app).
    func runnableCount(_ plan: CleanupPlan) -> Int {
        plan.items.filter { runningByItem[$0.id] == nil }.count
    }

    /// GUI apps (bundle-ID guards) that are running and blocking items in the plan.
    func blockingApps(_ plan: CleanupPlan) -> [NSRunningApplication] {
        var seen = Set<pid_t>()
        var apps: [NSRunningApplication] = []
        for item in plan.items where runningByItem[item.id] != nil {
            for g in item.candidate.guards where g.kind == .bundleID {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: g.value)
                where !app.isTerminated && seen.insert(app.processIdentifier).inserted {
                    apps.append(app)
                }
            }
        }
        return apps
    }

    func refreshRunning() async {
        guard case .reviewing(let plan) = phase else { return }
        let snapshot = await processes.snapshot()
        var map: [String: [String]] = [:]
        for item in plan.items {
            let running = snapshot.runningGuards(item.candidate.guards)
            if !running.isEmpty { map[item.id] = running }
        }
        runningByItem = map
    }

    /// Asks the blocking apps to quit normally (same as ⌘Q — they may show their own
    /// save prompts), waits briefly, then re-checks what is still running.
    func quitBlockingApps() {
        guard case .reviewing(let plan) = phase, !isQuittingApps else { return }
        let apps = blockingApps(plan)
        guard !apps.isEmpty else { return }
        isQuittingApps = true
        quitFailures = []
        for app in apps { app.terminate() }
        Task { @MainActor in
            for _ in 0..<40 {
                if apps.allSatisfy(\.isTerminated) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            quitFailures = apps.filter { !$0.isTerminated }.compactMap(\.localizedName)
            isQuittingApps = false
            await refreshRunning()
        }
    }

    func showMessage(_ text: String) {
        guard !isRunning else { return }
        phase = .message(text)
    }

    func confirm() {
        guard case .reviewing(let plan) = phase else { return }
        if plan.requiresExplicitAcknowledgement && !acknowledged { return }
        if let problem = preflight?(plan) {
            phase = .message(problem)
            return
        }
        guard let executor = makeExecutor?() else { return }
        phase = .running(plan, CleanupProgress(completed: 0, total: plan.items.count, currentTitle: ""))
        let onProgress: @Sendable (CleanupProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, case .running(let p, _) = self.phase else { return }
                self.phase = .running(p, progress)
            }
        }
        task = Task { [weak self] in
            let report = await executor.execute(plan, progress: onProgress)
            guard let self else { return }
            self.phase = .finished(report)
            self.onFinished?(report)
            self.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
    }
}
