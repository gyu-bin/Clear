import SwiftUI

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
            HeroSection()
            Divider()
            DiskSection()
            if model.general.value != nil {
                Divider()
                CandidatesSection()
                RecommendationsSection()
            }
            Divider()
            FooterSection()
            if let restricted = model.general.value?.restrictedLocations, !restricted.isEmpty {
                PermissionNoticeView(title: "일부 위치는 읽을 수 없어 제외했습니다",
                                     message: "접근이 제한된 위치는 0 B가 아니라 ‘접근 제한’으로 표시됩니다. 전체 디스크 접근을 허용하면 더 정확해집니다.",
                                     paths: restricted)
            }
        }
    }
}

// MARK: 1 + 3. Safely reclaimable space and the one-click action

private struct HeroSection: View {
    @Environment(\.appModel) private var model

    var body: some View {
        if model.isScanningMac {
            ScanProgressView(progress: model.general.progress ?? model.developer.progress ?? model.ai.progress
                             ?? model.storage.progress ?? ScanProgress(phase: "마무리 중"),
                             onCancel: { model.cancelMacScan() })
        } else if model.general.value != nil {
            let safe = model.smartCleanCandidates
            HStack(alignment: .center, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("안전하게 정리할 수 있는 공간").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    ByteFigure(bytes: safe.reduce(0) { $0 + $1.estimatedBytes }, font: ClearFont.display)
                    Text(safe.isEmpty ? "지금은 자동으로 정리할 항목이 없습니다."
                                      : "재생성되는 캐시·로그 \(safe.count)개 · 실행 전에 항목을 다시 확인합니다")
                        .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                Spacer()
                Button("안전 항목 정리…") { model.smartClean() }
                    .primaryButton(large: true)
                    .disabled(safe.isEmpty || model.cleanup.isRunning)
                    .help("⇧⌘K")
            }
        } else {
            HStack(alignment: .center, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("아직 분석하지 않았습니다").font(ClearFont.pageTitle)
                    Group {
                        if let last = model.settingsStore.lastScan {
                            Text("지난 분석(\(last.date.formatted(.relative(presentation: .named))))의 결과는 현재 상태와 다를 수 있어 표시하지 않습니다.")
                        } else {
                            Text("Mac을 스캔해 정리할 수 있는 공간을 찾습니다. 스캔은 파일을 읽기만 합니다.")
                        }
                    }
                    .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                }
                Spacer()
                Button("Mac 스캔") { model.scanMac() }.primaryButton(large: true)
            }
        }
    }
}

// MARK: 2. Disk usage

private struct DiskSection: View {
    @Environment(\.appModel) private var model

    var body: some View {
        if let volume = model.volume {
            let candidates = model.general.value.map { _ in model.cleanableBytes(model.allScanCandidates) } ?? 0
            let reclaim = min(candidates, volume.used)
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xl) {
                    MetricView(title: "전체", value: volume.totalCapacity.formattedBytes)
                    MetricView(title: "사용 중", value: volume.used.formattedBytes)
                    MetricView(title: "사용 가능", value: volume.availableForImportantUsage.formattedBytes,
                               valueColor: volume.usedFraction > 0.9 ? ClearColor.danger : ClearColor.textPrimary)
                    Spacer()
                    Text("\(Int((volume.usedFraction * 100).rounded()))% 사용").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
                }
                CapacityBar(segments: [
                    CapacitySegment(id: "used", title: "사용 중", bytes: volume.used - reclaim, color: ClearColor.textSecondary.opacity(0.55)),
                    CapacitySegment(id: "reclaim", title: "정리 후보", bytes: reclaim, color: ClearColor.accentBright),
                ], total: volume.totalCapacity)
                HStack(spacing: Space.l) {
                    LegendItem(segment: CapacitySegment(id: "used", title: "사용 중", bytes: volume.used - reclaim, color: ClearColor.textSecondary.opacity(0.55)))
                    if model.general.value != nil {
                        LegendItem(segment: CapacitySegment(id: "reclaim", title: "정리 후보", bytes: reclaim, color: ClearColor.accentBright))
                    }
                    LegendItem(segment: CapacitySegment(id: "free", title: "사용 가능", bytes: volume.availableForImportantUsage, color: ClearColor.track))
                    Spacer()
                    if volume.purgeable > 0 {
                        Text("제거 가능 공간 \(volume.purgeable.formattedBytes) 포함").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                            .help("macOS가 필요할 때 자동으로 비우는 공간이 사용 가능 공간에 포함되어 있습니다.")
                    }
                }
                CategoryBreakdown(volume: volume)
            }
        } else {
            ErrorStateView(message: model.volumeError ?? "디스크 정보를 읽지 못했습니다.") { model.refreshVolume() }
        }
    }
}

