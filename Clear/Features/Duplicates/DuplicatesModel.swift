import Foundation

@MainActor
@Observable
final class DuplicatesModel {
    enum Mode: String, CaseIterable, Identifiable {
        case exact, similar
        var id: String { rawValue }
        var title: String { self == .exact ? "정확한 중복" : "비슷한 사진" }
    }

    weak var environment: AppModel?
    var mode: Mode = .exact
    var roots: [URL] = []
    var exact: LoadState<DuplicateScanResult> = .idle
    var similar: LoadState<SimilarImageResult> = .idle
    /// Paths marked for removal.
    var marked: Set<String> = []
    var expandedGroups: Set<String> = []

    private var task: Task<Void, Never>?

    /// Roots of the latest scans — registered as allowed roots while results exist.
    var activeRoots: [URL] {
        var urls = (exact.value?.roots ?? []).map { URL(fileURLWithPath: $0) }
        if similar.value != nil { urls += roots }
        return urls
    }

    /// Only folders inside the home folder or on a mounted volume may be scanned.
    static func isAcceptableRoot(_ url: URL) -> Bool {
        let path = PathUtilities.canonicalPath(url.path) ?? url.path
        let home = PathUtilities.canonicalPath(PathUtilities.realHomeDirectory.path) ?? PathUtilities.realHomeDirectory.path
        if PathUtilities.isStrictDescendant(path, of: home) || path == home { return true }
        return PathUtilities.isStrictDescendant(path, of: "/Volumes")
    }

    func addRoots(_ urls: [URL]) -> [URL] {
        var rejected: [URL] = []
        for url in urls {
            guard Self.isAcceptableRoot(url) else { rejected.append(url); continue }
            let canonical = URL(fileURLWithPath: PathUtilities.canonicalPath(url.path) ?? url.path)
            if !roots.contains(canonical) { roots.append(canonical) }
        }
        environment?.settingsStore.settings.duplicateFolders = roots.map(\.path)
        return rejected
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        environment?.settingsStore.settings.duplicateFolders = roots.map(\.path)
    }

