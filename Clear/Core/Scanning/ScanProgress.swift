import Foundation

/// Progress messages emitted by long-running scans.
struct ScanProgress: Sendable, Equatable {
    var phase: String
    var detail: String = ""
    /// 0...1 when known.
    var fraction: Double?
    var itemsVisited: Int = 0
}

/// Thread-safe box used to throttle progress callbacks coming from a background walk.
final class ProgressThrottle: @unchecked Sendable {
    private let interval: TimeInterval
    private var last = Date.distantPast
    private let lock = NSLock()

    init(interval: TimeInterval = 0.08) { self.interval = interval }

    func shouldEmit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
