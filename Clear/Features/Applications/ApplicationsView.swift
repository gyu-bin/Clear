import SwiftUI

private struct AppRowData: Identifiable {
    let app: InstalledApp
    let size: Int64
    var id: String { app.id }
    var name: String { app.info.name }
    var lastUsed: Date { app.lastUsed ?? .distantPast }
}

struct ApplicationsView: View {
    @Environment(\.appModel) private var env
    /// Name order while sizes are still being measured (so rows do not jump under
    /// the pointer), then size order once measuring finishes — unless the user
    /// picked a sort themselves.
    @State private var sortOrder = [KeyPathComparator(\AppRowData.name)]
    @State private var userSorted = false
    @State private var applyingSort = false

    var body: some View {
        let model = env.applications
        @Bindable var bindable = model
        FixedPage(title: "앱 관리", subtitle: model.apps.value.map { "앱 \($0.count)개" }) {
            Button { model.load() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
        } content: {
            switch model.apps {
            case .idle, .loading:
                ScanProgressView(progress: model.apps.progress ?? ScanProgress(phase: "설치된 앱 찾는 중"))
                    .padding(ClearMetrics.pagePadding)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .onAppear { if case .idle = model.apps { model.load() } }
            case .failed(let e):
                ErrorStateView(message: e) { model.load() }.padding(ClearMetrics.pagePadding)
            case .loaded(let apps, _):
                ControlBar {
                    SearchField(prompt: "앱 검색", text: $bindable.search)
                    Spacer()
                    if model.measuring {
                        ProgressView().controlSize(.small)
                        Text("크기 계산 중").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    }
                }
                HStack(spacing: 0) {
                    appTable(apps, model: model)
                        .frame(width: 380)
                    Divider()
                    Group {
                        if let selected = model.selectedApp {
                            AppDetail(model: model, app: selected).id(selected.id)
                        } else {
                            EmptyStateView(symbol: "app.dashed", title: "앱을 선택하세요",
                                           message: "번들 ID와 서명 정보로 확실히 연결된 파일만 기본 선택됩니다.")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func appTable(_ apps: [InstalledApp], model: ApplicationsModel) -> some View {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let rows = apps
            .filter { model.search.isEmpty || $0.info.name.localizedCaseInsensitiveContains(model.search)
                || ($0.info.bundleIdentifier?.localizedCaseInsensitiveContains(model.search) ?? false) }
            .map { AppRowData(app: $0, size: model.sizes[$0.id]?.allocated ?? -1) }
            .sorted(using: sortOrder)
        return Table(rows, selection: Binding(get: { model.selectedAppID },
                                              set: { id in if let app = apps.first(where: { $0.id == id }) { model.select(app) } }),
                     sortOrder: $sortOrder) {
            TableColumn("이름", value: \.name) { (row: AppRowData) in
                HStack(spacing: Space.s) {
                    AppIcon(path: row.app.info.path, size: 20)
                    Text(row.name).lineLimit(1)
                    if let id = row.app.info.bundleIdentifier, running.contains(id) {
                        Circle().fill(ClearColor.warning).frame(width: 6, height: 6).help("실행 중")
                    }
                }
            }
            .width(min: 140, ideal: 190)
            TableColumn("최근 사용", value: \.lastUsed) { (row: AppRowData) in
                Text(row.app.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(ClearColor.textSecondary)
            }
            .width(min: 64, ideal: 80)
            TableColumn("크기", value: \.size) { (row: AppRowData) in
                Text(row.size >= 0 ? row.size.formattedBytes : "계산 중").font(ClearFont.numeric)
                    .foregroundStyle(row.size >= 0 ? ClearColor.textPrimary : ClearColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 68)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first { Button("Finder에서 보기") { FinderActions.reveal(id) } }
        } primaryAction: { ids in
            if let id = ids.first { FinderActions.reveal(id) }
        }
        .onChange(of: sortOrder) { _, _ in
            if applyingSort { applyingSort = false } else { userSorted = true }
        }
        .onChange(of: model.measuring, initial: true) { _, measuring in
            guard !measuring, !userSorted else { return }
            applyingSort = true
            sortOrder = [KeyPathComparator(\AppRowData.size, order: .reverse)]
        }
    }
}

/// Finder icon for a path.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AppDetail: View {
    let model: ApplicationsModel
    let app: InstalledApp
    @State private var focused: CleanupCandidate.ID?

    var body: some View {
        @Bindable var model = model
        let related = model.related[app.id]
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.info.bundleIdentifier ?? "-").isEmpty
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.m) {
                    AppIcon(path: app.info.path, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.info.name).font(ClearFont.pageTitle)
                        Text([app.info.bundleIdentifier ?? "번들 ID 없음", app.info.version.map { "v\($0)" }, app.isAppStore ? "App Store" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary).textSelection(.enabled).lineLimit(1)
                    }
                    Spacer()
                    IconButton(symbol: "magnifyingglass", help: "Finder에서 보기") { FinderActions.reveal(app.info.path) }
                }
                HStack(spacing: Space.xxl) {
                    MetricView(title: "앱 크기", value: model.sizes[app.id]?.allocated.formattedBytes ?? "계산 중")
                    MetricView(title: "관련 파일", value: (related?.value ?? []).reduce(0) { $0 + $1.estimatedBytes }.formattedBytes,
                               detail: related?.value.map { "\($0.count)곳" })
                    MetricView(title: "마지막 사용", value: app.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "알 수 없음")
                }
                if let reason = app.uninstallBlockReason {
                    Label(reason, systemImage: "lock").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                } else if isRunning {
                    Label("실행 중입니다. 종료한 뒤 제거할 수 있습니다.", systemImage: "exclamationmark.circle")
                        .font(ClearFont.callout).foregroundStyle(ClearColor.warning)
                }
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
            Divider()
            switch related {
            case .loaded(let files, _):
                if files.isEmpty {
                    EmptyStateView(symbol: "folder", title: "관련 파일이 없습니다", message: "번들 ID나 서명 정보로 연결된 파일을 찾지 못했습니다.")
                        .frame(maxHeight: .infinity)
                } else {
                    CandidateTable(candidates: files, checked: $model.relatedSelection, focused: $focused, showsCategory: false)
                }
            case .failed(let e):
                ErrorStateView(message: e) { model.loadRelated(app) }.padding(Space.xl)
                Spacer()
            default:
                ScanProgressView(progress: ScanProgress(phase: "관련 파일 찾는 중")).padding(Space.xl)
                Spacer()
            }
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: Space.m) {
                    Text("모든 제거는 휴지통으로 이동합니다").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    Spacer()
                    Button("관련 파일만 정리…") { model.removeRelatedOnly(app) }
                        .secondaryButton()
                        .disabled((related?.value ?? []).allSatisfy { !model.relatedSelection.contains($0.id) })
                    Button("앱 제거…") { model.uninstall(app) }
                        .destructiveButton()
                        .disabled(!app.canUninstall || isRunning || model.bundleCandidates[app.id] == nil)
                        .help("앱 번들과 선택한 관련 파일을 휴지통으로 이동합니다. 실행 전 확인 화면이 표시됩니다.")
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.s + 2)
            }
            .background(.bar)
        }
        .candidateInspector($focused, candidates: related?.value ?? [])
    }
}