    func restoreRoots() {
        guard roots.isEmpty, let saved = environment?.settingsStore.settings.duplicateFolders else { return }
        roots = saved.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func scan() {
        guard !roots.isEmpty, let environment else { return }
        task?.cancel()
        marked.removeAll()
        let roots = self.roots
        let minimum = Int64(max(1, environment.settings.duplicateMinimumSizeMB)) * 1024 * 1024
        let threshold = Float(environment.settings.similarPhotoThreshold)
        switch mode {
        case .exact:
            exact = .loading(ScanProgress(phase: "파일 목록 수집 중"))
            let progress = environment.progressHandler { [weak self] p in if self?.exact.isLoading == true { self?.exact = .loading(p) } }
            task = Task { [weak self] in
                do {
                    let result = try await runOffMain { try DuplicateFinder(minimumSize: minimum).scan(roots: roots, progress: progress) }
                    self?.exact = .loaded(result, Date())
                    self?.selectSuggested()
                } catch is CancellationError {
                    self?.exact = .idle
                } catch {
                    self?.exact = .failed(error.localizedDescription)
                }
            }
        case .similar:
            similar = .loading(ScanProgress(phase: "사진 찾는 중"))
            let progress = environment.progressHandler { [weak self] p in if self?.similar.isLoading == true { self?.similar = .loading(p) } }
            task = Task { [weak self] in
                do {
                    let result = try await runOffMain { try SimilarImageFinder(threshold: threshold).scan(roots: roots, progress: progress) }
                    self?.similar = .loaded(result, Date())
                } catch is CancellationError {
                    self?.similar = .idle
                } catch {
                    self?.similar = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Marks every copy except the suggested keeper — only in groups where the
    /// original is unambiguous. Other groups stay untouched.
    func selectSuggested() {
        guard let groups = exact.value?.groups else { return }
        for group in groups {
            guard let keeper = group.suggestedKeeper else { continue }
            for file in group.files where file.path != keeper { marked.insert(file.path) }
        }
    }

    /// Toggle with the "keep at least one" invariant.
    func toggle(_ path: String, in files: [String]) {
        if marked.contains(path) {
            marked.remove(path)
        } else {
            let others = files.filter { $0 != path }
            guard others.contains(where: { !marked.contains($0) }) else { return }
            marked.insert(path)
        }
    }

    func keepOnly(_ path: String, in files: [String]) {
        for f in files { if f == path { marked.remove(f) } else { marked.insert(f) } }
    }

    // MARK: Cleanup

    func requestCleanup() {
        guard let environment else { return }
        var candidates: [CleanupCandidate] = []
        let policy = environment.makePolicy()
        let groupsExact = exact.value?.groups.map { ($0.id, $0.files.map { ($0.path, $0.identity, $0.allocatedSize, $0.logicalSize, $0.modified) }) } ?? []
        let groupsSimilar = similar.value?.groups.map { ($0.id, $0.images.map { ($0.path, $0.identity, $0.size, $0.size, $0.modified) }) } ?? []
        let isExact = mode == .exact
        for (groupID, files) in (isExact ? groupsExact : groupsSimilar) {
            for (path, identity, allocated, logical, modified) in files where marked.contains(path) {
                guard let root = policy.allowedRoot(containing: path) else { continue }
                let name = (path as NSString).lastPathComponent
                candidates.append(CleanupCandidate(
                    id: "dup:\(path)", title: name, subtitle: PathUtilities.abbreviated(path),
                    category: isExact ? .duplicate : .similarPhoto, ruleID: isExact ? "duplicates.exact" : "duplicates.similar",
                    risk: .manual,
                    riskReason: isExact ? "SHA-256으로 내용이 동일함을 확인한 사본 (그룹 \(groupID.prefix(8)))"
                                        : "비슷한 사진 — 직접 비교 후 선택함",
                    impact: "휴지통으로 이동합니다. 같은 그룹의 다른 파일은 유지됩니다.",
                    regenerable: false,
                    size: SizeInfo(logical: logical, allocated: allocated, fileCount: 1, newestModification: modified),
                    lastModified: modified,
                    target: .path(PathTarget(url: URL(fileURLWithPath: path), identity: identity,
                                             allowedRoot: URL(fileURLWithPath: root), toleratesContentChanges: false,
                                             scannedAt: exact.date ?? similar.date ?? Date())),
                    guards: [], preferredMethod: .trash, allowsPermanentRemoval: false,
                    warning: isExact ? nil : "비슷한 사진은 내용이 다릅니다. 편집본·원본을 확인했는지 다시 확인하세요."))
            }
        }
        let fileGroups = (isExact ? groupsExact : groupsSimilar).map { (_, files) in files.map { ($0.0, $0.1) } }
        environment.cleanup.review(title: isExact ? "중복 파일 정리" : "비슷한 사진 정리", candidates: candidates) { plan in
            Self.verifyKeepers(plan: plan, groups: fileGroups)
        }
    }

    /// Pre-flight: every group must still have at least one unselected file that
    /// exists on disk unchanged. Otherwise the cleanup is refused.
    static func verifyKeepers(plan: CleanupPlan, groups: [[(String, FileIdentity)]]) -> String? {
        let removing = Set(plan.items.compactMap(\.candidate.path))
        for files in groups where files.contains(where: { removing.contains($0.0) }) {
            let keepers = files.filter { !removing.contains($0.0) }
            let intact = keepers.contains { path, identity in
                (try? LocalFileSystem().identity(atPath: path)).map { $0.isSameObject(as: identity) } ?? false
            }
            if !intact {
                return "‘\((files[0].0 as NSString).lastPathComponent)’ 그룹에 남겨둘 원본이 더 이상 존재하지 않아 정리를 중단했습니다. 다시 스캔하세요."
            }
        }
        return nil
    }

    func didFinishCleanup(_ done: Set<String>) {
        let removedPaths = Set(done.filter { $0.hasPrefix("dup:") }.map { String($0.dropFirst(4)) })
        guard !removedPaths.isEmpty else { return }
        marked.subtract(removedPaths)
        if case .loaded(let r, let d) = exact {
            let groups = r.groups.compactMap { g -> DuplicateGroup? in
                let files = g.files.filter { !removedPaths.contains($0.path) }
                return files.count > 1 ? DuplicateGroup(id: g.id, files: files, suggestedKeeper: g.suggestedKeeper) : nil
            }
            exact = .loaded(DuplicateScanResult(groups: groups, scannedFiles: r.scannedFiles, hashedFiles: r.hashedFiles,
                                                skippedCloudOnly: r.skippedCloudOnly, skippedProtected: r.skippedProtected,
                                                restricted: r.restricted, hardLinkSets: r.hardLinkSets, roots: r.roots), d)
        }
        if case .loaded(let r, let d) = similar {
            let groups = r.groups.compactMap { g -> SimilarImageGroup? in
                let images = g.images.filter { !removedPaths.contains($0.path) }
                return images.count > 1 ? SimilarImageGroup(id: g.id, images: images, closestDistance: g.closestDistance) : nil
            }
            similar = .loaded(SimilarImageResult(groups: groups, analyzedImages: r.analyzedImages,
                                                 skippedCloudOnly: r.skippedCloudOnly, truncated: r.truncated), d)
        }
    }
}
