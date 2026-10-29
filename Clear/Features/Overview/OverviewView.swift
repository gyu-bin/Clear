import Charts
import SwiftUI

/// Home dashboard. Every figure comes from real data: the volume (always), the
/// last Mac scan (labelled with its age when not from this session), the Trash,
/// cleanup history and the locally recorded free-space samples.
struct OverviewView: View {
    @Environment(\.appModel) private var model

    var body: some View {
        PageContainer(title: "홈", subtitle: model.volume?.name) {
            if !model.isScanningMac && model.general.value != nil {
                Button { model.scanMac() } label: { Label("다시 스캔", systemImage: "arrow.clockwise") }
                    .help("저장공간과 정리 후보를 다시 분석합니다 (읽기 전용)")
            }
        } content: {
            if !model.hasFullDiskAccess && !model.settings.fullDiskAccessNoticeDismissed {
                FullDiskAccessNotice()
            }
            if model.isScanningMac {
                ScanProgressView(progress: model.general.progress ?? model.developer.progress ?? model.ai.progress
                                 ?? model.storage.progress ?? ScanProgress(phase: "마무리 중"),
                                 onCancel: { model.cancelMacScan() })
            }
            StorageHero()
            SummaryTiles()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Space.l) {
                    FreeSpaceTrend().frame(maxWidth: .infinity)
                    CleanupBars().frame(maxWidth: .infinity)
                }
                VStack(spacing: Space.l) {
                    FreeSpaceTrend()
                    CleanupBars()
                }
            }
            if model.general.value != nil { RecommendationsSection() }
            if let restricted = model.general.value?.restrictedLocations, !restricted.isEmpty {
                PermissionNoticeView(title: "일부 위치는 읽을 수 없어 제외했습니다",
                                     message: "접근이 제한된 위치는 0 B가 아니라 ‘접근 제한’으로 표시됩니다.",
                                     paths: restricted)
            }
        }
    }
}

// MARK: - Storage donut

private struct DonutSlice: Identifiable, Equatable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
    var restricted = false
}

private struct StorageHero: View {
    @Environment(\.appModel) private var model
    @State private var selectedAngle: Double?

    private var slices: [DonutSlice] {
        guard let volume = model.volume else { return [] }
        let free = DonutSlice(id: "free", title: "사용 가능", bytes: volume.availableForImportantUsage, color: ClearColor.track)
        if let breakdown = model.storage.value {
            return categorySlices(breakdown.segments.map { ($0.id, $0.title, $0.bytes) }, unattributed: breakdown.unattributed) + [free]
        }
        if let stored = model.settingsStore.lastBreakdown {
            return categorySlices(stored.categories.map { ($0.id, $0.title, $0.bytes) }, unattributed: stored.unattributed) + [free]
        }
        return [DonutSlice(id: "used", title: "사용 중", bytes: volume.used, color: ClearColor.chart[0]), free]
    }

    /// Categories of at least 1 % of the disk get their own slice; the rest are
    /// folded into one "그 밖의 폴더" slice so the legend stays readable.
    private func categorySlices(_ items: [(String, String, Int64?)], unattributed: Int64) -> [DonutSlice] {
        let total = Double(max(model.volume?.totalCapacity ?? 1, 1))
        var result: [DonutSlice] = []
        var small: Int64 = 0
        for item in items {
            let bytes = item.2 ?? 0
            guard bytes > 0 else { continue }
            if Double(bytes) / total >= 0.01 && result.count < 6 {
                result.append(DonutSlice(id: item.0, title: item.1, bytes: bytes, color: ClearColor.chart[result.count % 6]))
            } else {
                small += bytes
            }
        }
        if small > 0 { result.append(DonutSlice(id: "small", title: "그 밖의 폴더", bytes: small, color: ClearColor.chart[6])) }
        result.append(DonutSlice(id: "other", title: "시스템 및 기타", bytes: unattributed, color: ClearColor.chart[7]))
        return result
    }

    private var breakdownCaption: String? {
        if model.storage.value != nil { return nil }
        if let stored = model.settingsStore.lastBreakdown {
            return "\(stored.date.formatted(.relative(presentation: .named))) 분석 기준 · 사용 가능 공간은 실시간"
        }
        return "Mac 스캔을 하면 카테고리별로 나눠 보여 줍니다"
    }

    private func slice(at angle: Double?) -> DonutSlice? {
        guard let angle else { return nil }
        var running = 0.0
        for s in slices {
            running += Double(s.bytes)
            if angle <= running { return s }
        }
        return nil
    }

