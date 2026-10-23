import Foundation
import os

/// Stores cleanup reports as JSON in `~/Library/Application Support/Clear/history.json`.
@MainActor
@Observable
final class HistoryStore {
    private(set) var records: [CleanupReport] = []
    private(set) var loadError: String?
    private let fileURL: URL
    private static let log = Logger(subsystem: "com.mungyubin.clear", category: "history")

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clear", isDirectory: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    var lastReport: CleanupReport? { records.first }

    func append(_ report: CleanupReport, retentionDays: Int) {
        records.insert(report, at: 0)
        prune(retentionDays: retentionDays)
        save()
    }

    func prune(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        records.removeAll { $0.finishedAt < cutoff }
    }

    func removeAll() {
        records.removeAll()
        save()
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([CleanupReport].self, from: data)
        } catch {
            loadError = "정리 기록을 읽지 못했습니다: \(error.localizedDescription)"
            Self.log.error("history decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
