import Foundation
import ImageIO
import Vision

struct SimilarImage: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let size: Int64
    let modified: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let identity: FileIdentity
}

struct SimilarImageGroup: Identifiable, Hashable, Sendable {
    let id: String
    let images: [SimilarImage]
    /// Smallest pairwise distance observed in the group (lower = more alike).
    let closestDistance: Float
}

struct SimilarImageResult: Sendable {
    let groups: [SimilarImageGroup]
    let analyzedImages: Int
    let skippedCloudOnly: Int
    let truncated: Bool
}

/// Finds visually similar photos with Vision feature prints. Results are only
/// suggestions: nothing is pre-selected and the user compares side by side.
struct SimilarImageFinder: Sendable {
    var maximumImages = 2500
    var minimumSize: Int64 = 50 * 1024
    /// Euclidean distance between normalized feature prints (revision 2: 0…2).
    var threshold: Float = 0.35

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp"]

    func scan(roots: [URL], progress: @escaping @Sendable (ScanProgress) -> Void) throws -> SimilarImageResult {
        var files: [SimilarImage] = []
        var cloudOnly = 0
        var truncated = false
        for root in roots {
            try FTSWalker(root: PathUtilities.canonicalPath(root.path) ?? root.path).walk { entry in
                let name = (entry.path as NSString).lastPathComponent
                if entry.kind == .directoryPre, entry.level > 0 {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if name.hasPrefix(".") || DuplicateFinder.skippedPackages.contains(ext)
                        || DuplicateFinder.skippedDirectories.contains(name) { return .skipDescendants }
                }
                guard entry.kind == .file, let st = entry.stat, !name.hasPrefix("."),
                      Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { return .continue }
                let id = FileIdentity(stat: st)
                guard id.logicalSize >= minimumSize else { return .continue }
                if id.isDataless { cloudOnly += 1; return .continue }
                if files.count >= maximumImages { truncated = true; return .stop }
                files.append(SimilarImage(path: entry.path, name: name, size: id.allocatedSize, modified: id.modificationDate,
                                          pixelWidth: 0, pixelHeight: 0, identity: id))
                return .continue
            }
        }

        var prints: [(SimilarImage, VNFeaturePrintObservation)] = []
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            progress(ScanProgress(phase: "이미지 특징 분석 중", detail: file.name,
                                  fraction: Double(i) / Double(max(1, files.count)) * 0.9, itemsVisited: i))
            guard let fp = featurePrint(for: file.path) else { continue }
            var enriched = file
            if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: file.path) as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                enriched = SimilarImage(path: file.path, name: file.name, size: file.size, modified: file.modified,
                                        pixelWidth: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                        pixelHeight: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
                                        identity: file.identity)
            }
            prints.append((enriched, fp))
        }

        // Union-find over pairs below the threshold.
        var parent = Array(0..<prints.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        var closest = [Int: Float]()
        for i in 0..<prints.count {
            if i % 64 == 0 {
                try Task.checkCancellation()
                progress(ScanProgress(phase: "비슷한 사진 묶는 중", fraction: 0.9 + 0.1 * Double(i) / Double(max(1, prints.count))))
            }
            for j in (i + 1)..<prints.count {
                var distance: Float = 0
                guard (try? prints[i].1.computeDistance(&distance, to: prints[j].1)) != nil, distance <= threshold else { continue }
                let a = find(i), b = find(j)
                if a != b { parent[b] = a }
                closest[i] = min(closest[i] ?? distance, distance)
                closest[j] = min(closest[j] ?? distance, distance)
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in 0..<prints.count where closest[i] != nil { clusters[find(i), default: []].append(i) }
        let groups = clusters.values.filter { $0.count > 1 }.map { members in
            SimilarImageGroup(id: prints[members[0]].0.path,
                              images: members.map { prints[$0].0 }.sorted { $0.modified < $1.modified },
                              closestDistance: members.compactMap { closest[$0] }.min() ?? 0)
        }.sorted { $0.images.count > $1.images.count }
        return SimilarImageResult(groups: groups, analyzedImages: prints.count, skippedCloudOnly: cloudOnly, truncated: truncated)
    }

    private func featurePrint(for path: String) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }
}
