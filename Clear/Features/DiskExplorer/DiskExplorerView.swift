import SwiftUI

struct DiskExplorerView: View {
    @Environment(\.appModel) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let model = app.diskExplorer
        @Bindable var bindable = model
        FixedPage(title: "디스크 분석", subtitle: model.rootURL.map { PathUtilities.abbreviated($0.path) }) {
            if !model.state.isLoading && model.rootURL != nil {
                Button { model.rescan() } label: { Label("다시 스캔", systemImage: "arrow.clockwise") }
                Button { chooseFolder() } label: { Label("폴더 선택", systemImage: "folder") }
            }
        } content: {
            switch model.state {
            case .idle: LocationPicker(model: model, choose: chooseFolder)
            case .loading(let p):
                ScanProgressView(progress: p, onCancel: { model.cancel() }).padding(ClearMetrics.pagePadding)
                Spacer()
            case .failed(let e):
                ErrorStateView(message: e) { model.rescan() }.padding(ClearMetrics.pagePadding)
                Spacer()
            case .loaded(let result, let date):
                ControlBar {
                    Picker("보기", selection: $bindable.tab) { ForEach(DiskExplorerModel.Tab.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    Text("\(result.totalEntries.formatted())개 항목").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textTertiary)
                    FreshnessLabel(date: date)
                }
                switch model.tab {
                case .treemap: TreemapPane(model: model, result: result)
                case .largeFiles: FileTable(files: result.largeFiles, emptyMessage: "50MB 이상인 파일이 없습니다.")
                case .oldFiles: FileTable(files: result.oldFiles, emptyMessage: "1년 넘게 수정되지 않은 20MB 이상 파일이 없습니다.")
                case .types: TypeBreakdown(types: result.typeBreakdown)
                }
            }
        }
    }

    private func chooseFolder() {
        if let url = FinderActions.chooseFolders(message: "분석할 폴더나 볼륨을 선택하세요", allowsMultiple: false).first {
            app.diskExplorer.scan(url)
        }
    }
}

