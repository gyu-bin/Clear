import Foundation
import os

struct CleanupProgress: Sendable, Equatable {
    var completed: Int
    var total: Int
    var currentTitle: String
    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

/// Executes a plan item by item. Every item is re-validated right before it is
/// touched; failures are isolated; cancellation stops before the next item.
struct CleanupExecutor: Sendable {
    let validator: CleanupValidator
    let fileSystem: FileSystemOperating
    let processes: ProcessInspecting
    let commandRunner: CommandRunning
    let volumes: VolumeService
    var measureVolume = true

    private static let log = Logger(subsystem: "com.mungyubin.clear", category: "cleanup")

    func execute(_ plan: CleanupPlan,
                 progress: @escaping @Sendable (CleanupProgress) -> Void) async -> CleanupReport {
        let started = Date()
        let before = measureVolume ? (try? volumes.volume())?.availableRaw : nil
        var results: [CleanupItemResult] = []
        var cancelled = false

        for (index, item) in plan.items.enumerated() {
            progress(CleanupProgress(completed: index, total: plan.items.count, currentTitle: item.candidate.title))
            if Task.isCancelled { cancelled = true }
            if cancelled {
                results.append(result(item, .cancelled, message: "사용자가 취소함"))
                continue
            }
            let snapshot = await processes.snapshot()
            let outcome = validator.validate(item.candidate, processes: snapshot)
            switch outcome {
            case .alreadyGone:
                results.append(result(item, .alreadyGone, message: nil))
                continue
            case .rejected(let reason):
                Self.log.info("skip \(item.candidate.id, privacy: .public): \(reason, privacy: .public)")
                results.append(result(item, .skipped, message: reason))
                continue
            case .approved:
                break
            }
            results.append(await perform(item))
            if Task.isCancelled { cancelled = true }
        }
        progress(CleanupProgress(completed: plan.items.count, total: plan.items.count, currentTitle: ""))

        let after = measureVolume ? (try? volumes.volume())?.availableRaw : nil
        return CleanupReport(id: plan.id, title: plan.title, startedAt: started, finishedAt: Date(),
                             results: results, freeSpaceBefore: before, freeSpaceAfter: after,
                             wasCancelled: cancelled)
    }

    private func perform(_ item: CleanupPlanItem) async -> CleanupItemResult {
        switch item.candidate.target {
        case .command(let command):
            do {
                let output = try await commandRunner.run(command.tool, command.arguments, timeout: 600)
                if output.succeeded {
                    return result(item, .commandSucceeded, message: Self.summary(of: output.stdout))
                }
                return result(item, .failed, message: Self.summary(of: output.stderr.isEmpty ? output.stdout : output.stderr)
                              ?? "종료 코드 \(output.exitCode)")
            } catch {
                return result(item, .failed, message: error.localizedDescription)
            }

        case .path(let target):
            switch item.method {
            case .trash:
                do {
                    let location = try fileSystem.moveToTrash(atPath: target.path)
                    return result(item, .trashed, message: nil, trash: location)
                } catch {
                    return result(item, .failed, message: error.localizedDescription)
                }
            case .permanent:
                let fs = fileSystem
                let path = target.path
                let identity = target.identity
                let outcome: Result<RemovalStats, Error> = await Task.detached(priority: .userInitiated) {
                    Result { try fs.removeTree(atPath: path, expected: identity, shouldCancel: { Task.isCancelled }) }
                }.value
                switch outcome {
                case .success(let stats):
                    return result(item, .removed, message: nil, freed: stats.freedBytes)
                case .failure(let error as RemovalIncomplete):
                    return result(item, .failed, message: error.localizedDescription, freed: error.stats.freedBytes)
                case .failure(FileSystemError.notFound):
                    return result(item, .alreadyGone, message: nil)
                case .failure(let error):
                    return result(item, .failed, message: error.localizedDescription)
                }
            }
        }
    }

    private func result(_ item: CleanupPlanItem, _ status: CleanupItemStatus, message: String?,
                        freed: Int64 = 0, trash: String? = nil) -> CleanupItemResult {
        CleanupItemResult(candidateID: item.candidate.id, title: item.candidate.title, path: item.candidate.path,
                          category: item.candidate.category, method: item.method, status: status,
                          estimatedBytes: item.candidate.estimatedBytes, freedBytes: freed,
                          message: message, trashLocation: trash)
    }

    private static func summary(of text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return String(last.prefix(300))
    }
}
