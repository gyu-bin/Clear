import SwiftUI

struct StartupItemsView: View {
    @Environment(\.appModel) private var app

    var body: some View {
        let model = app.startup
        @Bindable var bindable = model
        FixedPage(title: "시작 항목", subtitle: model.state.value.map { "\($0.count)개 · 켜짐 \($0.filter { !$0.isDisabled }.count)개" }) {
            Button { model.load() } label: { Label("새로고침", systemImage: "arrow.clockwise") }
        } content: {
            switch model.state {
            case .idle, .loading:
                ScanProgressView(progress: ScanProgress(phase: "시작 항목 확인 중")).padding(ClearMetrics.pagePadding)
                    .onAppear { if case .idle = model.state { model.load() } }
                Spacer()
            case .failed(let e):
                ErrorStateView(message: e) { model.load() }.padding(ClearMetrics.pagePadding)
                Spacer()
            case .loaded(let items, _):
                ControlBar {
                    Picker("범위", selection: $bindable.scope) {
                        Text("전체").tag(StartupItem.Scope?.none)
                        ForEach(StartupItem.Scope.allCases, id: \.self) { s in Text(s.title).tag(StartupItem.Scope?.some(s)) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if items.contains(where: \.isBroken) {
                        TagBadge(text: "고장 \(items.filter(\.isBroken).count)개", symbol: "exclamationmark.triangle", tint: ClearColor.warning)
                    }
                    Spacer()
                    Button("로그인 시 열리는 앱…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link).font(ClearFont.callout)
                    .help("로그인할 때 열리는 앱 목록은 macOS 시스템 설정에서 관리합니다.")
                    SearchField(prompt: "항목 검색", text: $bindable.search)
                }
                if let error = model.lastError {
                    Text(error).font(ClearFont.caption).foregroundStyle(ClearColor.danger)
                        .padding(.horizontal, ClearMetrics.pagePadding).padding(.vertical, Space.xs)
                }
                if model.visible.isEmpty {
                    EmptyStateView(symbol: "power", title: "항목이 없습니다", message: "이 범위에는 로그인·부팅 시 실행되는 항목이 없습니다.")
                        .frame(maxHeight: .infinity)
                } else {
                    table(model)
                }
                footer(model)
            }
        }
    }

    private func table(_ model: StartupItemsModel) -> some View {
        @Bindable var model = model
        return Table(model.visible, selection: $model.selection) {
            TableColumn("항목") { (item: StartupItem) in
                HStack(spacing: Space.s) {
                    if let appPath = item.appPath {
                        AppIcon(path: appPath, size: 22)
                    } else {
                        Image(systemName: "gearshape.2").foregroundStyle(ClearColor.textSecondary).frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Space.xs) {
                            Text(item.displayName).lineLimit(1)
                            if item.isBroken { TagBadge(text: "프로그램 없음", tint: ClearColor.warning) }
                        }
                        Text(item.label).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 220, ideal: 340)
            TableColumn("상태") { (item: StartupItem) in
                statusText(item)
            }
            .width(min: 80, ideal: 100)
            TableColumn("범위") { (item: StartupItem) in
                Text(item.scope.title).foregroundStyle(ClearColor.textSecondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("켜짐") { (item: StartupItem) in
                if item.canToggle {
                    Toggle("", isOn: Binding(get: { !item.isDisabled }, set: { model.setEnabled(item, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .disabled(model.busy.contains(item.id))
                        .accessibilityLabel("\(item.displayName) 시작 시 실행")
                } else {
                    Image(systemName: "lock").foregroundStyle(ClearColor.textTertiary).help("관리자 권한이 필요해 Clear에서 바꾸지 않습니다")
                }
            }
            .width(54)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = model.visible.first(where: { $0.id == id }) {
                Button("설정 파일 Finder에서 보기") { FinderActions.reveal(item.plistPath) }
                if let program = item.program, item.programExists { Button("프로그램 Finder에서 보기") { FinderActions.reveal(program) } }
                if item.canRemove { Divider(); Button("삭제…") { model.remove(item) } }
            }
        } primaryAction: { ids in
            if let id = ids.first { FinderActions.reveal(id) }
        }
    }

    @ViewBuilder private func statusText(_ item: StartupItem) -> some View {
        if item.isDisabled {
            Text("꺼짐").foregroundStyle(ClearColor.textTertiary)
        } else if let pid = item.pid {
            Label("실행 중", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(ClearFont.callout)
                .foregroundStyle(ClearColor.success).help("PID \(pid)")
        } else if item.isLoaded == true {
            Text("대기 중").foregroundStyle(ClearColor.textSecondary)
        } else if item.isLoaded == false {
            Text("로드 안 됨").foregroundStyle(ClearColor.textTertiary)
        } else {
            Text("—").foregroundStyle(ClearColor.textTertiary)
        }
    }

    private func footer(_ model: StartupItemsModel) -> some View {
        let item = model.visible.first { $0.id == model.selection }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: Space.m) {
                if let item {
                    Text(item.program.map { PathUtilities.abbreviated($0) } ?? item.label)
                        .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("끄기는 이 계정에만 적용되고 언제든 다시 켤 수 있습니다. 시스템 항목은 보기만 합니다.")
                        .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
                Spacer()
                Button("Finder에서 보기") { if let item { FinderActions.reveal(item.plistPath) } }
                    .secondaryButton().disabled(item == nil)
                Button("삭제…") { if let item { model.remove(item) } }
                    .secondaryButton().disabled(item?.canRemove != true)
                    .help("내 계정의 항목만 삭제할 수 있습니다(휴지통으로 이동).")
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.s + 2)
        }
        .background(.bar)
    }
}
