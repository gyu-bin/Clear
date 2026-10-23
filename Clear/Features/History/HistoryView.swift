import SwiftUI

private struct HistoryRow: Identifiable {
    let report: CleanupReport
    var id: UUID { report.id }
    var date: Date { report.finishedAt }
    var title: String { report.title }
    var cleaned: Int64 { report.removedBytes + report.trashedBytes }
    var failures: Int { report.failed.count }
}

struct HistoryView: View {
    @Environment(\.appModel) private var model
    @State private var confirmClear = false
    @State private var selection: UUID?
    @State private var sortOrder = [KeyPathComparator(\HistoryRow.date, order: .reverse)]

    var body: some View {
        let records = model.history.records
        FixedPage(title: "정리 기록", subtitle: records.isEmpty ? nil : "\(records.count)회 · 보관 \(model.settings.historyRetentionDays == 0 ? "무제한" : "\(model.settings.historyRetentionDays)일")") {
            Button("기록 지우기…") { confirmClear = true }.disabled(records.isEmpty)
        } content: {
            VStack(spacing: 0) {
                if let error = model.history.loadError {
                    ErrorStateView(message: error).padding(.horizontal, ClearMetrics.pagePadding)
                    Divider()
                }
                if records.isEmpty {
                    EmptyStateView(symbol: "clock", title: "정리 기록이 없습니다", message: "정리를 실행하면 항목별 결과가 이 Mac에만 기록됩니다.")
                        .frame(maxHeight: .infinity)
                } else {
                    let rows = records.map(HistoryRow.init).sorted(using: sortOrder)
                    Table(rows, selection: $selection, sortOrder: $sortOrder) {
                        TableColumn("날짜", value: \.date) { r in Text(r.date.formatted(date: .abbreviated, time: .shortened)) }
                            .width(min: 120, ideal: 150)
                        TableColumn("작업", value: \.title) { r in Text(r.title).lineLimit(1) }
                            .width(min: 120, ideal: 200)
                        TableColumn("결과", value: \.failures) { r in
                            HStack(spacing: Space.xs) {
                                Circle().fill(r.report.failed.isEmpty && !r.report.wasCancelled ? ClearColor.success : ClearColor.warning).frame(width: 6, height: 6)
                                Text("성공 \(r.report.succeeded.count) · 실패 \(r.report.failed.count) · 건너뜀 \(r.report.skipped.count)")
                                    .foregroundStyle(ClearColor.textSecondary)
                            }
                        }
                        .width(min: 150, ideal: 190)
                        TableColumn("정리량", value: \.cleaned) { r in
                            Text(r.cleaned.formattedBytes).font(ClearFont.numeric).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 70, ideal: 90)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .detailPane(isPresented: records.contains { $0.id == selection }, onClose: { selection = nil }) {
            if let report = records.first(where: { $0.id == selection }) { HistoryDetail(report: report).id(report.id) }
        }
        .confirmationDialog("모든 정리 기록을 지울까요?", isPresented: $confirmClear) {
            Button("기록 지우기", role: .destructive) { model.history.removeAll(); selection = nil }
        } message: {
            Text("파일에는 영향을 주지 않으며 기록만 삭제됩니다.")
        }
    }
}

private struct HistoryDetail: View {
    let report: CleanupReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(report.title).font(ClearFont.headline).padding(.trailing, Space.xl)
                    Text(report.finishedAt.formatted(date: .complete, time: .shortened)).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                }
                Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
                    row("즉시 확보", report.removedBytes.formattedBytes)
                    row("휴지통으로 이동", report.trashedBytes.formattedBytes)
                    row("실측 여유 공간 변화", report.measuredFreedBytes.map { ($0 >= 0 ? "+" : "") + $0.formattedBytes } ?? "측정 불가")
                }
                Text("APFS 특성(클론·스냅샷)과 다른 앱의 쓰기 때문에 실측 변화는 삭제한 크기와 다를 수 있습니다.")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                Divider()
                ForEach(report.results) { r in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: icon(r.status)).foregroundStyle(color(r.status)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).font(ClearFont.callout)
                            if let path = r.path {
                                Text(PathUtilities.abbreviated(path)).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Text(r.message.map { "\(r.status.title) — \($0)" } ?? r.status.title)
                                .font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                        }
                        Spacer()
                        Text(r.estimatedBytes.formattedBytes).font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
                    }
                    .contextMenu { if let trash = r.trashLocation { Button("휴지통에서 보기") { FinderActions.reveal(trash) } } }
                }
            }
            .padding(Space.l)
        }
    }

    private func row(_ t: String, _ v: String) -> some View {
        GridRow {
            Text(t).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
            Text(v).font(ClearFont.numeric)
        }
    }

    private func icon(_ s: CleanupItemStatus) -> String {
        switch s {
        case .removed, .commandSucceeded, .trashed: "checkmark.circle"
        case .alreadyGone: "circle.dashed"
        case .skipped: "forward"
        case .failed: "xmark.circle"
        case .cancelled: "stop.circle"
        }
    }

    private func color(_ s: CleanupItemStatus) -> Color {
        switch s {
        case .removed, .trashed, .commandSucceeded: ClearColor.success
        case .alreadyGone, .cancelled: ClearColor.textTertiary
        case .skipped: ClearColor.warning
        case .failed: ClearColor.danger
        }
    }
}
