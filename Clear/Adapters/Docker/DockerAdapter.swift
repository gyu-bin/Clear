import Foundation

/// Docker: read-only `docker system df` analysis. Prune actions are separate,
/// explicit commands; volumes are never pruned by Clear.
struct DockerAdapter: ToolAdapter {
    let id = "docker"
    let name = "Docker"
    let symbol = "shippingbox.fill"
    let kind = ToolKind.developer

    struct DFRow: Decodable {
        let type: String
        let totalCount: String
        let active: String
        let size: String
        let reclaimable: String

        enum CodingKeys: String, CodingKey {
            case type = "Type", totalCount = "TotalCount", active = "Active", size = "Size", reclaimable = "Reclaimable"
        }
    }

    static func parse(_ output: String) -> [DFRow] {
        output.split(separator: "\n").compactMap { try? JSONDecoder().decode(DFRow.self, from: Data($0.utf8)) }
    }

    func scan(_ ctx: ScanContext) async -> ToolReport {
        let appInstalled = ["/Applications/Docker.app", "/Applications/OrbStack.app"].contains { ctx.exists(URL(fileURLWithPath: $0)) }
        guard ctx.commandRunner.locate(.docker) != nil else {
            var r = ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: appInstalled)
            if appInstalled { r.error = "docker CLI를 신뢰할 수 있는 위치에서 찾지 못했습니다." }
            return r
        }
        var report = ToolReport(id: id, name: name, symbol: symbol, kind: kind, installed: true)
        ctx.progress(ScanProgress(phase: "Docker 사용량 확인 중"))
        if let v = try? await ctx.commandRunner.run(.docker, ["version", "--format", "{{.Client.Version}}"], timeout: 15), v.succeeded {
            report.version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let df: CommandResult
        do {
            df = try await ctx.commandRunner.run(.docker, ["system", "df", "--format", "{{json .}}"], timeout: 60)
        } catch {
            report.error = error.localizedDescription
            return report
        }
        guard df.succeeded else {
            report.error = df.stderr.contains("Cannot connect") || df.stderr.contains("daemon")
                ? "Docker 엔진이 실행 중이 아닙니다. Docker를 실행한 뒤 다시 스캔하세요."
                : (df.stderr.split(separator: "\n").first.map(String.init) ?? "docker system df 실패")
            return report
        }
        let rows = Self.parse(df.stdout)
        for row in rows {
            let size = HumanSizeParser.bytes(from: row.size, binary: false) ?? 0
            let reclaim = HumanSizeParser.bytes(from: row.reclaimable, binary: false) ?? 0
            let isVolume = row.type.lowercased().contains("volume")
            report.locations.append(ToolLocation(
                path: "docker:\(row.type)", title: "\(row.type) (\(row.totalCount)개, 사용 중 \(row.active))",
                role: isVolume ? .data : .cache,
                size: SizeInfo(logical: size, allocated: size), isProtected: isVolume,
                note: isVolume ? "볼륨은 영구 데이터를 포함할 수 있어 Clear에서 정리하지 않습니다."
                               : "정리 가능 \(row.reclaimable)"))
            let command: (args: [String], title: String, risk: RiskLevel, impact: String)?
            switch row.type.lowercased() {
            case "images":
                command = (["image", "prune", "-f"], "태그 없는(dangling) 이미지 정리", .review,
                           "어떤 태그도 가리키지 않는 이미지 레이어가 삭제됩니다.")
            case "build cache":
                command = (["builder", "prune", "-f"], "빌드 캐시 정리", .review, "다음 docker build가 캐시 없이 실행됩니다.")
            case "containers":
                command = (["container", "prune", "-f"], "중지된 컨테이너 삭제", .manual,
                           "중지된 컨테이너와 그 안의 쓰기 레이어 데이터가 삭제됩니다.")
            default:
                command = nil
            }
            if let command, reclaim > 0 {
                report.candidates.append(CleanupCandidate(
                    id: "docker:\(command.args.joined(separator: "-"))", title: command.title,
                    subtitle: "docker " + command.args.joined(separator: " "), category: .docker,
                    ruleID: "dev.docker.prune", risk: command.risk, riskReason: "Docker 공식 prune 명령",
                    impact: command.impact, regenerable: command.risk == .review,
                    size: SizeInfo(logical: reclaim, allocated: reclaim), lastModified: nil,
                    target: .command(TrustedCommand(tool: .docker, arguments: command.args)),
                    guards: [], preferredMethod: .permanent, allowsPermanentRemoval: true,
                    warning: "Docker 디스크 이미지는 macOS에서 바로 줄어들지 않을 수 있습니다."))
            }
        }
        report.notes.append("Docker Desktop은 데이터를 가상 디스크에 저장하므로 prune 후에도 Mac 여유 공간이 즉시 늘지 않을 수 있습니다.")
        return report
    }
}
