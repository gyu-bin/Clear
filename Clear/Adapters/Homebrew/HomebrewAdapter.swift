import Foundation

enum HumanSizeParser {
    /// Parses "61.4MB", "1.2 GB", "512kB", "0B". `binary` selects 1024-based units.
    static func bytes(from text: String, binary: Bool) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: /^([0-9]+(?:[.,][0-9]+)?)\s*([KkMGTP]i?B|B)/) else { return nil }
        let number = Double(match.1.replacingOccurrences(of: ",", with: ".")) ?? 0
        let base: Double = binary ? 1024 : 1000
        let unit = match.2.uppercased()
        let exp: Double = switch unit.first {
        case "K": 1
        case "M": 2
        case "G": 3
        case "T": 4
        case "P": 5
        default: 0
        }
        return Int64(number * pow(base, exp))
    }
}

/// Homebrew is cleaned only through its own `brew cleanup`, after showing the dry run.
struct HomebrewAdapter: ToolAdapter {
    let id = "homebrew"
    let name = "Homebrew"
    let symbol = "mug.fill"
    let kind = ToolKind.developer

    struct DryRun: Sendable {
        var items: [(path: String, size: Int64)] = []
        var total: Int64 = 0
    }

    static func parseDryRun(_ output: String) -> DryRun {
        var result = DryRun()
        for line in output.split(separator: "\n") {
            if let m = line.firstMatch(of: /^Would remove: (.+?) \((?:[0-9,]+ files?, )?([0-9.,]+\s*[KMGT]?B)\)$/) {
                result.items.append((String(m.1), HumanSizeParser.bytes(from: String(m.2), binary: true) ?? 0))
            } else if let m = line.firstMatch(of: /free approximately ([0-9.,]+\s*[KMGT]?B)/) {
                result.total = HumanSizeParser.bytes(from: String(m.1), binary: true) ?? 0
            }
        }
        if result.total == 0 { result.total = result.items.reduce(0) { $0 + $1.size } }
        return result
    }

    func scan(_ ctx: ScanContext) async -> ToolReport {
        guard ctx.commandRunner.locate(.brew) != nil else {
            return ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: false)
        }
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: true)
        ctx.progress(ScanProgress(phase: "Homebrew 정리 대상 확인 중 (brew cleanup -n)"))
        if let v = try? await ctx.commandRunner.run(.brew, ["--version"], timeout: 30), v.succeeded {
            report.version = v.stdout.split(separator: "\n").first.map { $0.replacingOccurrences(of: "Homebrew ", with: "") }
        }
        if let cache = try? await ctx.commandRunner.run(.brew, ["--cache"], timeout: 30), cache.succeeded {
            let path = cache.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), let loc = ctx.location(URL(fileURLWithPath: path), title: "다운로드 캐시", role: .cache,
                                                          protected: true, note: "brew cleanup으로 정리됩니다.") {
                report.locations.append(loc)
            }
        }
        do {
            let result = try await ctx.commandRunner.run(.brew, ["cleanup", "-n"], timeout: 180)
            guard result.succeeded else {
                report.error = result.stderr.split(separator: "\n").last.map(String.init) ?? "brew cleanup -n 실패"
                return report
            }
            let dry = Self.parseDryRun(result.stdout)
            report.notes.append("dry-run 결과 \(dry.items.count)개 항목, 약 \(dry.total.formattedBytes) 확보 예상")
            if !dry.items.isEmpty {
                let preview = dry.items.prefix(8).map { "• " + PathUtilities.abbreviated($0.path) }.joined(separator: "\n")
                report.candidates.append(CleanupCandidate(
                    id: "brew:cleanup", title: "오래된 버전과 다운로드 정리", subtitle: "brew cleanup",
                    category: .homebrew, ruleID: "dev.homebrew.cleanup", risk: .review,
                    riskReason: "Homebrew 공식 정리 명령 — 사용 중인 버전은 유지",
                    impact: "설치된 패키지의 이전 버전과 오래된 다운로드가 삭제됩니다. 이전 버전으로 되돌릴 수 없습니다.\n\(preview)"
                        + (dry.items.count > 8 ? "\n외 \(dry.items.count - 8)개" : ""),
                    regenerable: true,
                    size: SizeInfo(logical: dry.total, allocated: dry.total, fileCount: dry.items.count),
                    lastModified: nil,
                    target: .command(TrustedCommand(tool: .brew, arguments: ["cleanup"])),
                    guards: DeveloperGuards.homebrew, preferredMethod: .permanent, allowsPermanentRemoval: true,
                    runningGuards: ctx.processes.runningGuards(DeveloperGuards.homebrew)))
            }
        } catch {
            report.error = error.localizedDescription
        }
        return report
    }
}
