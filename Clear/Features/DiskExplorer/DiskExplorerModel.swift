import Foundation

@MainActor
@Observable
final class DiskExplorerModel {
    enum Tab: String, CaseIterable, Identifiable {
        case treemap, largeFiles, oldFiles, types
        var id: String { rawValue }
        var title: String {
            switch self {
            case .treemap: "트리맵"
            case .largeFiles: "대용량 파일"
            case .oldFiles: "오래된 파일"
            case .types: "파일 유형"
            }
        }
    }

    weak var environment: AppModel?
    var rootURL: URL?
    var state: LoadState<DiskScanResult> = .idle
    /// Navigation stack; the last element is the folder being shown.
    var stack: [DiskNode] = []
    var selectedNode: DiskNode?
    var hoveredNode: DiskNode?
    var tab: Tab = .treemap
    var filter = ""
    var typeFilter: FileTypeGroup?

    private var task: Task<Void, Never>?

    var current: DiskNode? { stack.last }

    func scan(_ url: URL) {
        task?.cancel()
        rootURL = url
        stack = []
        selectedNode = nil
        state = .loading(ScanProgress(phase: "탐색 준비 중"))
        let noop: @Sendable (ScanProgress) -> Void = { _ in }
        let progress = environment?.progressHandler { [weak self] p in
            if self?.state.isLoading == true { self?.state = .loading(p) }
        } ?? noop
        task = Task { [weak self] in
            do {
                let result = try await runOffMain { try DiskTreeScanner().scan(root: url, progress: progress) }
                guard let self, !Task.isCancelled else { return }
                self.state = .loaded(result, Date())
                self.stack = [result.root]
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }

    func rescan() { if let rootURL { scan(rootURL) } }

    func enter(_ node: DiskNode) {
        guard node.isContainer else { selectedNode = node; return }
        stack.append(node)
        selectedNode = nil
    }

    func goUp() {
        guard stack.count > 1 else { return }
        stack.removeLast()
        selectedNode = nil
    }

    func go(to index: Int) {
        guard stack.indices.contains(index) else { return }
        stack.removeSubrange((index + 1)...)
        selectedNode = nil
    }

    var visibleChildren: [DiskNode] {
        guard let current else { return [] }
        guard !filter.isEmpty else { return current.children }
        return current.children.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Quick-pick locations, including external volumes (scanned only when chosen).
    var quickLocations: [(title: String, symbol: String, url: URL)] {
        let home = PathUtilities.realHomeDirectory
        var list: [(String, String, URL)] = [
            ("홈 폴더", "house", home),
            ("다운로드", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("문서", "doc.text", home.appendingPathComponent("Documents")),
            ("라이브러리", "books.vertical", home.appendingPathComponent("Library")),
            ("응용 프로그램", "square.grid.2x2", URL(fileURLWithPath: "/Applications")),
        ]
        for volume in environment?.volumeService.mountedVolumes() ?? [] where !volume.isRoot {
            list.append((volume.name, volume.isRemovable ? "externaldrive" : "internaldrive", volume.url))
        }
        return list
    }
}
