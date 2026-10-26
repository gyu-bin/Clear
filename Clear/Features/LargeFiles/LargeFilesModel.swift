import Foundation

@MainActor
@Observable
final class LargeFilesModel {
    enum AgeFilter: Int, CaseIterable, Identifiable {
        case any = 0, sixMonths = 182, oneYear = 365, twoYears = 730
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .any: "전체"
            case .sixMonths: "6개월 이상 안 씀"
            case .oneYear: "1년 이상 안 씀"
            case .twoYears: "2년 이상 안 씀"
            }
        }
    }

    weak var environment: AppModel?
    var state: LoadState<LargeFileScanResult> = .idle
    var thresholdMB = 100
    var type: FileTypeGroup?
    var age: AgeFilter = .any
    var includeHidden = true
    var search = ""
    var checked: Set<String> = []
    var focused: String?

    private var task: Task<Void, Never>?

    /// The home folder becomes an allowed root only while results exist; every
    /// candidate is still re-validated and moved to the Trash, never deleted.
    var activeRoots: [URL] { state.value.map { [URL(fileURLWithPath: $0.root)] } ?? [] }

    var visibleItems: [LargeFileItem] {
        guard let items = state.value?.items else { return [] }
        let minimum = Int64(thresholdMB) * 1024 * 1024
        let cutoff = Date().addingTimeInterval(-Double(age.rawValue) * 86_400)
        return items.filter { item in
            item.allocatedSize >= minimum
                && (type == nil || item.type == type)
                && (age == .any || item.lastUsed < cutoff)
                && (includeHidden || !item.isHidden)
                && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                    || item.folder.localizedCaseInsensitiveContains(search))
        }
    }

    @discardableResult
    func scan() -> Task<Void, Never>? {
        guard let environment else { return nil }
        task?.cancel()
        checked.removeAll()
        focused = nil
        state = .loading(ScanProgress(phase: "큰 파일 찾는 중"))
        let progress = environment.progressHandler { [weak self] p in if self?.state.isLoading == true { self?.state = .loading(p) } }
        let home = PathUtilities.realHomeDirectory
        task = Task { [weak self] in
            do {
                let result = try await runOffMain { try LargeFileScanner().scan(home: home, progress: progress) }
                guard !Task.isCancelled, let self else { return }
                // Defense in depth: never list what the safety policy protects.
                let policy = environment.makePolicy()
                let visible = result.items.filter { policy.protectionReason(for: $0.path) == nil }
                self.state = .loaded(LargeFileScanResult(root: result.root, items: visible, scannedFiles: result.scannedFiles,
                                                         skippedCloudOnly: result.skippedCloudOnly, restricted: result.restricted), Date())
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
        return task
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }

    func requestCleanup() {
        guard let environment, let result = state.value else { return }
        let root = URL(fileURLWithPath: result.root)
        let selected = result.items.filter { checked.contains($0.id) }
        let candidates = selected.map { item in
            CleanupCandidate(
                id: "large:\(item.path)", title: item.name, subtitle: PathUtilities.abbreviated(item.path),
                category: .largeFile, ruleID: "largeFiles", risk: .manual,
                riskReason: item.lastOpened.map { "마지막으로 연 날짜 \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? "열어 본 기록 없음 · 수정 \(item.modified.formatted(date: .abbreviated, time: .omitted))",
                impact: "휴지통으로 이동합니다. 휴지통을 비우기 전까지 복구할 수 있습니다.",
                regenerable: false,
                size: SizeInfo(logical: item.logicalSize, allocated: item.allocatedSize, fileCount: 1, newestModification: item.modified),
                lastModified: item.modified,
                target: .path(PathTarget(url: URL(fileURLWithPath: item.path), identity: item.identity,
                                         allowedRoot: root, toleratesContentChanges: false, scannedAt: state.date ?? Date())),
                guards: [], preferredMethod: .trash, allowsPermanentRemoval: false)
        }
        environment.cleanup.review(title: "대용량 파일 정리", candidates: candidates)
    }

    func didFinishCleanup(_ done: Set<String>) {
        let removed = Set(done.filter { $0.hasPrefix("large:") }.map { String($0.dropFirst(6)) })
        guard !removed.isEmpty, case .loaded(let r, let d) = state else { return }
        checked.subtract(removed)
        state = .loaded(LargeFileScanResult(root: r.root, items: r.items.filter { !removed.contains($0.path) },
                                            scannedFiles: r.scannedFiles, skippedCloudOnly: r.skippedCloudOnly,
                                            restricted: r.restricted), d)
    }
}