    var body: some View {
        if let volume = model.volume {
            let selected = slice(at: selectedAngle)
            HStack(alignment: .center, spacing: Space.xxl) {
                ZStack {
                    Chart(slices) { s in
                        SectorMark(angle: .value("크기", Double(s.bytes)), innerRadius: .ratio(0.72), angularInset: 1.2)
                            .cornerRadius(3)
                            .foregroundStyle(s.color)
                            .opacity(selected == nil || selected?.id == s.id ? 1 : 0.35)
                    }
                    .chartLegend(.hidden)
                    .chartAngleSelection(value: $selectedAngle)
                    .animation(.easeOut(duration: 0.15), value: selected)
                    VStack(spacing: 2) {
                        Text((selected?.bytes ?? volume.availableForImportantUsage).formattedBytes)
                            .font(ClearFont.figure).contentTransition(.numericText())
                        Text(selected?.title ?? "사용 가능").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                    }
                    .allowsHitTesting(false)
                }
                .frame(width: 210, height: 210)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("저장공간: 전체 \(volume.totalCapacity.formattedBytes), 사용 가능 \(volume.availableForImportantUsage.formattedBytes)")

                VStack(alignment: .leading, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(volume.availableForImportantUsage.formattedBytes).font(ClearFont.display)
                                .contentTransition(.numericText())
                            Text("/ \(volume.totalCapacity.formattedBytes) 사용 가능").font(ClearFont.body).foregroundStyle(ClearColor.textSecondary)
                        }
                        Text("\(Int((volume.usedFraction * 100).rounded()))% 사용 중 · 제거 가능 공간 \(volume.purgeable.formattedBytes) 포함")
                            .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    }
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: 7) {
                        ForEach(slices.filter { $0.id != "free" }) { s in
                            GridRow {
                                RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 9, height: 9)
                                Text(s.title).font(ClearFont.callout)
                                    .foregroundStyle(selected?.id == s.id ? ClearColor.textPrimary : ClearColor.textSecondary)
                                Text(s.bytes.formattedBytes).font(ClearFont.numericSmall).gridColumnAlignment(.trailing)
                                Text(String(format: "%.0f%%", Double(s.bytes) / Double(max(volume.totalCapacity, 1)) * 100))
                                    .font(ClearFont.numericSmall).foregroundStyle(ClearColor.textTertiary).gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    if let caption = breakdownCaption {
                        Text(caption).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .panel(padding: Space.xl)
        } else {
            ErrorStateView(message: model.volumeError ?? "디스크 정보를 읽지 못했습니다.") { model.refreshVolume() }
        }
    }
}

// MARK: - Summary tiles

private struct SummaryTiles: View {
    @Environment(\.appModel) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Space.l) {
            safeTile
            trashTile
            historyTile
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var safeTile: some View {
        let safe = model.smartCleanCandidates
        let scanned = model.general.value != nil
        return DashboardTile(title: "안전하게 정리 가능", symbol: "sparkles",
                             value: scanned ? safe.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes : "—",
                             detail: scanned ? "검증된 캐시·로그 \(safe.count)개"
                                 : model.settingsStore.lastScan.map { "\($0.date.formatted(.relative(presentation: .named))) 분석 결과 \($0.safeBytes.formattedBytes) — 다시 스캔해 확인하세요" }
                                     ?? "Mac 스캔 후 표시됩니다") {
            if scanned {
                Button("정리…") { model.smartClean() }.primaryButton().disabled(safe.isEmpty || model.cleanup.isRunning)
            } else {
                Button("Mac 스캔") { model.scanMac() }.primaryButton().disabled(model.isScanningMac)
            }
        }
    }

    private var trashTile: some View {
        DashboardTile(title: "휴지통", symbol: "trash",
                      value: model.trashBytes?.formattedBytes ?? "—",
                      detail: model.trashBytes == nil ? "읽으려면 전체 디스크 접근이 필요합니다"
                          : (model.trashBytes ?? 0) > 0 ? "비워야 공간이 확보됩니다" : "비어 있습니다") {
            if model.trashBytes == nil {
                Button("권한 설정…") { model.openFullDiskAccessSettings() }.secondaryButton()
            } else {
                Button("비우기…") { model.emptyTrash() }.secondaryButton().disabled((model.trashBytes ?? 0) == 0)
            }
        }
    }

    private var historyTile: some View {
        let records = model.history.records
        // Only space actually freed: moving to the Trash frees nothing until it is
        // emptied, and counting both would count the same files twice.
        let total = records.reduce(Int64(0)) { $0 + $1.removedBytes }
        return DashboardTile(title: "지금까지 확보한 용량", symbol: "checkmark.seal",
                             value: total.formattedBytes,
                             detail: records.first.map { "\(records.count)회 · 최근 \($0.finishedAt.formatted(.relative(presentation: .named)))" }
                                 ?? "아직 정리 기록이 없습니다") {
            Button("기록 보기") { model.selection = .history }.secondaryButton().disabled(records.isEmpty)
        }
    }
}

private struct DashboardTile<Action: View>: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(title, systemImage: symbol).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
            Text(value).font(ClearFont.figure).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Charts

private struct FreeSpaceTrend: View {
    @Environment(\.appModel) private var model

    var body: some View {
        let samples = model.freeSpace.samples(lastDays: 30)
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("여유 공간 추이", subtitle: "최근 30일")
            if samples.count < 2 {
                ChartPlaceholder(symbol: "chart.xyaxis.line", text: "Clear를 사용하는 동안 30분 간격으로 기록이 쌓입니다.")
            } else {
                let values = samples.map { Double($0.available) / 1e9 }
                let low = (values.min() ?? 0), high = (values.max() ?? 1)
                let pad = max(2, (high - low) * 0.25)
                Chart(samples) { s in
                    AreaMark(x: .value("시각", s.date), yStart: .value("기준", max(0, low - pad)),
                             yEnd: .value("여유 공간", Double(s.available) / 1e9))
                        .foregroundStyle(LinearGradient(colors: [ClearColor.accentBright.opacity(0.28), ClearColor.accentBright.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("시각", s.date), y: .value("여유 공간", Double(s.available) / 1e9))
                        .foregroundStyle(ClearColor.accentBright)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: max(0, low - pad)...(high + pad))
                .chartYAxis { gbAxis }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day()).font(ClearFont.caption)
                    }
                }
                .frame(height: 150)
            }
        }
        .panel()
    }
}

