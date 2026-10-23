import SwiftUI

struct MenuBarView: View {
    @Environment(\.appModel) private var model
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(volume.availableForImportantUsage.formattedBytes).font(ClearFont.figure)
                        Text("사용 가능").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                        Spacer()
                        if model.general.isLoading { ProgressView().controlSize(.small) }
                    }
                    CapacityBar(segments: [CapacitySegment(id: "used", title: "사용 중", bytes: volume.used,
                                                           color: volume.usedFraction > 0.9 ? ClearColor.danger : ClearColor.textSecondary.opacity(0.6))],
                                total: volume.totalCapacity, height: 6)
                    Text("\(volume.name) · 전체 \(volume.totalCapacity.formattedBytes)").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                }
            }
            Divider()
            Group {
                if model.general.value != nil, let date = model.general.date {
                    HStack {
                        MetricView(title: "안전하게 정리 가능", value: model.smartCleanCandidates.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes)
                        Spacer()
                        MetricView(title: "전체 후보", value: model.cleanableBytes(model.allScanCandidates).formattedBytes)
                    }
                    Text("\(date.formatted(.relative(presentation: .named))) 스캔").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                } else if let last = model.settingsStore.lastScan {
                    Text("마지막 스캔 \(last.date.formatted(.relative(presentation: .named))) · 당시 후보 \(last.cleanableBytes.formattedBytes)")
                        .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    Text("현재 상태와 다를 수 있습니다").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                } else {
                    Text("아직 스캔하지 않았습니다").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                }
            }
            HStack(spacing: Space.s) {
                Button("빠른 스캔") { model.refreshVolume(); model.scanGeneral() }
                    .secondaryButton().disabled(model.general.isLoading)
                Spacer()
                Button("Clear 열기") { open(.overview) }.primaryButton()
            }
            Divider()
            HStack {
                Button("설정…") { open(.settings) }.buttonStyle(.borderless)
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.buttonStyle(.borderless).keyboardShortcut("q")
            }
            .font(ClearFont.callout)
            .foregroundStyle(ClearColor.textSecondary)
        }
        .padding(Space.l)
        .frame(width: 280)
        .onAppear { model.refreshVolume() }
    }

    private func open(_ item: SidebarItem) {
        close()
        model.selection = item
        model.openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
