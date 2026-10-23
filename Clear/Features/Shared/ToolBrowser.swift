import SwiftUI

/// Tool list on the left, the selected tool's data and candidates on the right.
/// Shared by Developer and AI Tools.
struct ToolBrowser: View {
    let reports: [ToolReport]
    @Binding var checked: Set<String>
    let reviewTitle: String
    @Environment(\.appModel) private var model
    @State private var selectedToolID: String?
    @State private var focused: CleanupCandidate.ID?

    private var installed: [ToolReport] { reports.filter(\.installed) }
    private var allCandidates: [CleanupCandidate] { reports.flatMap(\.candidates) }
    private var current: ToolReport? {
        installed.first { $0.id == selectedToolID } ?? installed.first
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { current?.id }, set: { selectedToolID = $0; focused = nil })) {
                Section("감지됨") {
                    ForEach(installed) { report in
                        ToolRow(report: report).tag(report.id)
                    }
                }
                let missing = reports.filter { !$0.installed }
                if !missing.isEmpty {
                    Section("감지되지 않음") {
                        ForEach(missing) { report in
                            Label(report.name, systemImage: report.symbol).foregroundStyle(.tertiary).selectionDisabled()
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: 250)
            Divider()

            Group {
                if let report = current {
                    ToolDetail(report: report, checked: $checked, focused: $focused)
                } else {
                    EmptyStateView(symbol: "questionmark.folder", title: "감지된 도구가 없습니다", message: "설치된 도구가 없거나 데이터 폴더를 찾지 못했습니다.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !allCandidates.isEmpty {
                CleanupActionBar(candidates: allCandidates, checked: $checked) {
                    model.cleanup.review(title: reviewTitle, candidates: allCandidates.filter { checked.contains($0.id) })
                }
            }
        }
        .candidateInspector($focused, candidates: allCandidates)
    }
}

private struct ToolRow: View {
    let report: ToolReport

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: report.symbol).frame(width: 18).foregroundStyle(ClearColor.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(report.name).lineLimit(1)
                    if !report.runningProcesses.isEmpty {
                        Circle().fill(ClearColor.warning).frame(width: 6, height: 6).help("실행 중")
                    }
                }
                Text(report.version ?? "버전 정보 없음").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1)
            }
            Spacer()
            Text(report.cleanableBytes.formattedBytes).font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ToolDetail: View {
    let report: ToolReport
    @Binding var checked: Set<String>
    @Binding var focused: CleanupCandidate.ID?
    @State private var showProtected = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(report.name).font(ClearFont.pageTitle)
                    if let v = report.version { Text(v).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary) }
                    if !report.runningProcesses.isEmpty {
                        TagBadge(text: "실행 중", tint: ClearColor.warning).help(report.runningProcesses.joined(separator: ", "))
                    }
                    Spacer()
                }
                HStack(spacing: Space.xxl) {
                    MetricView(title: "정리 가능", value: report.cleanableBytes.formattedBytes)
                    MetricView(title: "보호된 데이터", value: report.protectedBytes.formattedBytes)
                    MetricView(title: "전체 데이터", value: report.measuredBytes.formattedBytes)
                }
                if let error = report.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(ClearFont.callout).foregroundStyle(ClearColor.warning)
                }
                ForEach(report.notes, id: \.self) { note in
                    Text(note).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                }
                let protected = report.locations.filter(\.isProtected)
                if !protected.isEmpty {
                    DisclosureGroup(isExpanded: $showProtected) {
                        VStack(spacing: Space.xs) {
                            ForEach(protected) { loc in
                                HStack(spacing: Space.s) {
                                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(ClearColor.textTertiary)
                                    Text(loc.title).font(ClearFont.callout)
                                    Text(loc.role.title).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                                    Spacer()
                                    Text(loc.size?.allocated.formattedBytes ?? "접근 제한").font(ClearFont.numericSmall)
                                        .foregroundStyle(loc.size == nil ? ClearColor.warning : ClearColor.textSecondary)
                                }
                                .help(loc.note ?? PathUtilities.abbreviated(loc.path))
                            }
                        }
                        .padding(.top, Space.xs)
                    } label: {
                        Text("보호된 데이터 \(protected.count)곳 — 정리 대상에서 제외").font(ClearFont.callout)
                    }
                }
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
            Divider()
            if report.candidates.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "정리할 항목이 없습니다", message: "이 도구에서 정리할 수 있는 데이터를 찾지 못했습니다.")
                    .frame(maxHeight: .infinity)
            } else {
                CandidateTable(candidates: report.candidates, checked: $checked, focused: $focused, showsCategory: false)
            }
        }
    }
}
