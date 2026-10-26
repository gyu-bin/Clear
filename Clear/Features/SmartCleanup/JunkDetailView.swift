import SwiftUI

extension JunkGroup {
    var explanation: String {
        switch self {
        case .userCache: "앱이 빨리 다시 열리도록 저장해 둔 임시 데이터입니다. 지워도 앱이 다시 만듭니다."
        case .browserCache: "웹페이지를 빨리 열려고 저장한 데이터입니다. 로그인 정보와 방문 기록은 지워지지 않습니다."
        case .xcode: "Xcode 빌드 데이터, 시뮬레이터, 기기 지원 파일입니다."
        case .developer: "npm·Gradle·Homebrew 등 개발 도구가 내려받거나 만든 캐시입니다."
        case .projects: "프로젝트 안의 빌드 결과물, 의존성, Git이 제외한 생성 파일(보고서·스크린샷 등)입니다. Git이 추적하는 파일, 키·환경 변수 파일이 든 폴더는 막혀 있습니다."
        case .aiTools: "AI 도구의 캐시와 로그, 끝난 Claude Code 세션의 작업 폴더입니다. 대화 기록과 설정은 포함되지 않습니다."
        case .logs: "앱이 남긴 기록 파일입니다. 문제를 진단할 때 말고는 필요 없습니다."
        case .screenshots: "화면을 캡처한 이미지와 영상입니다. 직접 확인한 뒤 선택하세요."
        case .downloads: "다운로드 폴더의 큰 파일과 오래된 설치 파일입니다."
        case .mail: "메일에서 연 첨부파일의 사본입니다. 원본은 메일에 남아 있습니다."
        case .leftovers: "삭제된 앱이 남긴 데이터, 고장 난 시작 항목, 지난 기기 업데이트 파일입니다."
        case .other: "오래된 임시 파일과 창 복원 정보입니다."
        }
    }
}

/// Two-pane detail: junk types on the left (with tri-state checkboxes), the
/// items of the chosen type on the right (app icons, expandable sub-folders).
struct JunkDetailView: View {
    let report: GeneralScanReport
    let back: () -> Void
    @Binding var group: JunkGroup?
    @Environment(\.appModel) private var model
    @State private var search = ""
    @State private var sortBySize = true
    @State private var expanded: Set<String> = []

    var body: some View {
        @Bindable var model = model
        let all = model.junkCandidates
        let selectable = all.filter { $0.risk.isSelectable }
        let groups = JunkGroup.allCases.compactMap { g -> (JunkGroup, [CleanupCandidate])? in
            let items = all.filter { JunkGroup.of($0) == g }
            return items.isEmpty ? nil : (g, items)
        }.sorted { size($0.1) > size($1.1) }
        let current = group ?? groups.first?.0

        HStack(spacing: 0) {
            // Left: types
            VStack(spacing: 0) {
                HStack {
                    Button { back() } label: { Label("요약", systemImage: "chevron.left") }.buttonStyle(.borderless)
                    Spacer()
                    let allSelected = !selectable.isEmpty && selectable.allSatisfy { model.junkSelection.contains($0.id) }
                    Button(allSelected ? "모두 해제" : "모두 선택") {
                        if allSelected { model.junkSelection.removeAll() } else { model.junkSelection.formUnion(selectable.map(\.id)) }
                    }
                    .buttonStyle(.borderless).font(ClearFont.callout)
                }
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                Divider()
                List(selection: Binding(get: { current }, set: { group = $0 })) {
                    ForEach(groups, id: \.0) { g, items in
                        GroupRow(group: g, items: items, selection: $model.junkSelection).tag(g)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 280)
            Divider()

            // Right: items of the chosen type
            VStack(spacing: 0) {
                if let current {
                    let items = (groups.first { $0.0 == current }?.1 ?? [])
                        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search) }
                        .sorted { sortBySize ? $0.estimatedBytes > $1.estimatedBytes : $0.title.localizedCompare($1.title) == .orderedAscending }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(current.title).font(ClearFont.pageTitle)
                            Spacer()
                            Menu(sortBySize ? "크기순" : "이름순") {
                                Button("크기순") { sortBySize = true }
                                Button("이름순") { sortBySize = false }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                            SearchField(prompt: "검색", text: $search)
                        }
                        Text(current.explanation).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    }
                    .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
                    Divider()
                    List {
                        ForEach(items) { c in
                            ItemRow(candidate: c, selection: $model.junkSelection, expanded: $expanded)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                } else {
                    EmptyStateView(symbol: "checkmark.circle", title: "정리할 항목이 없습니다", message: "다시 스캔해 보세요.")
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        bottomBar(all)
    }

    private func size(_ items: [CleanupCandidate]) -> Int64 {
        items.filter { $0.risk != .blocked }.reduce(0) { $0 + $1.estimatedBytes }
    }

    private func bottomBar(_ all: [CleanupCandidate]) -> some View {
        let selected = all.filter { model.junkSelection.contains($0.id) && $0.risk.isSelectable }
        return VStack(spacing: 0) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    ByteFigure(bytes: selected.reduce(0) { $0 + $1.estimatedBytes }, font: ClearFont.figure)
                    Text("선택").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(size(all).formattedBytes).font(ClearFont.figureSmall).foregroundStyle(ClearColor.textTertiary)
                    Text("전체").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                Spacer()
                Button("정리…") {
                    model.cleanup.review(title: "스마트 청소", candidates: selected)
                }
                .primaryButton(large: true)
                .frame(minWidth: 140)
                .disabled(selected.isEmpty || model.cleanup.isRunning)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, Space.xl).padding(.vertical, Space.m)
        }
        .background(.bar)
    }
}

private struct GroupRow: View {
    let group: JunkGroup
    let items: [CleanupCandidate]
    @Binding var selection: Set<String>

    var body: some View {
        let selectable = items.filter { $0.risk.isSelectable }
        let bindings = selectable.map { c in
            Binding<Bool>(get: { selection.contains(c.id) }, set: { on in if on { selection.insert(c.id) } else { selection.remove(c.id) } })
        }
        let selectedBytes = selectable.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.estimatedBytes }
        HStack(spacing: Space.s) {
            Toggle(sources: bindings, isOn: \.self) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(selectable.isEmpty)
                .accessibilityLabel("\(group.title) 전체 선택")
            Image(systemName: group.symbol).foregroundStyle(group.color).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).lineLimit(1)
                Text(selectedBytes > 0 ? "\(selectedBytes.formattedBytes) 선택" : "\(items.count)개")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
            }
            Spacer()
            Text(items.filter { $0.risk != .blocked }.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes)
                .font(ClearFont.numericSmall)
        }
        .padding(.vertical, 3)
    }
}

