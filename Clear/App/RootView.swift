import SwiftUI

struct RootView: View {
    @Environment(\.appModel) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                // Theme in the identity: AppKit table headers do not repaint on a live appearance change.
                .id("\(model.selection?.rawValue ?? "")-\(model.settings.theme.rawValue)")
                .transition(.opacity)
                .animation(Motion.quick(reduceMotion), value: model.selection)
        }
        .sheet(isPresented: Binding(get: { model.cleanup.isPresented },
                                    set: { if !$0 { model.cleanup.dismiss() } })) {
            CleanupSheet().appModel(model)
        }
        .onAppear {
            model.applyTheme()
            let open = openWindow
            model.openMainWindow = { open(id: "main") }
        }
        .onChange(of: model.settings.theme) { _, _ in model.applyTheme() }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .overview {
        case .overview: OverviewView()
        case .smartCleanup: SmartCleanupView()
        case .diskExplorer: DiskExplorerView()
        case .largeFiles: LargeFilesView()
        case .applications: ApplicationsView()
        case .duplicates: DuplicatesView()
        case .developer: DeveloperView()
        case .aiTools: AIToolsView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

/// Native source-list sidebar. Groups are separated by spacing, not labels.
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Environment(\.appModel) private var model

    var body: some View {
        List(selection: $selection) {
            Section { ForEach(SidebarItem.primary) { row($0) } }
            Section { ForEach(SidebarItem.tools) { row($0) } }
            Section { ForEach(SidebarItem.other) { row($0) } }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { storageFooter }
    }

    private func row(_ item: SidebarItem) -> some View {
        let disabled = (item == .developer && !model.settings.developerModeEnabled)
            || (item == .aiTools && !model.settings.aiToolsEnabled)
        return HStack {
            Label(item.title, systemImage: item.symbol)
            Spacer()
            if isBusy(item) {
                ProgressView().controlSize(.mini)
            } else if let bytes = badgeBytes(item), bytes > 0 {
                Text(bytes.formattedBytes).font(ClearFont.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(disabled ? .secondary : .primary)
        .tag(item)
        .help(item.subtitle)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.subtitle)
    }

    private func badgeBytes(_ item: SidebarItem) -> Int64? {
        switch item {
        case .smartCleanup: model.general.value.map { model.cleanableBytes($0.candidates) }
        default: nil
        }
    }

    private func isBusy(_ item: SidebarItem) -> Bool {
        switch item {
        case .smartCleanup: model.general.isLoading
        case .developer: model.developer.isLoading
        case .aiTools: model.ai.isLoading
        case .diskExplorer: model.diskExplorer.state.isLoading
        case .largeFiles: model.largeFiles.state.isLoading
        case .duplicates: model.duplicates.exact.isLoading || model.duplicates.similar.isLoading
        default: false
        }
    }

    @ViewBuilder private var storageFooter: some View {
        if let volume = model.volume {
            VStack(alignment: .leading, spacing: Space.xs + 2) {
                ProgressView(value: volume.usedFraction)
                    .tint(volume.usedFraction > 0.9 ? ClearColor.danger : ClearColor.textSecondary)
                    .controlSize(.small)
                Text("\(volume.availableForImportantUsage.formattedBytes) 사용 가능")
                    .font(ClearFont.caption.monospacedDigit()).foregroundStyle(ClearColor.textSecondary)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.m)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(volume.name) \(volume.availableForImportantUsage.formattedBytes) 사용 가능")
        }
    }
}
