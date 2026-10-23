import SwiftUI

/// Buttons are native AppKit-styled controls. The accent fill is reserved for
/// the single primary action of a screen.
extension View {
    func primaryButton(large: Bool = false) -> some View {
        buttonStyle(.borderedProminent).controlSize(large ? .large : .regular)
    }

    func secondaryButton(large: Bool = false) -> some View {
        buttonStyle(.bordered).controlSize(large ? .large : .regular)
    }

    func destructiveButton() -> some View {
        buttonStyle(.borderedProminent).tint(ClearColor.danger)
    }
}

/// Small borderless icon button.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(ClearColor.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
