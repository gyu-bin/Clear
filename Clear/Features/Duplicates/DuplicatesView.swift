import SwiftUI

struct DuplicatesView: View {
    @Environment(\.appModel) private var app
    @State private var rejected: [URL] = []

    var body: some View {
        let model = app.duplicates
        @Bindable var bindable = model
        FixedPage(title: "중복 파일", subtitle: subtitle(model)) {
            Button { addFolders() } label: { Label("폴더 추가", systemImage: "folder.badge.plus") }
            if !isLoading(model) {
                Button { model.scan() } label: { Label("스캔", systemImage: "magnifyingglass") }
                    .disabled(model.roots.isEmpty)
            }
        } content: {
            VStack(spacing: 0) {
                FolderBar(model: model, rejected: rejected, settings: app.settingsStore)
                    .padding(.horizontal, ClearMetrics.pagePadding).padding(.vertical, Space.s + 2)
                Divider()
                switch model.mode {
                case .exact: ExactResults(model: model, addFolders: addFolders)
                case .similar: SimilarResults(model: model, addFolders: addFolders)
                }
            }
        }
        .onAppear { model.restoreRoots() }
    }

    private func subtitle(_ m: DuplicatesModel) -> String? {
        switch m.mode {
        case .exact: m.exact.value.map { "\($0.groups.count)개 그룹 · \($0.wastedBytes.formattedBytes) 중복" }
        case .similar: m.similar.value.map { "\($0.groups.count)개 묶음 · 사진 \($0.analyzedImages)장 분석" }
        }
    }

    private func isLoading(_ m: DuplicatesModel) -> Bool { m.mode == .exact ? m.exact.isLoading : m.similar.isLoading }

    private func addFolders() {
        rejected = app.duplicates.addRoots(FinderActions.chooseFolders(message: "중복 파일을 찾을 폴더를 선택하세요 (홈 폴더 안 또는 외장 볼륨)"))
    }
}

private struct FolderBar: View {
    let model: DuplicatesModel
    let rejected: [URL]
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Picker("모드", selection: Bindable(model).mode) { ForEach(DuplicatesModel.Mode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Divider().frame(height: 16)
                Text("검사할 폴더").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                if model.roots.isEmpty {
                    Text("없음").font(ClearFont.callout).foregroundStyle(ClearColor.textTertiary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(model.roots, id: \.self) { url in
                            HStack(spacing: Space.xs) {
                                Text(PathUtilities.abbreviated(url.path)).font(ClearFont.callout)
                                Button { model.removeRoot(url) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).font(.system(size: 9, weight: .semibold))
                                    .accessibilityLabel("\(url.lastPathComponent) 제거")
                            }
                            .padding(.horizontal, Space.s).padding(.vertical, 3)
                            .background(Capsule().fill(ClearColor.elevated))
                        }
                    }
                }
                Spacer()
                if model.mode == .exact {
                    Stepper("최소 \(settings.settings.duplicateMinimumSizeMB)MB", value: $settings.settings.duplicateMinimumSizeMB, in: 1...1024)
                        .font(ClearFont.callout).fixedSize()
                } else {
                    Text("유사도").font(ClearFont.callout).foregroundStyle(ClearColor.textSecondary)
                    Slider(value: $settings.settings.similarPhotoThreshold, in: 0.15...0.6).frame(width: 120)
                        .help("왼쪽일수록 엄격하게 비교합니다")
                }
            }
            if !rejected.isEmpty {
                Text("홈 폴더 밖의 위치는 추가할 수 없습니다: \(rejected.map(\.path).joined(separator: ", "))")
                    .font(ClearFont.caption).foregroundStyle(ClearColor.warning)
            }
        }
    }
}

private struct MarkBar: View {
    let model: DuplicatesModel
    let files: [(String, Int64)]