/// One cleanup item with its app icon; expands to show the largest sub-folders.
private struct ItemRow: View {
    let candidate: CleanupCandidate
    @Binding var selection: Set<String>
    @Binding var expanded: Set<String>
    @State private var children: [(name: String, bytes: Int64)]?

    var body: some View {
        let isExpanded = expanded.contains(candidate.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Toggle("", isOn: Binding(get: { selection.contains(candidate.id) },
                                         set: { on in if on { selection.insert(candidate.id) } else { selection.remove(candidate.id) } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(!candidate.risk.isSelectable)
                    .accessibilityLabel("\(candidate.title) 선택")
                CandidateIcon(candidate: candidate).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Space.xs) {
                        Text(candidate.title).lineLimit(1)
                        if !candidate.runningGuards.isEmpty { TagBadge(text: "실행 중", tint: ClearColor.warning) }
                    }
                    Text(candidate.subtitle).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                RiskBadge(risk: candidate.risk)
                Text(candidate.estimatedBytes.formattedBytes).font(ClearFont.numeric).frame(minWidth: 72, alignment: .trailing)
                Button {
                    if isExpanded { expanded.remove(candidate.id) } else { expanded.insert(candidate.id); loadChildren() }
                } label: {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundStyle(ClearColor.textTertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "접기" : "자세히")
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let p = candidate.path { FinderActions.reveal(p) } }

            if isExpanded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(candidate.riskReason).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                    Text(candidate.impact).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    if let children {
                        ForEach(children.prefix(10), id: \.name) { child in
                            HStack {
                                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(ClearColor.textTertiary)
                                Text(child.name).font(ClearFont.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(child.bytes.formattedBytes).font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
                            }
                        }
                        if children.count > 10 {
                            Text("외 \(children.count - 10)개").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                        }
                    } else if candidate.path != nil {
                        HStack(spacing: Space.xs) { ProgressView().controlSize(.mini); Text("하위 폴더 크기 계산 중").font(ClearFont.caption) }
                    }
                    if let path = candidate.path {
                        Button("Finder에서 보기") { FinderActions.reveal(path) }.buttonStyle(.link).font(ClearFont.caption)
                    }
                }
                .padding(.leading, 60).padding(.trailing, Space.l).padding(.bottom, Space.s)
            }
        }
        .contextMenu {
            if let path = candidate.path {
                Button("Finder에서 보기") { FinderActions.reveal(path) }
                Button("경로 복사") { FinderActions.copyPath(path) }
            }
        }
    }

    /// Measures the direct children off the main thread (only when expanded).
    private func loadChildren() {
        guard children == nil, let path = candidate.path else { return }
        Task {
            let result = await runOffMain { () -> [(name: String, bytes: Int64)] in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                let sizer = DirectorySizer()
                return names.compactMap { name -> (String, Int64)? in
                    guard let size = try? sizer.measure(path: path + "/" + name) else { return nil }
                    return (name, size.allocated)
                }
                .sorted { $0.1 > $1.1 }
                .map { (name: $0.0, bytes: $0.1) }
            }
            children = result
        }
    }
}

/// App icon for a candidate when its owner app can be found, otherwise the
/// Finder icon of the item itself (folder or file).
struct CandidateIcon: View {
    let candidate: CleanupCandidate

    var body: some View {
        Image(nsImage: Self.icon(for: candidate)).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func icon(for c: CleanupCandidate) -> NSImage {
        if let cached = cache[c.id] { return cached }
        var image: NSImage?
        for g in c.guards where g.kind == .bundleID {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: g.value) {
                image = NSWorkspace.shared.icon(forFile: url.path)
                break
            }
        }
        if image == nil, let path = c.path { image = NSWorkspace.shared.icon(forFile: path) }
        let result = image ?? NSImage(systemSymbolName: c.category.symbol, accessibilityDescription: nil) ?? NSImage()
        cache[c.id] = result
        return result
    }
}
