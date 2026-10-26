import QuickLook
import SwiftUI

struct LargeFilesView: View {
    @Environment(\.appModel) private var app
    @State private var sortOrder = [KeyPathComparator(\LargeFileItem.allocatedSize, order: .reverse)]
    @State private var preview: URL?

    var body: some View {
        let model = app.largeFiles
        @Bindable var bindable = model
        FixedPage(title: "대용량 파일", subtitle: model.state.value.map { "\($0.items.count)개 · \($0.scannedFiles.formatted())개 파일 검사" }) {
            if model.state.value != nil && !model.state.isLoading {
                Button { model.scan() } label: { Label("다시 스캔", systemImage: "arrow.clockwise") }
            }
        } content: {
            switch model.state {
            case .idle:
                EmptyStateView(symbol: "doc.text.magnifyingglass", title: "큰 파일을 찾아보세요",
                               message: "홈 폴더 전체(숨김 폴더 포함)에서 큰 파일을 찾고, 오래 열지 않은 파일을 골라 볼 수 있습니다. 직접 고른 파일만 휴지통으로 이동합니다.",
                               actionTitle: "스캔") { model.scan() }
                    .frame(maxHeight: .infinity)
            case .loading(let p):
                ScanProgressView(progress: p, onCancel: { model.cancel() }).padding(ClearMetrics.pagePadding)
                Spacer()
            case .failed(let e):
                ErrorStateView(message: e) { model.scan() }.padding(ClearMetrics.pagePadding)
                Spacer()
            case .loaded(let result, let date):
                ControlBar {
                    Picker("크기", selection: $bindable.thresholdMB) {
                        Text("50MB 이상").tag(50); Text("100MB 이상").tag(100); Text("500MB 이상").tag(500); Text("1GB 이상").tag(1024)
                    }
                    .fixedSize()
                    Picker("종류", selection: $bindable.type) {
                        Text("모든 종류").tag(FileTypeGroup?.none)
                        Divider()
                        ForEach(FileTypeGroup.allCases.filter { $0 != .folder }, id: \.self) { Text($0.title).tag(FileTypeGroup?.some($0)) }
                    }
                    .fixedSize()
                    Picker("사용", selection: $bindable.age) {
                        ForEach(LargeFilesModel.AgeFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .help("‘마지막으로 연 날짜’가 없으면 수정일을 기준으로 합니다.")
                    Toggle("숨김 파일", isOn: $bindable.includeHidden).toggleStyle(.checkbox).font(ClearFont.callout)
                    Spacer()
                    FreshnessLabel(date: date)
                    SearchField(prompt: "파일 검색", text: $bindable.search)
                }
                .labelsHidden()
                let items = model.visibleItems.sorted(using: sortOrder)
                if items.isEmpty {
                    EmptyStateView(symbol: "line.3.horizontal.decrease", title: "조건에 맞는 파일이 없습니다",
                                   message: "크기 기준이나 필터를 바꿔 보세요.")
                        .frame(maxHeight: .infinity)
                } else {
                    selectAll(items, model: model)
                    Divider()
                    table(items, model: model)
                }
                actionBar(result, model: model)
            }
        }
        .quickLookPreview($preview)
    }

    private func selectAll(_ items: [LargeFileItem], model: LargeFilesModel) -> some View {
        let bindings = items.map { item in
            Binding<Bool>(get: { model.checked.contains(item.id) },
                          set: { on in if on { model.checked.insert(item.id) } else { model.checked.remove(item.id) } })
        }
        let checked = items.filter { model.checked.contains($0.id) }
        return HStack(spacing: Space.s) {
            Toggle(sources: bindings, isOn: \.self) { Text("전체 선택").font(ClearFont.callout) }.toggleStyle(.checkbox)
            Text("\(items.count)개 중 \(checked.count)개 · 전체 \(items.reduce(0) { $0 + $1.allocatedSize }.formattedBytes)")
                .font(ClearFont.numericSmall).foregroundStyle(ClearColor.textTertiary)
            Spacer()
            Text("스페이스: 미리보기 · 더블클릭: Finder에서 보기").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
        }
        .padding(.leading, Space.l + 1).padding(.trailing, Space.l).padding(.vertical, 6)
    }

    private func table(_ items: [LargeFileItem], model: LargeFilesModel) -> some View {
        @Bindable var model = model
        return Table(items, selection: $model.focused, sortOrder: $sortOrder) {
            TableColumn("") { (item: LargeFileItem) in
                Toggle("", isOn: Binding(get: { model.checked.contains(item.id) },
                                         set: { on in if on { model.checked.insert(item.id) } else { model.checked.remove(item.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel("\(item.name) 선택")
            }
            .width(18)
            TableColumn("이름", value: \.name) { (item: LargeFileItem) in
                HStack(spacing: Space.s) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Space.xs) {
                            Text(item.name).lineLimit(1)
                            if item.isHidden { TagBadge(text: "숨김") }
                        }
                        Text(PathUtilities.abbreviated(item.folder)).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 200, ideal: 340)
            TableColumn("크기", value: \.allocatedSize) { (item: LargeFileItem) in
                Text(item.allocatedSize.formattedBytes).font(ClearFont.numeric).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 76)
            TableColumn("마지막으로 연 날짜", value: \.lastUsed) { (item: LargeFileItem) in
                Text(item.lastOpened.map { $0.formatted(.relative(presentation: .named)) } ?? "기록 없음")
                    .foregroundStyle(item.lastOpened == nil ? ClearColor.textTertiary : ClearColor.textSecondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("수정일", value: \.modified) { (item: LargeFileItem) in
                Text(item.modified.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(ClearColor.textSecondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn("종류") { (item: LargeFileItem) in
                Text(item.type.title).foregroundStyle(ClearColor.textSecondary)
            }
            .width(min: 60, ideal: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("미리보기") { preview = URL(fileURLWithPath: id) }
                Button("Finder에서 보기") { FinderActions.reveal(id) }
                Button("경로 복사") { FinderActions.copyPath(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { FinderActions.reveal(id) }
        }
        .onKeyPress(.space) {
            guard let id = model.focused else { return .ignored }
            preview = preview == nil ? URL(fileURLWithPath: id) : nil
            return .handled
        }
    }

    private func actionBar(_ result: LargeFileScanResult, model: LargeFilesModel) -> some View {
        let selected = result.items.filter { model.checked.contains($0.id) }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: Space.m) {
                Text("\(selected.count)개 선택").font(ClearFont.callout)
                Text(selected.reduce(0) { $0 + $1.allocatedSize }.formattedBytes).font(ClearFont.numeric).foregroundStyle(ClearColor.textSecondary)
                if result.skippedCloudOnly > 0 {
                    Text("iCloud에만 있는 파일 \(result.skippedCloudOnly)개는 건너뜀").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                Spacer()
                Button("휴지통으로 이동…") { model.requestCleanup() }.primaryButton().disabled(selected.isEmpty)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.s + 2)
        }
        .background(.bar)
    }
}
