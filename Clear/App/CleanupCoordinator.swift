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
        self.preflight = preflight
        phase = plan.isEmpty ? .message("정리할 수 있는 항목이 없습니다. 보호 대상이거나 이미 정리된 항목만 선택되었습니다.") : .reviewing(plan)
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
