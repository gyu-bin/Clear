import SwiftUI

/// Two-level squarified treemap drawn with Canvas.
/// Top-level tiles carry the color; their children are shown as brightness
/// variations of that color so structure is visible without extra chrome.
struct TreemapView: View {
    let node: DiskNode
    @Binding var hovered: DiskNode?
    let selected: DiskNode?
    let onActivate: (DiskNode) -> Void

    private struct Tile {
        let node: DiskNode
        let rect: CGRect
        let color: Color
        let children: [(DiskNode, CGRect)]
        let hasHeader: Bool
    }

    static func color(for node: DiskNode, index: Int) -> Color {
        switch node.kind {
        case .aggregate: ClearColor.chart[7].opacity(0.6)
        case .file, .symlink: ClearColor.chart[(FileTypeGroup.allCases.firstIndex(of: node.fileType) ?? 0) % ClearColor.chart.count]
        default: ClearColor.chart[index % (ClearColor.chart.count - 1)]
        }
    }

    private func tiles(in size: CGSize) -> [Tile] {
        let items = node.children.filter { $0.allocatedSize > 0 }
        let rects = TreemapLayout.squarify(items.map { Double($0.allocatedSize) }, in: CGRect(origin: .zero, size: size))
        return zip(items, rects).enumerated().map { index, pair in
            let (child, rect) = pair
            let hasHeader = child.isContainer && rect.width > 70 && rect.height > 44
            var inner: [(DiskNode, CGRect)] = []
            if hasHeader {
                let content = CGRect(x: rect.minX + 3, y: rect.minY + 20, width: rect.width - 6, height: rect.height - 23)
                let grand = child.children.filter { $0.allocatedSize > 0 }.prefix(60)
                inner = Array(zip(grand, TreemapLayout.squarify(grand.map { Double($0.allocatedSize) }, in: content)))
            }
            return Tile(node: child, rect: rect, color: Self.color(for: child, index: index), children: inner, hasHeader: hasHeader)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let layout = tiles(in: geo.size)
            Canvas { ctx, _ in
                for tile in layout {
                    let r = tile.rect.insetBy(dx: 1, dy: 1)
                    guard r.width > 1, r.height > 1 else { continue }
                    let radius = min(4, min(r.width, r.height) / 4)
                    let path = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
                    ctx.fill(path, with: .color(tile.color))
                    for (i, (child, cr)) in tile.children.enumerated() {
                        let ir = cr.insetBy(dx: 0.75, dy: 0.75)
                        guard ir.width > 1.5, ir.height > 1.5 else { continue }
                        let ip = Path(roundedRect: ir, cornerRadius: min(3, min(ir.width, ir.height) / 4), style: .continuous)
                        let shade = 0.10 + Double(i % 3) * 0.05
                        ctx.fill(ip, with: .color(.black.opacity(hovered?.id == child.id ? 0 : shade)))
                    }
                    if hovered?.id == tile.node.id { ctx.fill(path, with: .color(.white.opacity(0.14))) }
                    if selected?.id == tile.node.id { ctx.stroke(path, with: .color(.white), lineWidth: 2) }
                    if r.width > 56, r.height > 18 {
                        let title = Text(tile.node.name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                        ctx.draw(title, in: CGRect(x: r.minX + 6, y: r.minY + 3, width: r.width - 12, height: 14))
                    }
                    if r.width > 56, r.height > 36, !tile.hasHeader {
                        let size = Text(tile.node.allocatedSize.formattedBytes).font(.system(size: 10).monospacedDigit())
                            .foregroundColor(.white.opacity(0.8))
                        ctx.draw(size, in: CGRect(x: r.minX + 6, y: r.minY + 17, width: r.width - 12, height: 13))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(p, in: layout)
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let tile = layout.first(where: { $0.rect.contains(value.location) }) { onActivate(tile.node) }
            })
        }
        .accessibilityElement()
        .accessibilityLabel("\(node.name) 트리맵, 하위 항목 \(node.children.count)개")
        .accessibilityHint("오른쪽 목록에서 키보드로 탐색할 수 있습니다")
    }

    private func hit(_ p: CGPoint, in layout: [Tile]) -> DiskNode? {
        guard let tile = layout.first(where: { $0.rect.contains(p) }) else { return nil }
        return tile.children.first(where: { $0.1.contains(p) })?.0 ?? tile.node
    }
}
