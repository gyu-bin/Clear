import Darwin
import Foundation

@MainActor
@Observable
final class StartupItemsModel {
    weak var environment: AppModel?
    var state: LoadState<[StartupItem]> = .idle
    var scope: StartupItem.Scope?
    var search = ""
    var selection: String?
    var busy: Set<String> = []
    var lastError: String?

    var visible: [StartupItem] {
        (state.value ?? []).filter {
            (scope == nil || $0.scope == scope)
                && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                    || $0.label.localizedCaseInsensitiveContains(search))
        }
    }

    func load() {
        guard let environment else { return }
        if state.value == nil { state = .loading(ScanProgress(phase: "시작 항목 확인 중")) }
        let scanner = StartupScanner(home: PathUtilities.realHomeDirectory, runner: environment.commandRunner)
        Task { [weak self] in
            let items = await scanner.scan()
            self?.state = .loaded(items, Date())
        }
    }

    /// Turns an agent off (or on) for this user with `launchctl disable/enable` —
    /// the same per-user override System Settings uses. Also stops/starts it now.
    func setEnabled(_ item: StartupItem, _ enabled: Bool) {
        guard let environment, item.canToggle, StartupItem.isValidLabel(item.label) else { return }
        let runner = environment.commandRunner
        let domain = "gui/\(getuid())"
        busy.insert(item.id)
        lastError = nil
        Task { [weak self] in
            do {
                if enabled {
                    let r = try await runner.run(.launchctl, ["enable", "\(domain)/\(item.label)"], timeout: 15)
                    if !r.succeeded { throw CommandError.launchFailed(r.stderr) }
                    if item.runAtLoad || item.keepAlive {
                        _ = try? await runner.run(.launchctl, ["bootstrap", domain, item.plistPath], timeout: 15)
                    }
                } else {
                    let r = try await runner.run(.launchctl, ["disable", "\(domain)/\(item.label)"], timeout: 15)
                    if !r.succeeded { throw CommandError.launchFailed(r.stderr) }
                    _ = try? await runner.run(.launchctl, ["bootout", "\(domain)/\(item.label)"], timeout: 15)
                }
            } catch {
                self?.lastError = "\(item.displayName): \(error.localizedDescription)"
            }
            self?.busy.remove(item.id)
            self?.load()
        }
    }

    /// Removing goes through the normal confirmation and moves the plist to the Trash.
    func remove(_ item: StartupItem) {
        guard let environment, item.canRemove else { return }
        let root = PathUtilities.realHomeDirectory.appendingPathComponent("Library/LaunchAgents")
        let candidate = CleanupCandidate(
            id: "startup:\(item.plistPath)", title: item.displayName, subtitle: PathUtilities.abbreviated(item.plistPath),
            category: .startupItem, ruleID: "startup.remove", risk: .manual,
            riskReason: item.isBroken ? "실행할 프로그램이 없는 항목" : "로그인할 때 자동으로 실행되는 항목",
            impact: "휴지통으로 이동하고 실행을 멈춥니다. 앱이 다시 등록할 수도 있습니다. 휴지통에서 되돌릴 수 있습니다.",
            regenerable: false,
            size: SizeInfo(logical: item.identity.logicalSize, allocated: item.identity.allocatedSize, fileCount: 1),
            lastModified: item.modified,
            target: .path(PathTarget(url: URL(fileURLWithPath: PathUtilities.canonicalPath(item.plistPath) ?? item.plistPath),
                                     identity: item.identity,
                                     allowedRoot: URL(fileURLWithPath: PathUtilities.canonicalPath(root.path) ?? root.path),
                                     toleratesContentChanges: false, scannedAt: state.date ?? Date())),
            guards: [], preferredMethod: .trash, allowsPermanentRemoval: false)
        environment.cleanup.review(title: "시작 항목 삭제", candidates: [candidate])
    }

    /// After a removal, stop the job that was loaded from the trashed plist.
    func didFinishCleanup(_ done: Set<String>) {
        let removed = done.filter { $0.hasPrefix("startup:") }
        guard !removed.isEmpty, let environment else { return }
        let labels = (state.value ?? []).filter { removed.contains("startup:\($0.plistPath)") }.map(\.label)
        let runner = environment.commandRunner
        let domain = "gui/\(getuid())"
        Task { [weak self] in
            for label in labels where StartupItem.isValidLabel(label) {
                _ = try? await runner.run(.launchctl, ["bootout", "\(domain)/\(label)"], timeout: 15)
            }
            self?.load()
        }
    }
}
