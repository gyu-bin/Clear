import Foundation

@MainActor
@Observable
final class ApplicationsModel {
    weak var environment: AppModel?
    var apps: LoadState<[InstalledApp]> = .idle
    var sizes: [String: SizeInfo] = [:]
    var search = ""
    var selectedAppID: String?
    var related: [String: LoadState<[CleanupCandidate]>] = [:]
    var bundleCandidates: [String: CleanupCandidate] = [:]
    var relatedSelection: Set<String> = []
    var measuring = false

    private var loadTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?

    var selectedApp: InstalledApp? {
        apps.value?.first { $0.id == selectedAppID }
    }

    func load() {
        loadTask?.cancel()
        sizeTask?.cancel()
        apps = .loading(ScanProgress(phase: "설치된 앱 찾는 중"))
        loadTask = Task { [weak self] in
            let list = await runOffMain { AppInventory().listApps() }
            guard let self, !Task.isCancelled else { return }
            self.apps = .loaded(list, Date())
            self.measureSizes(list)
        }
    }

    /// Measures bundle sizes with limited parallelism, publishing results as they arrive.
    private func measureSizes(_ list: [InstalledApp]) {
        measuring = true
        sizeTask = Task { [weak self] in
            await withTaskGroup(of: (String, SizeInfo?).self) { group in
                var iterator = list.makeIterator()
                func addNext() {
                    guard let app = iterator.next() else { return }
                    group.addTask { (app.id, try? await runOffMain { try DirectorySizer().measure(path: app.info.path) }) }
                }
                for _ in 0..<4 { addNext() }
                while let (id, size) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let size { self?.sizes[id] = size }
                    addNext()
                }
            }
            self?.measuring = false
        }
    }

    func select(_ app: InstalledApp) {
        selectedAppID = app.id
        if related[app.id] == nil || related[app.id]?.error != nil { loadRelated(app) }
    }

    func loadRelated(_ app: InstalledApp) {
        guard let environment else { return }
        related[app.id] = .loading(ScanProgress(phase: "관련 파일 찾는 중"))
        Task { [weak self] in
            let ctx = await environment.makeContext()
            let inventory = AppInventory()
            let (bundle, files) = await runOffMain {
                (inventory.bundleCandidate(for: app, ctx: ctx), inventory.relatedFiles(for: app, ctx: ctx))
            }
            guard let self else { return }
            if let bundle { self.bundleCandidates[app.id] = bundle }
            self.related[app.id] = .loaded(files, Date())
            for file in files where file.isDefaultSelected { self.relatedSelection.insert(file.id) }
        }
    }

    func uninstall(_ app: InstalledApp) {
        guard let environment, let bundle = bundleCandidates[app.id] else { return }
        let files = (related[app.id]?.value ?? []).filter { relatedSelection.contains($0.id) }
        environment.cleanup.review(title: "\(app.info.name) 제거", candidates: [bundle] + files)
    }

    func removeRelatedOnly(_ app: InstalledApp) {
        guard let environment else { return }
        let files = (related[app.id]?.value ?? []).filter { relatedSelection.contains($0.id) }
        environment.cleanup.review(title: "\(app.info.name) 관련 파일 정리", candidates: files)
    }

    func didFinishCleanup(_ done: Set<String>) {
        guard !done.isEmpty else { return }
        for (key, state) in related {
            if case .loaded(var files, let d) = state {
                files.removeAll { done.contains($0.id) }
                related[key] = .loaded(files, d)
            }
        }
        relatedSelection.subtract(done)
        if bundleCandidates.values.contains(where: { done.contains($0.id) }) {
            bundleCandidates = bundleCandidates.filter { !done.contains($0.value.id) }
            selectedAppID = nil
            load()
        }
    }
}
