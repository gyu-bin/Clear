import SwiftUI

struct DeveloperView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case tools, projects
        var id: String { rawValue }
        var title: String { self == .tools ? "개발 도구" : "프로젝트" }
    }

    @Environment(\.appModel) private var model
    @State private var tab: Tab = .tools

    var body: some View {
        @Bindable var model = model
        FixedPage(title: "개발자 도구", subtitle: model.developer.date.map { "\($0.formatted(.relative(presentation: .named))) 스캔" }) {
            if model.settings.developerModeEnabled {
                if tab == .tools {
                    if !model.developer.isLoading {
                        Button { model.scanDeveloper() } label: { Label(model.developer.value == nil ? "스캔" : "다시 스캔", systemImage: "arrow.clockwise") }
                    }
                } else {
                    Button { addProjects() } label: { Label("프로젝트 추가", systemImage: "plus") }
                    Button { model.analyzeAllProjects() } label: { Label("모두 분석", systemImage: "arrow.clockwise") }
                        .disabled(model.settings.projectFolders.isEmpty)
                }
            }
        } content: {
            if !model.settings.developerModeEnabled {
                EmptyStateView(symbol: "hammer", title: "개발자 모드가 꺼져 있습니다",
                               message: "켜면 개발 도구 캐시와 프로젝트 빌드 산출물을 분석합니다.",
                               actionTitle: "개발자 모드 켜기") { model.settingsStore.settings.developerModeEnabled = true }
                    .frame(maxHeight: .infinity)
            } else {
                ControlBar {
                    Picker("보기", selection: $tab) { ForEach(Tab.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                }
                switch tab {
                case .tools: tools
                case .projects: ProjectsView(addProjects: addProjects)
                }
            }
        }
    }

    private func addProjects() {
        for url in FinderActions.chooseFolders(message: "분석할 개발 프로젝트 폴더를 선택하세요") {
            model.settingsStore.addProjectFolder(url)
            if let folder = model.settings.projectFolders.first(where: { $0.path == (PathUtilities.canonicalPath(url.path) ?? url.path) }) {
                model.analyzeProject(folder)
            }
        }
        tab = .projects
    }

    @ViewBuilder private var tools: some View {
        @Bindable var model = model
        switch model.developer {
        case .idle:
            EmptyStateView(symbol: "hammer", title: "개발 도구를 분석하지 않았습니다",
                           message: "Xcode·npm·Gradle 등의 캐시를 찾습니다. Homebrew와 Docker는 공식 명령의 결과를 먼저 보여 줍니다.",
                           actionTitle: "스캔") { model.scanDeveloper() }
                .frame(maxHeight: .infinity)
        case .loading(let p):
            ScanProgressView(progress: p, onCancel: { model.cancel("developer") }).padding(ClearMetrics.pagePadding)
        case .failed(let e):
            ErrorStateView(message: e) { model.scanDeveloper() }.padding(ClearMetrics.pagePadding)
        case .loaded(let reports, _):
            ToolBrowser(reports: reports, checked: $model.developerSelection, reviewTitle: "개발자 도구 정리")
        }
    }
}

private struct ProjectsView: View {
    @Environment(\.appModel) private var model
    let addProjects: () -> Void
    @State private var selectedPath: String?

    var body: some View {
        let folders = model.settings.projectFolders
        if folders.isEmpty {
            EmptyStateView(symbol: "folder.badge.plus", title: "등록된 프로젝트가 없습니다",
                           message: "프로젝트 폴더를 추가하면 소스·의존성·빌드 산출물·캐시를 나눠 보여 줍니다. 소스, .git, 환경 변수·키 파일은 정리 대상이 되지 않습니다.",
                           actionTitle: "프로젝트 추가", action: addProjects)
                .frame(maxHeight: .infinity)
        } else {
            let current = folders.first { $0.path == selectedPath } ?? folders[0]
            HStack(spacing: 0) {
                List(selection: Binding(get: { current.path }, set: { selectedPath = $0 })) {
                    ForEach(folders) { folder in
                        ProjectRow(folder: folder, state: model.projects[folder.path]).tag(folder.path)
                            .contextMenu {
                                Button("분석") { model.analyzeProject(folder) }
                                Button("Finder에서 보기") { FinderActions.reveal(folder.path) }
                                Divider()
                                Button("등록 해제") {
                                    model.settingsStore.removeProjectFolder(folder)
                                    model.projects[folder.path] = nil
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(width: 230)
                Divider()

                ProjectDetail(folder: current)
                    .id(current.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ProjectRow: View {
    let folder: ProjectFolder
    let state: LoadState<ProjectReport>?

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "folder").frame(width: 18).foregroundStyle(ClearColor.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).lineLimit(1)
                Text(state?.value?.kinds.joined(separator: " · ") ?? PathUtilities.abbreviated(folder.path))
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1)
            }
            Spacer()
            if state?.isLoading == true {
                ProgressView().controlSize(.mini)
            } else if let report = state?.value {
                Text(report.total.allocated.formattedBytes).font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProjectDetail: View {
    let folder: ProjectFolder
    @Environment(\.appModel) private var model
    @State private var focused: CleanupCandidate.ID?

    var body: some View {
        @Bindable var model = model
        let state = model.projects[folder.path]
        VStack(spacing: 0) {
            switch state {
            case nil, .idle?:
                EmptyStateView(symbol: "folder", title: "아직 분석하지 않았습니다", message: PathUtilities.abbreviated(folder.path),
                               actionTitle: "분석") { model.analyzeProject(folder) }
                    .frame(maxHeight: .infinity)
            case .loading(let p)?:
                ScanProgressView(progress: p).padding(Space.xl)
                Spacer()
            case .failed(let e)?:
                ErrorStateView(message: e) { model.analyzeProject(folder) }.padding(Space.xl)
                Spacer()
            case .loaded(let report, _)?:
                header(report)
                Divider()
                if report.candidates.isEmpty {
                    EmptyStateView(symbol: "checkmark.circle", title: "정리할 생성 파일이 없습니다", message: "빌드 산출물이나 캐시 폴더를 찾지 못했습니다.")
                        .frame(maxHeight: .infinity)
                } else {
                    CandidateTable(candidates: report.candidates, checked: $model.projectSelection, focused: $focused)
                    actionBar(report)
                }
            }
        }
        .candidateInspector($focused, candidates: state?.value?.candidates ?? [])
        .onAppear { if model.projects[folder.path] == nil { model.analyzeProject(folder) } }
    }

    private func header(_ report: ProjectReport) -> some View {
        let total = max(report.total.allocated, 1)
        let segments = [
            CapacitySegment(id: "src", title: "소스·기타", bytes: report.source, color: ClearColor.textSecondary.opacity(0.55)),
            CapacitySegment(id: "deps", title: "의존성", bytes: report.dependencies, color: ClearColor.chart[2]),
            CapacitySegment(id: "build", title: "빌드 산출물", bytes: report.build, color: ClearColor.chart[3]),
            CapacitySegment(id: "cache", title: "캐시", bytes: report.cache, color: ClearColor.chart[0]),
        ]
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(report.name).font(ClearFont.pageTitle)
                Text(([report.packageManager].compactMap { $0 } + report.kinds).joined(separator: " · "))
                    .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                Spacer()
                Text("\(report.analyzedAt.formatted(.relative(presentation: .named))) 분석").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                IconButton(symbol: "arrow.clockwise", help: "다시 분석") { model.analyzeProject(folder) }
            }
            HStack(spacing: Space.xxl) {
                MetricView(title: "전체", value: report.total.allocated.formattedBytes)
                MetricView(title: "정리 후보", value: report.cleanable.formattedBytes)
            }
            CapacityBar(segments: segments, total: total)
            HStack(spacing: Space.l) { ForEach(segments) { LegendItem(segment: $0) } }
            ForEach(report.notes, id: \.self) { Text($0).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary) }
        }
        .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
    }

    private func actionBar(_ report: ProjectReport) -> some View {
        @Bindable var model = model
        let buildItems = report.candidates.filter { $0.category == .projectBuild && $0.risk != .blocked }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: Space.m) {
                Text("빌드 정리는 빌드 산출물과 캐시만 대상으로 합니다. 의존성은 직접 선택하세요.")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                Spacer()
                Button("선택 항목 정리…") {
                    model.cleanup.review(title: "\(folder.name) 정리", candidates: report.candidates.filter { model.projectSelection.contains($0.id) })
                }
                .secondaryButton()
                .disabled(!report.candidates.contains { model.projectSelection.contains($0.id) })
                Button("빌드 정리…") { model.cleanup.review(title: "\(folder.name) 빌드 정리", candidates: buildItems) }
                    .primaryButton()
                    .disabled(buildItems.isEmpty)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.s + 2)
        }
        .background(.bar)
    }
}
