import SwiftUI

/// Confirm → progress → result. The only UI path that can start a deletion.
struct CleanupSheet: View {
    @Environment(\.appModel) private var model

    var body: some View {
        Group {
            switch model.cleanup.phase {
            case .idle: EmptyView()
            case .reviewing(let plan): ConfirmView(plan: plan)
            case .running(let plan, let progress): RunningView(plan: plan, progress: progress)
            case .finished(let report): ResultView(report: report)
            case .message(let text): MessageView(text: text)
            }
        }
        .frame(width: 600)
        .interactiveDismissDisabled(model.cleanup.isRunning)
    }
}

private struct ConfirmView: View {
    let plan: CleanupPlan
    @Environment(\.appModel) private var model

    var body: some View {
        @Bindable var cleanup = model.cleanup
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(plan.items.count)개 항목을 정리할까요?").font(ClearFont.pageTitle)
                    Text("실행 직전 각 항목의 경로·식별자·실행 중인 앱을 다시 확인하고, 조건이 바뀐 항목은 건너뜁니다.")
                        .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                }
                HStack(spacing: Space.xxl) {
                    MetricView(title: "예상 크기", value: plan.estimatedBytes.formattedBytes)
                    MetricView(title: "휴지통으로 이동", value: plan.trashBytes.formattedBytes, detail: "복구 가능")
                    MetricView(title: "즉시 삭제", value: plan.permanentBytes.formattedBytes, detail: "재생성되는 캐시만")
                }
            }
            .padding(Space.xl)
            Divider()
            List(plan.items) { item in
                HStack(spacing: Space.s) {
                    Image(systemName: item.candidate.category.symbol).foregroundStyle(ClearColor.textSecondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.candidate.title).lineLimit(1)
                        Text(item.candidate.subtitle).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let running = model.cleanup.runningByItem[item.id] {
                        TagBadge(text: "\(running.joined(separator: ", ")) 실행 중", tint: ClearColor.warning)
                            .help("실행 중인 앱의 데이터는 정리하지 않고 건너뜁니다. 앱을 종료하면 정리할 수 있습니다.")
                    } else {
                        RiskBadge(risk: item.candidate.risk)
                    }
                    Text(methodText(item)).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary).frame(width: 96, alignment: .trailing)
                    Text(item.candidate.estimatedBytes.formattedBytes).font(ClearFont.numericSmall).frame(width: 70, alignment: .trailing)
                }
                .help(item.candidate.impact)
            }
            .listStyle(.inset)
            .frame(height: min(260, CGFloat(plan.items.count) * 38 + 16))
            Divider()
            VStack(alignment: .leading, spacing: Space.s) {
                RunningAppsNotice(plan: plan)
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.triangle").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                }
                if !plan.excluded.isEmpty {
                    Label("\(plan.excluded.count)개는 제외됨 (보호 대상이거나 상위 폴더와 함께 정리)", systemImage: "minus.circle")
                        .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                if plan.requiresExplicitAcknowledgement {
                    Toggle("‘직접 선택’ 항목과 명령 항목을 확인했으며 정리에 동의합니다", isOn: $cleanup.acknowledged)
                        .toggleStyle(.checkbox).font(ClearFont.callout).padding(.top, Space.xs)
                }
                HStack {
                    Spacer()
                    Button("취소") { model.cleanup.dismiss() }.keyboardShortcut(.cancelAction).secondaryButton()
                    let runnable = model.cleanup.runnableCount(plan)
                    Button(runnable == plan.items.count || runnable == 0 ? "정리" : "\(runnable)개 정리") { model.cleanup.confirm() }
                        .primaryButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(runnable == 0 || model.cleanup.isQuittingApps
                                  || (plan.requiresExplicitAcknowledgement && !model.cleanup.acknowledged))
                        .help(runnable == 0 ? "모든 항목이 실행 중인 앱의 데이터입니다. 앱을 종료한 뒤 정리하세요." : "")
                }
                .padding(.top, Space.s)
            }
            .padding(Space.xl)
        }
    }

    private func methodText(_ item: CleanupPlanItem) -> String {
        if case .command = item.candidate.target { return "공식 명령" }
        return item.method == .trash ? "휴지통" : "즉시 삭제"
    }
}

/// Explains which apps block items and offers to quit them normally.
private struct RunningAppsNotice: View {
    let plan: CleanupPlan
    @Environment(\.appModel) private var model

