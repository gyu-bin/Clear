import SwiftUI

/// Compact empty state: small symbol, one line of title, one short message.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(ClearColor.textTertiary)
                .padding(.bottom, Space.xs)
            Text(title).font(ClearFont.headline).foregroundStyle(ClearColor.textPrimary)
            Text(message).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action).primaryButton().padding(.top, Space.xs)
            }
        }
        .padding(.vertical, Space.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Inline error with retry.
struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ClearColor.danger)
            Text(message).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary).textSelection(.enabled)
            Spacer()
            if let retry { Button("다시 시도", action: retry).secondaryButton() }
        }
        .padding(.vertical, Space.s)
    }
}

/// Inline scan progress: phase, native progress bar, current item, cancel.
struct ScanProgressView: View {
    let progress: ScanProgress
    var onCancel: (() -> Void)? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(progress.phase).font(ClearFont.headline)
                if progress.itemsVisited > 0 {
                    Text("\(progress.itemsVisited.formatted())개 확인").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textTertiary)
                }
                Spacer()
                if let onCancel { Button("취소", action: onCancel).secondaryButton().keyboardShortcut(.cancelAction) }
            }
            Group {
                if let fraction = progress.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            }
            .tint(ClearColor.accentBright)
            Text(progress.detail.isEmpty ? " " : progress.detail).font(ClearFont.mono).foregroundStyle(ClearColor.textTertiary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }
}

/// Permission note shown inline (not as a card).
struct PermissionNoticeView: View {
    let title: String
    let message: String
    var paths: [String] = []
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "lock").foregroundStyle(ClearColor.warning)
                Text(title).font(ClearFont.callout.weight(.medium))
                Spacer()
                if !paths.isEmpty {
                    Button(expanded ? "접기" : "위치 보기") { expanded.toggle() }.buttonStyle(.link).font(ClearFont.callout)
                }
                Button("시스템 설정…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link).font(ClearFont.callout)
            }
            Text(message).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary).padding(.leading, 22)
            if expanded {
                Text(paths.prefix(12).map { PathUtilities.abbreviated($0) }.joined(separator: "\n")
                     + (paths.count > 12 ? "\n외 \(paths.count - 12)곳" : ""))
                    .font(ClearFont.mono).foregroundStyle(ClearColor.textTertiary).textSelection(.enabled).padding(.leading, 22)
            }
        }
    }
}
