import SwiftUI

/// Scrolling page. The title and actions live in the window toolbar (native
/// macOS), so content starts directly without a duplicated in-page header.
struct PageContainer<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                content()
            }
            .padding(.horizontal, ClearMetrics.pagePadding)
            .padding(.vertical, Space.l)
            .frame(maxWidth: ClearMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ClearColor.background)
        .pageChrome(title: title, subtitle: subtitle, actions: actions)
    }
}

/// Non-scrolling page for table / list layouts that manage their own scrolling.
struct FixedPage<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        // One container, so modifiers apply once (not to each child of a multi-view builder).
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ClearColor.background)
            .pageChrome(title: title, subtitle: subtitle, actions: actions)
    }
}

extension View {
    func pageChrome<Actions: View>(title: String, subtitle: String?, @ViewBuilder actions: () -> Actions) -> some View {
        navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions() } }
    }
}

/// Section title with optional trailing accessory; no container.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(title).font(ClearFont.sectionTitle).foregroundStyle(ClearColor.textPrimary).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary) }
            Spacer()
            trailing()
        }
    }
}

/// "3분 전 스캔"
struct FreshnessLabel: View {
    let date: Date?
    var prefix = "스캔"

    var body: some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("\(date.formatted(.relative(presentation: .named))) \(prefix)")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
            }
        }
    }
}

/// Slim control bar under the toolbar for view switches and filters, so the
/// window toolbar stays small (a crowded toolbar forces a minimum width on the
/// detail column and squeezes the sidebar).
struct ControlBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) { content() }
                .padding(.horizontal, ClearMetrics.pagePadding)
                .padding(.vertical, Space.s)
            Divider()
        }
    }
}

/// Compact search field for control bars.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(ClearColor.textTertiary).font(.system(size: 11))
            TextField(prompt, text: $text).textFieldStyle(.plain).font(ClearFont.callout)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(ClearColor.textTertiary)
                    .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, Space.s).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(ClearColor.elevated))
        .frame(width: 200)
    }
}