    var body: some View {
        let marked = files.filter { model.marked.contains($0.0) }
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Space.m) {
                Menu("\(marked.count)개 선택") {
                    if model.mode == .exact { Button("원본이 명확한 그룹만 자동 선택") { model.selectSuggested() } }
                    Button("선택 해제") { model.marked.removeAll() }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Text(marked.reduce(0) { $0 + $1.1 }.formattedBytes).font(ClearFont.numeric).foregroundStyle(ClearColor.textSecondary)
                Text("각 그룹에서 최소 한 개는 항상 남깁니다").font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                Spacer()
                Button("휴지통으로 이동…") { model.requestCleanup() }.primaryButton().disabled(marked.isEmpty)
            }
            .padding(.horizontal, Space.l).padding(.vertical, Space.s + 2)
        }
        .background(.bar)
    }
}

private struct ExactResults: View {
    let model: DuplicatesModel
    let addFolders: () -> Void

    var body: some View {
        switch model.exact {
        case .idle:
            EmptyStateView(symbol: "doc.on.doc", title: model.roots.isEmpty ? "검사할 폴더를 추가하세요" : "스캔할 준비가 되었습니다",
                           message: "크기로 후보를 좁힌 뒤 SHA-256으로 내용이 같은지 확인합니다. iCloud에만 있는 파일은 내려받지 않고, 사진 보관함 내부는 검사하지 않습니다.",
                           actionTitle: model.roots.isEmpty ? "폴더 추가" : "스캔",
                           action: { model.roots.isEmpty ? addFolders() : model.scan() })
                .frame(maxHeight: .infinity)
        case .loading(let p):
            ScanProgressView(progress: p, onCancel: { model.cancel() }).padding(ClearMetrics.pagePadding)
            Spacer()
        case .failed(let e):
            ErrorStateView(message: e) { model.scan() }.padding(ClearMetrics.pagePadding)
            Spacer()
        case .loaded(let result, _):
            if result.groups.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "중복 파일이 없습니다",
                               message: "\(result.scannedFiles.formatted())개 파일을 검사했습니다.")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(result.groups.prefix(500)) { group in
                        Section { ForEach(group.files) { DuplicateRow(file: $0, group: group, model: model) } } header: { groupHeader(group) }
                    }
                    if result.skippedCloudOnly > 0 || !result.skippedProtected.isEmpty || result.hardLinkSets > 0 {
                        Section {
                            Text("건너뜀: iCloud 전용 파일 \(result.skippedCloudOnly)개 · 사진 보관함 \(result.skippedProtected.count)개 · 하드 링크 \(result.hardLinkSets)세트(같은 파일이므로 중복 아님)")
                                .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                MarkBar(model: model, files: result.groups.flatMap(\.files).map { ($0.path, $0.allocatedSize) })
            }
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack(spacing: Space.s) {
            Text(group.files[0].name).font(ClearFont.headline).foregroundStyle(ClearColor.textPrimary).lineLimit(1)
            Text("\(group.files.count)개 · 각 \(group.fileSize.formattedBytes)").font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
            if group.suggestedKeeper == nil {
                TagBadge(text: "원본 불명확", tint: ClearColor.warning).help("원본을 추정할 수 없어 자동으로 선택하지 않습니다")
            }
            Spacer()
            Text("\(group.wastedBytes.formattedBytes) 중복").font(ClearFont.numericSmall).foregroundStyle(ClearColor.textSecondary)
        }
    }
}

private struct DuplicateRow: View {
    let file: DuplicateFile
    let group: DuplicateGroup
    let model: DuplicatesModel

