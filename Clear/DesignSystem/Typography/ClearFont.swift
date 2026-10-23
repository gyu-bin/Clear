import SwiftUI

/// Type scale on the system font (SF Pro). Every number uses tabular digits so
/// columns line up and values do not jitter while they change.
enum ClearFont {
    /// The one hero figure on a screen.
    static let display = Font.system(size: 30, weight: .semibold).monospacedDigit()
    static let figure = Font.system(size: 20, weight: .semibold).monospacedDigit()
    static let figureSmall = Font.system(size: 15, weight: .semibold).monospacedDigit()
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let captionEmphasis = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let numeric = Font.system(size: 13).monospacedDigit()
    static let numericSmall = Font.system(size: 12).monospacedDigit()
}

/// Spacing, radius and icon sizes shared by every screen.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let s: CGFloat = 4
    static let m: CGFloat = 6
    static let l: CGFloat = 10
}

enum IconSize {
    static let row: CGFloat = 16
    static let rowLarge: CGFloat = 24
}

enum ClearMetrics {
    static let pagePadding: CGFloat = Space.xl
    static let gap: CGFloat = Space.l
    static let contentMaxWidth: CGFloat = 1040
    static let rowVerticalPadding: CGFloat = 6
}