    var body: some View {
        let blocked = plan.items.filter { model.cleanup.runningByItem[$0.id] != nil }
        if !blocked.isEmpty {
            let apps = model.cleanup.blockingApps(plan)
            let names = Array(Set(blocked.flatMap { model.cleanup.runningByItem[$0.id] ?? [] })).sorted()
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ClearColor.warning)
                    Text("\(names.joined(separator: ", "))이(가) 실행 중이라 \(blocked.count)개 항목은 정리할 수 없습니다.")
                        .font(ClearFont.callout)
                    Spacer()
                    if model.cleanup.isQuittingApps {
                        ProgressView().controlSize(.small)
                        Text("종료하는 중…").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                    } else if !apps.isEmpty {
                        Button(apps.count == 1 ? "\(apps[0].localizedName ?? "앱") 종료" : "앱 \(apps.count)개 종료") {
                            model.cleanup.quitBlockingApps()
                        }
                        .secondaryButton()
                        .help("일반 종료(⌘Q)와 같습니다. 저장하지 않은 작업이 있으면 앱이 먼저 물어봅니다.")
                    }
                }
                Text(apps.isEmpty
                     ? "터미널 등에서 실행 중인 도구를 종료한 뒤 다시 시도하세요."
                     : "앱을 종료하면 바로 정리할 수 있습니다. 실행 중인 앱의 캐시를 지우면 앱이 오작동할 수 있어 건너뜁니다.")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary).padding(.leading, 22)
                if !model.cleanup.quitFailures.isEmpty {
                    Text("\(model.cleanup.quitFailures.joined(separator: ", "))이(가) 아직 종료되지 않았습니다. 앱에서 저장 여부를 묻고 있는지 확인하세요.")
                        .font(ClearFont.caption).foregroundStyle(ClearColor.warning).padding(.leading, 22)
                }
            }
            .padding(.bottom, Space.xs)
        }
    }
}

private struct RunningView: View {
    let plan: CleanupPlan
    let progress: CleanupProgress
    @Environment(\.appModel) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("정리 중").font(ClearFont.pageTitle)
            ProgressView(value: progress.fraction).tint(ClearColor.accentBright)
            Text("\(progress.completed) / \(progress.total)  \(progress.currentTitle)").font(ClearFont.numericSmall)
                .foregroundStyle(ClearColor.textSecondary).lineLimit(1)
            HStack {
                Text("취소하면 현재 항목 이후는 실행되지 않습니다.").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                Spacer()
                Button("취소") { model.cleanup.cancel() }.secondaryButton()
            }
        }
        .padding(Space.xl)
    }
}

private struct ResultView: View {
    let report: CleanupReport
    @Environment(\.appModel) private var model

    private var outcome: (title: String, symbol: String, color: Color) {
        let done = report.results.filter { $0.status == .removed || $0.status == .trashed || $0.status == .commandSucceeded }
        if report.wasCancelled { return ("정리를 취소했습니다", "stop.circle.fill", ClearColor.warning) }
        if done.isEmpty && !report.results.isEmpty {
            return ("정리하지 못했습니다", "exclamationmark.circle.fill", ClearColor.warning)
        }
        if !report.failed.isEmpty || !report.skipped.isEmpty {
            return ("일부 항목만 정리했습니다", "exclamationmark.circle.fill", ClearColor.warning)
        }
        return ("정리를 마쳤습니다", "checkmark.circle.fill", ClearColor.success)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Image(systemName: outcome.symbol)
                    .font(.system(size: 20)).foregroundStyle(outcome.color)
                    .symbolEffect(.bounce, value: report.id)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(outcome.title)
                        .font(ClearFont.pageTitle)
                    Text("성공 \(report.succeeded.count) · 실패 \(report.failed.count) · 건너뜀 \(report.skipped.count)")
                        .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                }
            }
            HStack(spacing: Space.xxl) {
                MetricView(title: "즉시 확보", value: report.removedBytes.formattedBytes)
                MetricView(title: "휴지통으로 이동", value: report.trashedBytes.formattedBytes, detail: "휴지통을 비우면 확보")
                MetricView(title: "실측 여유 공간 변화",
                           value: report.measuredFreedBytes.map { ($0 >= 0 ? "+" : "") + $0.formattedBytes } ?? "측정 불가",
                           detail: "APFS 특성상 다를 수 있음")
            }
            let problems = report.results.filter { $0.status == .failed || $0.status == .skipped }
            if !problems.isEmpty {
                Text("정리되지 않은 항목").font(ClearFont.captionEmphasis).foregroundStyle(ClearColor.textSecondary)
                List(problems) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title).font(ClearFont.callout)
                        Text(r.message ?? r.status.title).font(ClearFont.caption)
                            .foregroundStyle(r.status == .failed ? ClearColor.danger : ClearColor.textSecondary)
                    }
                }
                .listStyle(.inset)
                .frame(height: min(180, CGFloat(problems.count) * 40 + 12))
            }
            HStack {
                Button("기록 보기") {
                    model.cleanup.dismiss()
                    model.selection = .history
                }
                .secondaryButton()
                Spacer()
                Button("완료") { model.cleanup.dismiss() }.primaryButton().keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
    }
}

private struct MessageView: View {
    let text: String
    @Environment(\.appModel) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(text).font(ClearFont.body).foregroundStyle(ClearColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("확인") { model.cleanup.dismiss() }.primaryButton().keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
    }
}
