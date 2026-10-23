import SwiftUI

extension CleanupCandidate {
    var sortDate: Date { lastModified ?? .distantPast }
    var riskRank: Int {
        switch risk {
        case .safe: 0
        case .review: 1
        case .manual: 2
        case .blocked: 3
        }
    }
    var categoryTitle: String { category.title }
}

/// Finder-style table of cleanup candidates. Checkboxes decide what gets cleaned;
/// row selection (click) only opens the detail inspector.
struct CandidateTable: View {
    let candidates: [CleanupCandidate]
    @Binding var checked: Set<String>
    @Binding var focused: CleanupCandidate.ID?
    var showsCategory = true
    @State private var sortOrder = [KeyPathComparator(\CleanupCandidate.estimatedBytes, order: .reverse)]

    private var rows: [CleanupCandidate] { candidates.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $focused, sortOrder: $sortOrder) {
            TableColumn("") { (c: CleanupCandidate) in
                Toggle("", isOn: Binding(
                    get: { checked.contains(c.id) },
                    set: { on in if on { checked.insert(c.id) } else { checked.remove(c.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(!c.risk.isSelectable)
                    .accessibilityLabel("\(c.title) 선택")
            }
            .width(18)

            TableColumn("이름", value: \.title) { (c: CleanupCandidate) in
                CandidateNameCell(candidate: c)
            }
            .width(min: 160, ideal: 300)

            TableColumn("크기", value: \.estimatedBytes) { (c: CleanupCandidate) in
                Text(c.estimatedBytes.formattedBytes).font(ClearFont.numeric)
                    .foregroundStyle(c.risk == .blocked ? ClearColor.textTertiary : ClearColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 76)

            TableColumn("위험도", value: \.riskRank) { (c: CleanupCandidate) in
                RiskBadge(risk: c.risk)
            }
            .width(min: 64, ideal: 80)

            TableColumn("종류", value: \.categoryTitle) { (c: CleanupCandidate) in
                Text(c.categoryTitle).foregroundStyle(ClearColor.textSecondary).lineLimit(1)
            }
            .width(min: 60, ideal: 100)

            TableColumn("수정일", value: \.sortDate) { (c: CleanupCandidate) in
                Text(c.lastModified.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(ClearColor.textSecondary).lineLimit(1)
            }
            .width(min: 60, ideal: 84)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: CleanupCandidate.ID.self) { ids in
            if let id = ids.first, let path = candidates.first(where: { $0.id == id })?.path {
                Button("Finder에서 보기") { FinderActions.reveal(path) }
                Button("경로 복사") { FinderActions.copyPath(path) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let path = candidates.first(where: { $0.id == id })?.path { FinderActions.reveal(path) }
        }
    }
}

private struct CandidateNameCell: View {
    let candidate: CleanupCandidate

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: candidate.category.symbol).foregroundStyle(ClearColor.textSecondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(candidate.title).lineLimit(1)
                        .foregroundStyle(candidate.risk == .blocked ? ClearColor.textTertiary : ClearColor.textPrimary)
                    if !candidate.runningGuards.isEmpty {
                        TagBadge(text: "실행 중", tint: ClearColor.warning).help(candidate.runningGuards.joined(separator: ", "))
                    }
                }
                Text(candidate.subtitle).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Detail for the focused candidate (shown in the inspector).
struct CandidateInspector: View {
    let candidate: CleanupCandidate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(candidate.title).font(ClearFont.headline).textSelection(.enabled).padding(.trailing, Space.xl)
                    Text(candidate.subtitle).font(ClearFont.mono).foregroundStyle(ClearColor.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text(candidate.estimatedBytes.formattedBytes).font(ClearFont.figure)

                detail("위험도") {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RiskBadge(risk: candidate.risk)
                        Text(candidate.riskReason).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    }
                }
                detail("삭제 후 영향") { Text(candidate.impact).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary) }
                if let warning = candidate.warning {
                    detail("주의") { Text(warning).font(ClearFont.callout).foregroundStyle(ClearColor.warning) }
                }
                if !candidate.runningGuards.isEmpty {
                    detail("실행 중") {
                        Text("\(candidate.runningGuards.joined(separator: ", ")) — 정리 시점에 다시 확인하고, 실행 중이면 건너뜁니다.")
                            .font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    }
                }
                detail("크기") {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xs) {
                        row("디스크 할당", candidate.size.allocated.formattedBytes)
                        row("논리 크기", candidate.size.logical.formattedBytes)
                        if candidate.size.itemCount > 1 { row("파일", "\(candidate.size.fileCount.formatted())개") }
                        if candidate.size.sharedHardLinkBytes > 0 { row("하드 링크 공유", candidate.size.sharedHardLinkBytes.formattedBytes) }
                        if let date = candidate.lastModified { row("수정일", date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                }
                detail("정리 방법") {
                    Text(methodDescription).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                }
                if let path = candidate.path {
                    HStack {
                        Button("Finder에서 보기") { FinderActions.reveal(path) }.secondaryButton()
                        Button("경로 복사") { FinderActions.copyPath(path) }.secondaryButton()
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var methodDescription: String {
        if case .command(let c) = candidate.target { return "공식 명령 실행: \(c.displayCommand)" }
        if !candidate.allowsPermanentRemoval { return "항상 휴지통으로 이동 (복구 가능)" }
        return "기본은 휴지통으로 이동. ‘휴지통 우선’을 끄면 재생성 가능한 캐시만 즉시 삭제"
    }

    private func detail<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(ClearFont.captionEmphasis).foregroundStyle(ClearColor.textTertiary)
            content()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
            Text(value).font(ClearFont.numericSmall)
        }
    }
}

/// Bottom bar: selection summary, selection menu, primary action.
struct CleanupActionBar: View {
    let candidates: [CleanupCandidate]
    @Binding var checked: Set<String>
    var actionTitle = "정리…"
    let onClean: () -> Void

    private var selected: [CleanupCandidate] { candidates.filter { checked.contains($0.id) && $0.risk.isSelectable } }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Space.m) {
                Menu {
                    Button("안전 항목만 선택") { checked = Set(candidates.filter(\.isDefaultSelected).map(\.id)) }
                    Button("선택 가능한 항목 모두 선택") { checked = Set(candidates.filter { $0.risk.isSelectable }.map(\.id)) }
                    Divider()
                    Button("선택 해제") { checked.removeAll() }
                } label: {
                    Text("\(selected.count)개 선택")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text(selected.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes)
                    .font(ClearFont.numeric).foregroundStyle(ClearColor.textSecondary)
                Spacer()
                Button(actionTitle, action: onClean)
                    .primaryButton()
                    .disabled(selected.isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s + 2)
        }
        .background(.bar)
    }
}

/// Fixed-width trailing detail pane. Unlike `.inspector`, its width does not
/// follow the content's ideal width, so long unbreakable paths cannot push the
/// window layout around.
struct DetailPane<Pane: View>: ViewModifier {
    let isPresented: Bool
    let onClose: () -> Void
    @ViewBuilder let pane: () -> Pane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if isPresented {
                Divider()
                pane()
                    .frame(width: 290)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .topTrailing) {
                        IconButton(symbol: "xmark", help: "닫기", action: onClose)
                            .keyboardShortcut(.cancelAction)
                            .padding(Space.s)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.standard(reduceMotion), value: isPresented)
    }
}

extension View {
    func detailPane<Pane: View>(isPresented: Bool, onClose: @escaping () -> Void, @ViewBuilder pane: @escaping () -> Pane) -> some View {
        modifier(DetailPane(isPresented: isPresented, onClose: onClose, pane: pane))
    }

    /// Shows the candidate detail while a row is focused.
    func candidateInspector(_ focused: Binding<CleanupCandidate.ID?>, candidates: [CleanupCandidate]) -> some View {
        let candidate = focused.wrappedValue.flatMap { id in candidates.first { $0.id == id } }
        return detailPane(isPresented: candidate != nil, onClose: { focused.wrappedValue = nil }) {
            if let candidate { CandidateInspector(candidate: candidate).id(candidate.id) }
        }
    }
}

enum RiskFilter: String, CaseIterable, Identifiable {
    case all, safe, review, manual, blocked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "전체"
        case .safe: "안전"
        case .review: "검토"
        case .manual: "직접 선택"
        case .blocked: "보호됨"
        }
    }

    func matches(_ c: CleanupCandidate) -> Bool {
        switch self {
        case .all: c.risk != .blocked
        case .safe: c.risk == .safe
        case .review: c.risk == .review
        case .manual: c.risk == .manual
        case .blocked: c.risk == .blocked
        }
    }
}

/// Inline risk summary: "● 안전 2.2GB  ● 검토 4.2GB …"
struct RiskSummary: View {
    let candidates: [CleanupCandidate]

    var body: some View {
        HStack(spacing: Space.xl) {
            ForEach([RiskLevel.safe, .review, .manual], id: \.self) { risk in
                let items = candidates.filter { $0.risk == risk }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: 5) {
                        Circle().fill(ClearColor.risk(risk)).frame(width: 6, height: 6)
                        Text("\(risk.title) \(items.count)").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
                    }
                    Text(items.reduce(0) { $0 + $1.estimatedBytes }.formattedBytes).font(ClearFont.figureSmall)
                }
                .help(risk.explanation)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
