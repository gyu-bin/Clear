import QuickLookThumbnailing
import SwiftUI

/// QuickLook thumbnail with a Finder-icon placeholder.
struct ThumbnailView: View {
    let path: String
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().aspectRatio(contentMode: .fit).padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .task(id: path) { image = await Self.load(path: path, size: size) }
        .accessibilityHidden(true)
    }

    @MainActor
    private static func load(path: String, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        return rep.nsImage
    }
}
