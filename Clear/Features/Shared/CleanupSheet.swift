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
                    RiskBadge(risk: item.candidate.risk)
                    Text(methodText(item)).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary).frame(width: 96, alignment: .trailing)
                    Text(item.candidate.estimatedBytes.formattedBytes).font(ClearFont.numericSmall).frame(width: 70, alignment: .trailing)
                }
                .help(item.candidate.impact)
            }
            .listStyle(.inset)
            .frame(height: min(260, CGFloat(plan.items.count) * 38 + 16))
            Divider()
            VStack(alignment: .leading, spacing: Space.s) {
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
                    Button("정리") { model.cleanup.confirm() }
                        .primaryButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan.requiresExplicitAcknowledgement && !model.cleanup.acknowledged)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.s) {
                Image(systemName: report.failed.isEmpty && !report.wasCancelled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(report.failed.isEmpty && !report.wasCancelled ? ClearColor.success : ClearColor.warning)
                    .symbolEffect(.bounce, value: report.id)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(report.wasCancelled ? "정리를 취소했습니다" : report.failed.isEmpty ? "정리를 마쳤습니다" : "일부 항목을 정리하지 못했습니다")
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