private struct CleanupBars: View {
    @Environment(\.appModel) private var model

    private struct Bar: Identifiable {
        let id: UUID
        let label: String
        let gigabytes: Double
        let trash: Bool
    }

    var body: some View {
        let records = Array(model.history.records.prefix(8).reversed())
        let bars = records.flatMap { r -> [Bar] in
            let label = r.finishedAt.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
            return [Bar(id: r.id, label: label, gigabytes: Double(r.removedBytes) / 1e9, trash: false),
                    Bar(id: UUID(), label: label, gigabytes: Double(r.trashedBytes) / 1e9, trash: true)]
        }
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("최근 정리", subtitle: records.isEmpty ? nil : "최근 \(records.count)회")
            if records.isEmpty {
                ChartPlaceholder(symbol: "chart.bar", text: "정리를 실행하면 확보한 용량이 여기에 쌓입니다.")
            } else {
                Chart(bars) { b in
                    BarMark(x: .value("정리", b.label), y: .value("용량", b.gigabytes), width: .ratio(0.55))
                        .foregroundStyle(by: .value("방법", b.trash ? "휴지통으로 이동" : "즉시 삭제"))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(["즉시 삭제": ClearColor.accentBright, "휴지통으로 이동": ClearColor.chart[1]])
                .chartLegend(position: .top, alignment: .trailing)
                .chartYAxis { gbAxis }
                .chartXAxis(.hidden)
                .frame(height: 150)
            }
        }
        .panel()
    }
}

private var gbAxis: some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ClearColor.separator)
        AxisValueLabel {
            if let v = value.as(Double.self) { Text("\(v, format: .number.precision(.fractionLength(0...1)))GB").font(ClearFont.caption) }
        }
    }
}

private struct ChartPlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(ClearColor.textTertiary)
            Text(text).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

// MARK: - Recommendations

private struct RecommendationsSection: View {
    @Environment(\.appModel) private var model

    var body: some View {
        let top = Array(model.allScanCandidates.filter { $0.risk == .safe || $0.risk == .review }
            .sorted { $0.estimatedBytes > $1.estimatedBytes }.prefix(6))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("용량이 큰 정리 추천", subtitle: "전체 후보 \(model.cleanableBytes(model.allScanCandidates).formattedBytes)")
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, c in
                        if index > 0 { RowDivider(leading: 32) }
                        Button { model.selection = destination(for: c) } label: {
                            HStack(spacing: Space.s) {
                                SymbolTile(symbol: c.category.symbol)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.title).font(ClearFont.body).lineLimit(1)
                                    Text(c.riskReason).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1)
                                }
                                Spacer()
                                RiskBadge(risk: c.risk)
                                Text(c.estimatedBytes.formattedBytes).font(ClearFont.numeric).frame(minWidth: 72, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ClearColor.textTertiary)
                            }
                            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                    }
                }
                .panel(padding: Space.xs)
            }
        }
    }

    private func destination(for c: CleanupCandidate) -> SidebarItem {
        switch c.domain {
        case .developer, .projects: .developer
        case .aiTools: .aiTools
        default: .smartCleanup
        }
    }
}

// MARK: - Full Disk Access notice

/// Shown until granted or dismissed: one Full Disk Access grant replaces the
/// per-folder prompts and enables emptying the Trash.
private struct FullDiskAccessNotice: View {
    @Environment(\.appModel) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(ClearColor.accentBright)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("전체 디스크 접근을 한 번만 허용하세요").font(ClearFont.headline)
                Text("허용하면 문서·데스크탑 같은 폴더마다 접근을 묻지 않고, 휴지통 비우기와 앱 데이터 분석이 정확해집니다. 시스템 설정에서 Clear를 켠 뒤 이 화면으로 돌아오면 바로 적용됩니다.")
                    .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Button("시스템 설정 열기") { model.openFullDiskAccessSettings() }.primaryButton()
                    Button("나중에") { model.settingsStore.settings.fullDiskAccessNoticeDismissed = true }.buttonStyle(.borderless)
                }
                .padding(.top, Space.xs)
            }
            Spacer()
        }
        .panel()
    }
}
