import SwiftUI

struct AIToolsView: View {
    @Environment(\.appModel) private var model

    var body: some View {
        @Bindable var model = model
        FixedPage(title: "AI 도구", subtitle: model.ai.date.map { "\($0.formatted(.relative(presentation: .named))) 스캔" }) {
            if model.settings.aiToolsEnabled && !model.ai.isLoading {
                Button { model.scanAI() } label: { Label(model.ai.value == nil ? "스캔" : "다시 스캔", systemImage: "arrow.clockwise") }
            }
        } content: {
            if !model.settings.aiToolsEnabled {
                EmptyStateView(symbol: "brain", title: "AI 도구 관리가 꺼져 있습니다", message: "켜면 AI 도구의 캐시·로그·모델 사용량을 분석합니다.",
                               actionTitle: "켜기") { model.settingsStore.settings.aiToolsEnabled = true }
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "lock.shield").foregroundStyle(ClearColor.success)
                        Text("대화·세션 기록, 인증 정보, 설정, 메모리는 정리 대상에서 제외됩니다. 로컬 모델은 캐시로 취급하지 않으며 개별 선택이 필요합니다.")
                            .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, ClearMetrics.pagePadding).padding(.vertical, Space.s + 2)
                    Divider()
                    switch model.ai {
                    case .idle:
                        EmptyStateView(symbol: "brain", title: "AI 도구를 분석하지 않았습니다", message: "설치된 도구와 실제 데이터 위치를 확인합니다.",
                                       actionTitle: "스캔") { model.scanAI() }
                            .frame(maxHeight: .infinity)
                    case .loading(let p):
                        ScanProgressView(progress: p, onCancel: { model.cancel("ai") }).padding(ClearMetrics.pagePadding)
                        Spacer()
                    case .failed(let e):
                        ErrorStateView(message: e) { model.scanAI() }.padding(ClearMetrics.pagePadding)
                        Spacer()
                    case .loaded(let reports, _):
                        ToolBrowser(reports: reports, checked: $model.aiSelection, reviewTitle: "AI 도구 정리")
                    }
                }
            }
        }
    }
}
