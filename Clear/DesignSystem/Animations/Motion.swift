import SwiftUI

/// Short animations that collapse to none when Reduce Motion is on.
enum Motion {
    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.22)
    }

    static func gentle(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }

    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }
}
