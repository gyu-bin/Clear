import AppKit
import SwiftUI

/// Design tokens.
///
/// Text and separators use the system label colors so contrast follows the
/// appearance and the "Increase contrast" setting automatically. Surfaces are a
/// calm charcoal in dark mode and white / light gray in light mode. The accent
/// (teal, from the asset catalog) is reserved for primary buttons and selection;
/// `accentBright` is the lighter mint used for data marks such as capacity bars.
enum ClearColor {
    // Surfaces
    static let background = dynamic(dark: 0x1B1C1F, light: 0xFFFFFF, darkHC: 0x111214, lightHC: 0xFFFFFF)
    static let surface = dynamic(dark: 0x232428, light: 0xF5F5F7, darkHC: 0x1C1D20, lightHC: 0xF0F0F2)
    static let elevated = dynamic(dark: 0x2C2D32, light: 0xEBEBEE, darkHC: 0x34353B, lightHC: 0xE2E2E6)
    static let hover = dynamic(dark: 0xFFFFFF, light: 0x000000, alphaDark: 0.05, alphaLight: 0.04, alphaHC: 0.10)
    static let track = dynamic(dark: 0xFFFFFF, light: 0x000000, alphaDark: 0.09, alphaLight: 0.08, alphaHC: 0.2)

    // Text & lines (system, appearance- and contrast-aware)
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
    static let stroke = separator

    // Accent
    static let accent = Color.accentColor
    static let accentBright = dynamic(dark: 0x7ED5D2, light: 0x1F8582, darkHC: 0xA4ECE9, lightHC: 0x0E5F5D)
    static let accentDeep = accent
    static let developer = dynamic(dark: 0xB7A2E6, light: 0x6F52C2)
    static let ai = dynamic(dark: 0x92B3EE, light: 0x3A62BE)

    // Status (system colors adapt to appearance and contrast)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let info = Color(nsColor: .systemBlue)

    /// Muted palette for storage categories and treemap tiles.
    static let chart: [Color] = [
        dynamic(dark: 0x5FB8B4, light: 0x4FA9A5), dynamic(dark: 0x6F95D6, light: 0x5D86CC),
        dynamic(dark: 0x9C86D4, light: 0x8B74C8), dynamic(dark: 0xD0A85E, light: 0xC69A48),
        dynamic(dark: 0x74B98F, light: 0x5FAA7C), dynamic(dark: 0xC9809F, light: 0xBD6E8F),
        dynamic(dark: 0xC98A78, light: 0xBE7A66), dynamic(dark: 0x8C97A8, light: 0x8A95A5),
    ]

    static func risk(_ level: RiskLevel) -> Color {
        switch level {
        case .safe: success
        case .review: warning
        case .manual: info
        case .blocked: textTertiary
        }
    }

    static func domain(_ domain: CleanupDomain) -> Color {
        switch domain {
        case .developer, .projects: developer
        case .aiTools: ai
        default: textSecondary
        }
    }

    private static func dynamic(dark: UInt32, light: UInt32, darkHC: UInt32? = nil, lightHC: UInt32? = nil,
                                alphaDark: CGFloat = 1, alphaLight: CGFloat = 1, alphaHC: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            switch match {
            case .accessibilityHighContrastDarkAqua: return nsColor(darkHC ?? dark, alphaHC ?? alphaDark)
            case .accessibilityHighContrastAqua: return nsColor(lightHC ?? light, alphaHC ?? alphaLight)
            case .darkAqua: return nsColor(dark, alphaDark)
            default: return nsColor(light, alphaLight)
            }
        })
    }

    private static func nsColor(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