private struct CategoryBreakdown: View {
    @Environment(\.appModel) private var model
    let volume: VolumeInfo

    var body: some View {
        switch model.storage {
        case .loaded(let breakdown, _):
            let used = max(1, Double(volume.used))
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader("카테고리별 사용량")
                ForEach(Array(breakdown.segments.enumerated()), id: \.element.id) { index, seg in
                    ProportionRow(title: seg.title, bytes: seg.bytes, fraction: Double(seg.bytes ?? 0) / used,
                                  color: ClearColor.chart[index % ClearColor.chart.count])
                }
                ProportionRow(title: "시스템 및 기타", bytes: breakdown.unattributed, fraction: Double(breakdown.unattributed) / used,
                              color: ClearColor.textTertiary)
            }
            .padding(.top, Space.s)
        case .loading(let p):
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(p.detail.isEmpty ? p.phase : "\(p.phase) · \(p.detail)").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
            }
        case .failed(let e):
            Text(e).font(ClearFont.caption).foregroundStyle(ClearColor.danger)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: 4. All candidates

private struct CandidatesSection: View {
    @Environment(\.appModel) private var model

    var body: some View {
        let all = model.allScanCandidates.filter { $0.risk != .blocked }
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("전체 정리 후보", subtitle: "\(all.count)개 · \(model.cleanableBytes(all).formattedBytes)")
            HStack(alignment: .bottom) {
                RiskSummary(candidates: all)
                Spacer()
            }
            VStack(spacing: 0) {
                domainRow("일반", symbol: "sparkles", state: model.general.isLoading ? nil : model.general.value?.candidates, target: .smartCleanup, enabled: true)
                RowDivider(leading: 32)
                domainRow("개발자 도구", symbol: "hammer", state: model.developer.isLoading ? nil : model.developer.value?.flatMap(\.candidates),
                          target: .developer, enabled: model.settings.developerModeEnabled)
                RowDivider(leading: 32)
                domainRow("AI 도구", symbol: "brain", state: model.ai.isLoading ? nil : model.ai.value?.flatMap(\.candidates),
                          target: .aiTools, enabled: model.settings.aiToolsEnabled)
            }
            .panel(padding: Space.xs)
        }
    }

    private func domainRow(_ title: String, symbol: String, state: [CleanupCandidate]?, target: SidebarItem, enabled: Bool) -> some View {
        Button { model.selection = target } label: {
            HStack(spacing: Space.s) {
                SymbolTile(symbol: symbol)
                Text(title).font(ClearFont.body)
                Spacer()
                if !enabled {
                    Text("꺼짐").font(ClearFont.callout).foregroundStyle(ClearColor.textTertiary)
                } else if let items = state {
                    let open = items.filter { $0.risk != .blocked }
                    Text("\(open.count)개").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textTertiary)
                    Text(open.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes).font(ClearFont.numeric).frame(minWidth: 72, alignment: .trailing)
                } else {
                    Text("분석 전").font(ClearFont.callout).foregroundStyle(ClearColor.textTertiary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ClearColor.textTertiary)
            }
            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .accessibilityHint("\(target.title) 화면으로 이동")
    }
}

// MARK: 5. Largest recommendations

private struct RecommendationsSection: View {
    @Environment(\.appModel) private var model

    var body: some View {
        let top = Array(model.allScanCandidates.filter { $0.risk == .safe || $0.risk == .review }
            .sorted { $0.estimatedBytes > $1.estimatedBytes }.prefix(6))
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("용량이 큰 정리 추천")
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

// MARK: 6. Recent activity

private struct FooterSection: View {
    @Environment(\.appModel) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Space.xxl) {
            if let last = model.history.lastReport {
                MetricView(title: "최근 정리", value: last.finishedAt.formatted(.relative(presentation: .named)),
                           detail: "삭제 \(last.removedBytes.formattedBytes) · 휴지통 \(last.trashedBytes.formattedBytes)",
                           font: ClearFont.body.weight(.medium))
            } else {
                MetricView(title: "최근 정리", value: "기록 없음", font: ClearFont.body.weight(.medium))
            }
            if let trash = model.general.value?.trashSize {
                VStack(alignment: .leading, spacing: Space.xs) {
                    MetricView(title: "휴지통", value: trash.allocated.formattedBytes, font: ClearFont.body.weight(.medium))
                    if trash.allocated > 0 {
                        Button("휴지통 비우기…") { model.emptyTrash() }.buttonStyle(.link).font(ClearFont.caption)
                    }
                }
            }
            if let date = model.general.date {
                MetricView(title: "마지막 스캔", value: date.formatted(date: .omitted, time: .shortened), font: ClearFont.body.weight(.medium))
            }
            Spacer()
        }
    }
}

/// Shown once until granted or dismissed: one Full Disk Access grant replaces the
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
