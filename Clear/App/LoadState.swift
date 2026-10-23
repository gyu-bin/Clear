import Foundation

enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(ScanProgress)
    case loaded(Value, Date)
    case failed(String)

    var value: Value? {
        if case .loaded(let v, _) = self { return v }
        return nil
    }

    var date: Date? {
        if case .loaded(_, let d) = self { return d }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var progress: ScanProgress? {
        if case .loading(let p) = self { return p }
        return nil
    }

    var error: String? {
        if case .failed(let e) = self { return e }
        return nil
    }
}

/// Runs synchronous, CPU/IO-heavy work off the main actor while staying in the
/// caller's task (so cancellation propagates).
@concurrent
func runOffMain<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
    try work()
}