    var body: some View {
        let paths = group.files.map(\.path)
        let marked = model.marked.contains(file.path)
        HStack(spacing: Space.s) {
            Toggle("", isOn: Binding(get: { marked }, set: { _ in model.toggle(file.path, in: paths) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("\(file.name) 휴지통으로 이동 선택")
            ThumbnailView(path: file.path, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(file.name).lineLimit(1)
                    if file.path == group.suggestedKeeper { TagBadge(text: "원본 추정") }
                    if !file.hardLinks.isEmpty { TagBadge(text: "하드 링크 \(file.hardLinks.count)") }
                }
                Text(PathUtilities.abbreviated((file.path as NSString).deletingLastPathComponent))
                    .font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(file.modified.formatted(date: .abbreviated, time: .shortened)).font(ClearFont.caption).foregroundStyle(ClearColor.textSecondary)
            Text(marked ? "삭제" : "보존").font(ClearFont.caption)
                .foregroundStyle(marked ? ClearColor.warning : ClearColor.textTertiary).frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("이 파일만 보존") { model.keepOnly(file.path, in: paths) }
            Button("Finder에서 보기") { FinderActions.reveal(file.path) }
            Button("열기") { FinderActions.open(file.path) }
        }
        .onTapGesture(count: 2) { FinderActions.reveal(file.path) }
    }
}

private struct SimilarResults: View {
    let model: DuplicatesModel
    let addFolders: () -> Void

    var body: some View {
        switch model.similar {
        case .idle:
            EmptyStateView(symbol: "photo.on.rectangle", title: "비슷한 사진 찾기",
                           message: "Vision으로 사진의 특징을 비교합니다. 편집본·다른 해상도가 함께 묶일 수 있어 아무것도 자동 선택하지 않습니다.",
                           actionTitle: model.roots.isEmpty ? "폴더 추가" : "스캔",
                           action: { model.roots.isEmpty ? addFolders() : model.scan() })
                .frame(maxHeight: .infinity)
        case .loading(let p):
            ScanProgressView(progress: p, onCancel: { model.cancel() }).padding(ClearMetrics.pagePadding)
            Spacer()
        case .failed(let e):
            ErrorStateView(message: e) { model.scan() }.padding(ClearMetrics.pagePadding)
            Spacer()
        case .loaded(let result, _):
            if result.groups.isEmpty {
                EmptyStateView(symbol: "checkmark.circle", title: "비슷한 사진이 없습니다",
                               message: "사진 \(result.analyzedImages)장을 분석했습니다. 유사도를 느슨하게 바꿔 다시 시도할 수 있습니다.")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    if result.truncated {
                        Text("사진이 많아 처음 \(result.analyzedImages)장만 분석했습니다. 폴더를 나눠서 스캔하세요.")
                            .font(ClearFont.caption).foregroundStyle(ClearColor.warning)
                    }
                    ForEach(result.groups.prefix(300)) { group in
                        Section {
                            SimilarStrip(group: group, model: model)
                        } header: {
                            Text("\(group.images.count)장 · 직접 비교해 지울 사진을 고르세요").font(ClearFont.caption)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                MarkBar(model: model, files: result.groups.flatMap(\.images).map { ($0.path, $0.size) })
            }
        }
    }
}

private struct SimilarStrip: View {
    let group: SimilarImageGroup
    let model: DuplicatesModel

    var body: some View {
        let paths = group.images.map(\.path)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(group.images) { image in
                    let marked = model.marked.contains(image.path)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        ThumbnailView(path: image.path, size: 132)
                            .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(marked ? ClearColor.warning : .clear, lineWidth: 2))
                            .onTapGesture(count: 2) { FinderActions.open(image.path) }
                        Toggle(isOn: Binding(get: { marked }, set: { _ in model.toggle(image.path, in: paths) })) {
                            Text(image.name).font(ClearFont.caption).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        .frame(width: 132, alignment: .leading)
                        Text("\(image.pixelWidth)×\(image.pixelHeight) · \(image.size.formattedBytes)")
                            .font(ClearFont.caption.monospacedDigit()).foregroundStyle(ClearColor.textTertiary)
                        Text(image.modified.formatted(date: .abbreviated, time: .shortened)).font(ClearFont.caption).foregroundStyle(ClearColor.textTertiary)
                    }
                    .contextMenu { Button("Finder에서 보기") { FinderActions.reveal(image.path) } }
                }
            }
            .padding(.vertical, Space.xs)
        }
    }
}
