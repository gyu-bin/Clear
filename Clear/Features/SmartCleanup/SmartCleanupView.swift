import SwiftUI

struct SmartCleanupView: View {
    @Environment(\.appModel) private var model
    @State private var filter: RiskFilter = .all
    @State private var search = ""
    @State private var focused: CleanupCandidate.ID?

    var body: some View {
        FixedPage(title: "스마트 청소", subtitle: "캐시 · 로그 · 임시 파일 · 다운로드") {
            if !model.general.isLoading && model.general.value != nil {
                Button { model.scanGeneral() } label: { Label(model.general.value == nil ? "스캔" : "다시 스캔", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        } content: {
            switch model.general {
            case .idle:
                EmptyStateView(symbol: "sparkles", title: "아직 분석하지 않았습니다",
                               message: "스캔은 파일을 읽기만 합니다. 확인 화면에서 승인한 항목만 정리됩니다.",
                               actionTitle: "스캔") { model.scanGeneral() }
                    .frame(maxHeight: .infinity)
            case .loading(let p):
                ScanProgressView(progress: p, onCancel: { model.cancel("general") }).padding(ClearMetrics.pagePadding)
            case .failed(let e):
                ErrorStateView(message: e) { model.scanGeneral() }.padding(ClearMetrics.pagePadding)
            case .loaded(let report, let date):
                results(report, date: date)
            }
        }
    }

    @ViewBuilder
    private func results(_ report: GeneralScanReport, date: Date) -> some View {
        @Bindable var model = model
        let visible = report.candidates.filter {
            filter.matches($0) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                                   || $0.subtitle.localizedCaseInsensitiveContains(search))
        }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .bottom) {
                    RiskSummary(candidates: report.candidates)
                    Spacer()
                    if let trash = report.trashSize, trash.allocated > 0 {
                        MetricView(title: "휴지통 (직접 비워야 함)", value: trash.allocated.formattedBytes, font: ClearFont.figureSmall)
                            .help("Clear는 휴지통을 비우지 않습니다. Finder에서 확인 후 비우세요.")
                    }
                }
                HStack {
                    Picker("필터", selection: $filter) { ForEach(RiskFilter.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    FreshnessLabel(date: date)
                    SearchField(prompt: "항목 검색", text: $search)
                }
                if !report.restrictedLocations.isEmpty {
                    PermissionNoticeView(title: "접근이 제한된 위치 \(report.restrictedLocations.count)곳은 제외했습니다",
                                         message: "크기를 알 수 없어 정리 후보에 넣지 않았습니다.", paths: report.restrictedLocations)
                }
            }
            .padding(.horizontal, ClearMetrics.pagePadding).padding(.vertical, Space.m)
            Divider()
            if report.candidates.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "정리할 항목이 없습니다", message: "나중에 다시 스캔해 보세요.")
                    .frame(maxHeight: .infinity)
            } else if visible.isEmpty {
                EmptyStateView(symbol: "line.3.horizontal.decrease", title: "해당하는 항목이 없습니다", message: "필터나 검색어를 바꿔 보세요.")
                    .frame(maxHeight: .infinity)
            } else {
                CandidateTable(candidates: visible, checked: $model.generalSelection, focused: $focused)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !report.candidates.isEmpty {
                CleanupActionBar(candidates: report.candidates, checked: $model.generalSelection) {
                    model.cleanup.review(title: "스마트 청소", candidates: report.candidates.filter { model.generalSelection.contains($0.id) })
                }
            }
        }
        .candidateInspector($focused, candidates: report.candidates)
    }
}
