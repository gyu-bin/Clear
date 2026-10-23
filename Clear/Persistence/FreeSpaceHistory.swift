import Foundation

struct FreeSpaceSample: Codable, Hashable, Sendable, Identifiable {
    var id: Date { date }
    let date: Date
    let available: Int64
    let total: Int64
}

/// Free-space samples for the Home trend chart, stored locally in
/// `~/Library/Application Support/Clear/free-space.json`.
/// A sample is kept at most every 30 minutes (sooner if the value moved by more
/// than 1 GB); samples older than 90 days are dropped.
@MainActor
@Observable
final class FreeSpaceHistory {
    private(set) var samples: [FreeSpaceSample] = []
    private let fileURL: URL
    private let minimumInterval: TimeInterval = 30 * 60
    private let retention: TimeInterval = 90 * 86_400

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clear", isDirectory: true)
        fileURL = base.appendingPathComponent("free-space.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([FreeSpaceSample].self, from: data) {
            samples = decoded
        }
    }

    func record(available: Int64, total: Int64, at date: Date = Date()) {
        if let last = samples.last {
            let elapsed = date.timeIntervalSince(last.date)
            let moved = abs(available - last.available) > 1_000_000_000
            guard elapsed >= minimumInterval || (moved && elapsed >= 60) else { return }
        }
        samples.append(FreeSpaceSample(date: date, available: available, total: total))
        samples.removeAll { date.timeIntervalSince($0.date) > retention }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(samples).write(to: fileURL, options: .atomic)
    }

    func samples(lastDays days: Int, now: Date = Date()) -> [FreeSpaceSample] {
        samples.filter { now.timeIntervalSince($0.date) <= Double(days) * 86_400 }
    }
}