private struct LocationPicker: View {
    let model: DiskExplorerModel
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("분석할 위치").font(ClearFont.sectionTitle)
            VStack(spacing: 0) {
                ForEach(Array(model.quickLocations.enumerated()), id: \.element.url) { index, loc in
                    if index > 0 { RowDivider(leading: 36) }
                    Button { model.scan(loc.url) } label: {
                        HStack(spacing: Space.s) {
                            SymbolTile(symbol: loc.symbol)
                            Text(loc.title).font(ClearFont.body)
                            Text(PathUtilities.abbreviated(loc.url.path)).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(ClearColor.textTertiary)
                        }
                        .padding(.horizontal, Space.s).padding(.vertical, Space.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
            .panel(padding: Space.xs)
            HStack {
                Text("크기는 디스크에 실제로 할당된 공간 기준입니다. 외장 드라이브는 선택했을 때만 스캔합니다. 이 화면은 파일을 삭제하지 않습니다.")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                Spacer()
                Button("다른 폴더 선택…", action: choose).secondaryButton()
            }
        }
        .padding(ClearMetrics.pagePadding)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TreemapPane: View {
    let model: DiskExplorerModel
    let result: DiskScanResult
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        if let current = model.current {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Breadcrumbs(model: model, restricted: result.restrictedPaths)
                        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                    Divider()
                    Group {
                        if current.children.contains(where: { $0.allocatedSize > 0 }) {
                            TreemapView(node: current, hovered: $model.hoveredNode, selected: model.selectedNode) { node in
                                withAnimation(Motion.standard(reduceMotion)) { model.enter(node) }
                            }
                            .id(current.id)
                            .transition(.opacity)
                        } else {
                            EmptyStateView(symbol: "folder", title: "표시할 항목이 없습니다", message: "비어 있거나 크기를 알 수 없는 폴더입니다.")
                        }
                    }
                    .padding(Space.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    StatusBar(node: model.hoveredNode ?? model.selectedNode, parent: current)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()

                ChildList(model: model, node: current)
                    .frame(width: 280)
            }
        }
    }
}

private struct Breadcrumbs: View {
    let model: DiskExplorerModel
    let restricted: [String]
    @State private var showRestricted = false

    var body: some View {
        HStack(spacing: Space.xs) {
            IconButton(symbol: "chevron.left", help: "상위 폴더") { model.goUp() }
                .disabled(model.stack.count <= 1)
                .keyboardShortcut(.upArrow, modifiers: [.command])
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(Array(model.stack.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(ClearColor.textTertiary) }
                        Button(node.name) { model.go(to: index) }
                            .buttonStyle(.plain)
                            .font(ClearFont.callout.weight(index == model.stack.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == model.stack.count - 1 ? ClearColor.textPrimary : ClearColor.textSecondary)
                    }
                }
            }
            Spacer()
            if !restricted.isEmpty {
                Button { showRestricted.toggle() } label: {
                    Label("접근 제한 \(restricted.count)곳", systemImage: "lock").font(ClearFont.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ClearColor.warning)
                .popover(isPresented: $showRestricted) {
                    PermissionNoticeView(title: "\(restricted.count)개 폴더에 접근할 수 없습니다",
                                         message: "크기를 알 수 없어 합계에 포함하지 않았습니다(‘+’로 표시).", paths: restricted)
                        .padding(Space.l).frame(width: 420)
                }
            }
            if let current = model.current {
                Text(current.allocatedSize.formattedBytes + (current.isPartial ? "+" : "")).font(ClearFont.numeric)
                IconButton(symbol: "magnifyingglass", help: "Finder에서 보기") { FinderActions.reveal(current.path) }
            }
        }
    }
}

private struct StatusBar: View {
    let node: DiskNode?
    let parent: DiskNode

    var body: some View {
        HStack(spacing: Space.s) {
            if let node {
                Image(systemName: node.isContainer ? "folder" : node.fileType.symbol).foregroundStyle(ClearColor.textSecondary)
                Text(node.name).font(ClearFont.callout.weight(.medium)).lineLimit(1)
                Text(node.isRestricted ? "접근 제한" : node.allocatedSize.formattedBytes + (node.isPartial ? "+" : ""))
                    .font(ClearFont.numericSmall)
                if parent.allocatedSize > 0, !node.isRestricted {
                    Text(String(format: "%.1f%%", Double(node.allocatedSize) / Double(parent.allocatedSize) * 100))
                        .font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
                }
                if node.fileCount > 1 {
                    Text("파일 \(node.fileCount.formatted())개").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                if let m = node.modified {
                    Text("수정 \(m.formatted(date: .abbreviated, time: .omitted))").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                Spacer()
            } else {
                Text("타일에 마우스를 올리면 정보가 표시되고, 폴더를 클릭하면 안으로 들어갑니다.")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                Spacer()
            }
        }
        .frame(height: 18)
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
    }
}

private struct ChildList: View {
    let model: DiskExplorerModel
    let node: DiskNode

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selectedNode?.id },
                                set: { id in model.selectedNode = node.children.first { $0.id == id } })) {
            ForEach(Array(model.visibleChildren.enumerated()), id: \.element.id) { index, child in
                row(child, index: index).tag(child.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                TextField("이 폴더에서 찾기", text: $model.filter).textFieldStyle(.roundedBorder)
                    .padding(Space.s)
                Divider()
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let child = node.children.first(where: { $0.id == id }) {
                Button("Finder에서 보기") { FinderActions.reveal(child.path) }
                Button("경로 복사") { FinderActions.copyPath(child.path) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let child = node.children.first(where: { $0.id == id }) { model.enter(child) }
        }
    }

    private func row(_ child: DiskNode, index: Int) -> some View {
        let fraction = node.allocatedSize > 0 ? Double(child.allocatedSize) / Double(node.allocatedSize) : 0
        let colorIndex = node.children.firstIndex { $0.id == child.id } ?? index
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: 2).fill(child.allocatedSize > 0 ? TreemapView.color(for: child, index: colorIndex) : ClearColor.track)
                    .frame(width: 8, height: 8)
                Image(systemName: icon(child)).foregroundStyle(child.isRestricted ? ClearColor.warning : ClearColor.textSecondary).frame(width: 16)
                Text(child.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(child.isRestricted ? "접근 제한" : child.allocatedSize.formattedBytes + (child.isPartial ? "+" : ""))
                    .font(ClearFont.numericSmall)
                    .foregroundStyle(child.isRestricted ? ClearColor.warning : ClearColor.textSecondary)
            }
            GeometryReader { g in
                Capsule().fill(ClearColor.track)
                    .overlay(alignment: .leading) { Capsule().fill(ClearColor.textTertiary).frame(width: max(1, g.size.width * fraction)) }
            }
            .frame(height: 2)
            .padding(.leading, 32)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(child.isContainer ? "두 번 눌러 폴더로 이동" : "")
    }

    private func icon(_ n: DiskNode) -> String {
        switch n.kind {
        case .directory: "folder"
        case .package: "shippingbox"
        case .restricted: "lock"
        case .aggregate: "ellipsis"
        case .symlink: "arrow.turn.up.right"
        case .file: n.fileType.symbol
        }
    }
}

private struct FileTable: View {
    let files: [LargeFileEntry]
    let emptyMessage: String
    @State private var type: FileTypeGroup?
    @State private var sortOrder = [KeyPathComparator(\LargeFileEntry.allocatedSize, order: .reverse)]
    @State private var selection: LargeFileEntry.ID?

    var body: some View {
        let rows = files.filter { type == nil || $0.type == type }.sorted(using: sortOrder)
        VStack(spacing: 0) {
            HStack {
                Picker("유형", selection: $type) {
                    Text("모든 유형").tag(FileTypeGroup?.none)
                    Divider()
                    ForEach(FileTypeGroup.allCases, id: \.self) { Text($0.title).tag(FileTypeGroup?.some($0)) }
                }
                .fixedSize()
                Spacer()
                Text("\(rows.count)개 · \(rows.reduce(0) { $0 + $1.allocatedSize }.formattedBytes)").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
            Divider()
            if rows.isEmpty {
                EmptyStateView(symbol: "doc", title: "해당하는 파일이 없습니다", message: emptyMessage).frame(maxHeight: .infinity)
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("이름", value: \.name) { f in
                        HStack(spacing: Space.s) {
                            Image(systemName: f.type.symbol).foregroundStyle(ClearColor.textSecondary).frame(width: 16)
                            Text(f.name).lineLimit(1)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("위치") { f in
                        Text(PathUtilities.abbreviated((f.path as NSString).deletingLastPathComponent))
                            .foregroundStyle(ClearColor.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("수정일", value: \.modified) { f in
                        Text(f.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(ClearColor.textSecondary)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("크기", value: \.allocatedSize) { f in
                        Text(f.allocatedSize.formattedBytes).font(ClearFont.numeric).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 64, ideal: 80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: LargeFileEntry.ID.self) { ids in
                    if let id = ids.first {
                        Button("Finder에서 보기") { FinderActions.reveal(id) }
                        Button("경로 복사") { FinderActions.copyPath(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { FinderActions.reveal(id) }
                }
            }
        }
    }
}

private struct TypeBreakdown: View {
    let types: [FileTypeGroup: Int64]

    var body: some View {
        let total = max(1, types.values.reduce(0, +))
        let sorted = types.sorted { $0.value > $1.value }
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("파일 유형별 사용량", subtitle: "확장자 기준 · 디스크 할당 크기")
                ForEach(Array(sorted.enumerated()), id: \.element.key) { index, entry in
                    ProportionRow(title: entry.key.title, bytes: entry.value, fraction: Double(entry.value) / Double(total),
                                  color: ClearColor.chart[index % ClearColor.chart.count], symbol: entry.key.symbol)
                }
            }
            .padding(ClearMetrics.pagePadding)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}
