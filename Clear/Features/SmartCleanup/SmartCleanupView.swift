import SwiftUI

/// "정크 파일" hub: one scan over everyday junk, developer and AI caches.
/// Summary first (what was found, what the smart selection would clean),
/// details on demand (the full table).
struct SmartCleanupView: View {
    @Environment(\.appModel) private var model
    @State private var showDetails = false
    @State private var group: JunkGroup?
    @State private var filter: RiskFilter = .all
    @State private var search = ""
    @State private var focused: CleanupCandidate.ID?

    var body: some View {
        FixedPage(title: "스마트 청소", subtitle: model.general.date.map { "\($0.formatted(.relative(presentation: .named))) 스캔" }) {
            if !model.isJunkScanning && model.general.value != nil {
                Button { model.scanJunk() } label: { Label("다시 스캔", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        } content: {
            if model.isJunkScanning {
                ScanProgressView(progress: model.general.progress ?? model.developer.progress ?? model.ai.progress
                                 ?? ScanProgress(phase: "마무리 중"),
                                 onCancel: { model.cancelJunkScan() })
                    .padding(ClearMetrics.pagePadding)
                Spacer()
            } else if let error = model.general.error {
                ErrorStateView(message: error) { model.scanJunk() }.padding(ClearMetrics.pagePadding)
                Spacer()
            } else if let report = model.general.value {
                if showDetails { details(report) } else { JunkSummary(report: report, showDetails: openDetails) }
            } else {
                EmptyStateView(symbol: "sparkles", title: "정크 파일을 찾아보세요",
                               message: "캐시·로그·브라우저 캐시·Xcode와 개발 도구 파일·스크린샷·삭제된 앱의 잔여 파일까지 한 번에 찾습니다. 스캔은 읽기만 합니다.",
                               actionTitle: "스캔") { model.scanJunk() }
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func openDetails(_ g: JunkGroup?) {
        group = g
        focused = nil
        showDetails = true
    }

    @ViewBuilder
    private func details(_ report: GeneralScanReport) -> some View {
        @Bindable var model = model
        let all = model.junkCandidates
        let visible = all.filter {
            (group == nil || JunkGroup.of($0) == group) && filter.matches($0)
                && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search))
        }
        ControlBar {
            Button { showDetails = false } label: { Label("요약", systemImage: "chevron.left") }.buttonStyle(.borderless)
            Picker("종류", selection: $group) {
                Text("모든 종류").tag(JunkGroup?.none)
                Divider()
                ForEach(JunkGroup.allCases) { g in Text(g.title).tag(JunkGroup?.some(g)) }
            }
            .fixedSize()
            Picker("위험도", selection: $filter) { ForEach(RiskFilter.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).fixedSize()
            Spacer()
            SearchField(prompt: "항목 검색", text: $search)
        }
        .labelsHidden()
        if !report.restrictedLocations.isEmpty {
            PermissionNoticeView(title: "접근이 제한된 위치 \(report.restrictedLocations.count)곳은 제외했습니다",
                                 message: "크기를 알 수 없어 정리 후보에 넣지 않았습니다.", paths: report.restrictedLocations)
                .padding(.horizontal, ClearMetrics.pagePadding).padding(.vertical, Space.s)
            Divider()
        }
        if visible.isEmpty {
            EmptyStateView(symbol: "line.3.horizontal.decrease", title: "해당하는 항목이 없습니다", message: "종류·위험도·검색어를 바꿔 보세요.")
                .frame(maxHeight: .infinity)
        } else {
            CandidateTable(candidates: visible, checked: $model.junkSelection, focused: $focused)
                .candidateInspector($focused, candidates: all)
        }
        CleanupActionBar(candidates: all, checked: $model.junkSelection) {
            model.cleanup.review(title: "스마트 청소", candidates: all.filter { model.junkSelection.contains($0.id) })
        }
    }
}

/// Summary in the spirit of "발견된 파일 → 종류별 → 스마트 선택 → 정리".
private struct JunkSummary: View {
    let report: GeneralScanReport
    let showDetails: (JunkGroup?) -> Void
    @Environment(\.appModel) private var model

    var body: some View {
        let all = model.junkCandidates.filter { $0.risk != .blocked }
        let groups = Dictionary(grouping: all, by: JunkGroup.of)
            .map { (group: $0.key, items: $0.value, bytes: $0.value.reduce(0) { $0 + $1.estimatedBytes }) }
            .sorted { $0.bytes > $1.bytes }
        let total = all.reduce(0) { $0 + $1.estimatedBytes }
        let selected = all.filter { model.junkSelection.contains($0.id) }
        let selectedBytes = selected.reduce(0) { $0 + $1.estimatedBytes }

        ScrollView {
            VStack(spacing: Space.xl) {
                VStack(spacing: Space.xs) {
                    Text("발견된 항목").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    ByteFigure(bytes: total, font: .system(size: 40, weight: .semibold).monospacedDigit())
                    Text("\(all.count)개 항목 · \(model.general.date?.formatted(.relative(presentation: .named)) ?? "") 스캔")
                        .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                .padding(.top, Space.xl)

                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.group) { index, entry in
                        if index > 0 { RowDivider(leading: 40) }
                        Button { showDetails(entry.group) } label: {
                            HStack(spacing: Space.m) {
                                Image(systemName: entry.group.symbol).foregroundStyle(entry.group.color).frame(width: 20)
                                Text(entry.group.title).font(ClearFont.body)
                                Spacer()
                                let safe = entry.items.filter { $0.risk == .safe }.count
                                if safe > 0 { Text("안전 \(safe)").font(ClearFont.caption).foregroundStyle(ClearColor.success) }
                                Text("\(entry.items.count)개").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textTertiary)
                                Text(entry.bytes.formattedBytes).font(ClearFont.numeric).frame(minWidth: 76, alignment: .trailing)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ClearColor.textTertiary)
                            }
                            .padding(.horizontal, Space.m).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .accessibilityHint("세부 정보 보기")
                    }
                    infoRows
                }
                .panel(padding: Space.xs)

                VStack(spacing: Space.m) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text("스마트 선택").font(ClearFont.body).foregroundStyle(ClearColor.textSecondary)
                        ByteFigure(bytes: selectedBytes, font: .system(size: 28, weight: .semibold).monospacedDigit())
                    }
                    let heldBack = all.filter { $0.risk == .safe && !$0.runningGuards.isEmpty }
                    Text(selected.isEmpty ? "선택된 항목이 없습니다. 세부 정보에서 직접 고를 수 있습니다."
                                          : "검증된 캐시·로그 등 \(selected.count)개")
                        .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    if !heldBack.isEmpty {
                        let apps = Array(Set(heldBack.flatMap(\.runningGuards))).sorted().prefix(3).joined(separator: ", ")
                        Text("안전 항목 \(heldBack.count)개(\(heldBack.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes))는 \(apps)이(가) 실행 중이라 선택하지 않았습니다. 앱을 종료하고 다시 스캔하면 포함됩니다.")
                            .font(ClearFont.caption).foregroundStyle(ClearColor.warning).multilineTextAlignment(.center)
                    }
                    HStack(spacing: Space.m) {
                        Button("세부 정보 보기") { showDetails(nil) }.secondaryButton(large: true)
                        Button("정리…") {
                            model.cleanup.review(title: "스마트 청소", candidates: selected)
                        }
                        .primaryButton(large: true)
                        .frame(minWidth: 140)
                        .disabled(selected.isEmpty || model.cleanup.isRunning)
                    }
                }
                .padding(.bottom, Space.xl)
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, ClearMetrics.pagePadding)
            .frame(maxWidth: .infinity)
        }
    }

    /// Facts that are not cleanable by Clear, shown so the numbers add up.
    @ViewBuilder private var infoRows: some View {
        if let volume = model.volume, volume.purgeable > 0 {
            RowDivider(leading: 40)
            infoRow("internaldrive", "제거 가능 공간", volume.purgeable,
                    "macOS가 공간이 필요할 때 자동으로 비웁니다. 직접 지울 수 없어 합계에서 제외했습니다.")
        }
        if let logs = report.systemLogBytes, logs > 0 {
            RowDivider(leading: 40)
            infoRow("lock.doc", "시스템 로그", logs, "관리자 권한이 필요해 Clear는 지우지 않습니다.")
        }
        if let trash = model.trashBytes, trash > 0 {
            RowDivider(leading: 40)
            HStack(spacing: Space.m) {
                Image(systemName: "trash").foregroundStyle(ClearColor.textTertiary).frame(width: 20)
                Text("휴지통").font(ClearFont.body).foregroundStyle(ClearColor.textSecondary)
                Spacer()
                Button("비우기…") { model.emptyTrash() }.buttonStyle(.link).font(ClearFont.callout)
                Text(trash.formattedBytes).font(ClearFont.numeric).foregroundStyle(ClearColor.textSecondary)
                    .frame(minWidth: 76, alignment: .trailing)
                Color.clear.frame(width: 10)
            }
            .padding(.horizontal, Space.m).padding(.vertical, 10)
        }
    }

    private func infoRow(_ symbol: String, _ title: String, _ bytes: Int64, _ help: String) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol).foregroundStyle(ClearColor.textTertiary).frame(width: 20)
            Text(title).font(ClearFont.body).foregroundStyle(ClearColor.textSecondary)
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(ClearColor.textTertiary).help(help)
            Spacer()
            Text("정리 대상 아님").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
            Text(bytes.formattedBytes).font(ClearFont.numeric).foregroundStyle(ClearColor.textSecondary)
                .frame(minWidth: 76, alignment: .trailing)
            Color.clear.frame(width: 10)
        }
        .padding(.horizontal, Space.m).padding(.vertical, 10)
        .help(help)
    }
}
