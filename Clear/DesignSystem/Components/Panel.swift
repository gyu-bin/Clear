import SwiftUI

/// Flat grouped container: subtle fill and a hairline, no gradient, no shadow.
/// Used only where content forms a real group (lists, tables, detail blocks).
struct PanelModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClearColor.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).strokeBorder(ClearColor.separator, lineWidth: 0.5))
    }
}

extension View {
    func panel(padding: CGFloat = Space.l) -> some View { modifier(PanelModifier(padding: padding)) }
}

/// Row hover background.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(hovering ? ClearColor.hover : .clear))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}

/// Hairline divider inset to align with row text.
struct RowDivider: View {
    var leading: CGFloat = 0
    var body: some View {
        Rectangle().fill(ClearColor.separator).frame(height: 0.5).padding(.leading, leading)
    }
}
