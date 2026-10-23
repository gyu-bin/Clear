import Foundation

struct VolumeInfo: Hashable, Sendable, Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let totalCapacity: Int64
    /// What macOS considers available for important data (includes purgeable space).
    let availableForImportantUsage: Int64
    /// Raw free blocks right now (excludes purgeable space). The strict number used
    /// to verify how much a cleanup actually freed.
    let availableRaw: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isRoot: Bool
    let isReadOnly: Bool
    let fileSystem: String?

    var used: Int64 { max(0, totalCapacity - availableForImportantUsage) }
    var purgeable: Int64 { max(0, availableForImportantUsage - availableRaw) }
    var usedFraction: Double { totalCapacity > 0 ? Double(used) / Double(totalCapacity) : 0 }
}

/// Reads volume capacity through `URLResourceValues` (the same source Finder uses).
struct VolumeService: Sendable {
    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
        .volumeIsRemovableKey, .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey,
    ]

    func volume(containing url: URL = PathUtilities.realHomeDirectory) throws -> VolumeInfo {
        // URL resource values are cached per URL instance; build a fresh one each time.
        let fresh = URL(fileURLWithPath: url.path)
        let v = try fresh.resourceValues(forKeys: Self.keys)
        let raw = Int64(v.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            url: url,
            name: v.volumeName ?? "Macintosh HD",
            totalCapacity: Int64(v.volumeTotalCapacity ?? 0),
            availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? raw,
            availableRaw: raw,
            isInternal: v.volumeIsInternal ?? true,
            isRemovable: v.volumeIsRemovable ?? false,
            isRoot: v.volumeIsRootFileSystem ?? false,
            isReadOnly: v.volumeIsReadOnly ?? false,
            fileSystem: v.volumeLocalizedFormatDescription
        )
    }

    /// User-visible mounted volumes, including external drives (scanned only when selected).
    func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(Self.keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let info = try? volume(containing: url), info.totalCapacity > 0 else { return nil }
            return info
        }
    }
}
