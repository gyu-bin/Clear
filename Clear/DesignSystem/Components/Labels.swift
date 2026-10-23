import SwiftUI

/// Risk shown as a colored dot plus text — readable without relying on color alone.
struct RiskBadge: View {
    let risk: RiskLevel
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ClearColor.risk(risk)).frame(width: 6, height: 6)
            Text(risk.title).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
        }
        .fixedSize()
        .help(risk.explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("위험도 \(risk.title)")
    }
}

/// Quiet metadata tag. Tint is for status only (warning, running).
struct TagBadge: View {
    let text: String
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(ClearFont.caption).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .foregroundStyle(tint ?? ClearColor.textSecondary)
        .background(Capsule().fill((tint ?? ClearColor.textSecondary).opacity(0.12)))
        .fixedSize()
    }
}

/// Monochrome SF Symbol at row size. `tint` is applied only when given.
struct SymbolTile: View {
    let symbol: String
    var tint: Color? = nil
    var size: CGFloat = IconSize.row

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.85))
            .foregroundStyle(tint ?? ClearColor.textSecondary)
            .frame(width: size + 4, height: size + 4)
            .accessibilityHidden(true)
    }
}
