import SwiftUI

struct SettingsView: View {
    @Environment(\.appModel) private var model

    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section("화면") {
                Picker("테마", selection: $store.settings.theme) {
                    ForEach(AppSettings.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("메뉴 막대 아이콘 표시", isOn: $store.settings.showMenuBarIcon)
            }

            Section("기능") {
                Toggle("개발자 모드", isOn: $store.settings.developerModeEnabled)
                Toggle("AI 도구 관리", isOn: $store.settings.aiToolsEnabled)
            }

            Section {
                ForEach([("Documents", "문서"), ("Desktop", "데스크탑"), ("Downloads", "다운로드"), ("Pictures", "사진"),
                         ("Movies", "동영상"), ("Music", "음악")], id: \.0) { folder, title in
                    Toggle(title, isOn: Binding(
                        get: { store.settings.overviewFolders.contains(folder) },
                        set: { on in
                            if on { store.settings.overviewFolders.append(folder) }
                            else { store.settings.overviewFolders.removeAll { $0 == folder } }
                        }))
                }
            } header: {
                Text("홈 화면 스캔 대상 폴더")
            } footer: {
                Text("처음 측정할 때 macOS가 폴더 접근 허용 여부를 묻습니다. 거절해도 다른 기능은 정상 동작합니다.")
            }

            Section {
                ForEach(store.settings.projectFolders) { folder in
                    HStack {
                        Label(PathUtilities.abbreviated(folder.path), systemImage: "folder")
                        Spacer()
                        Button("해제") { store.removeProjectFolder(folder) }.buttonStyle(.borderless)
                    }
                }
                Button("프로젝트 폴더 추가…") {
                    FinderActions.chooseFolders(message: "개발 프로젝트 폴더를 선택하세요").forEach { store.addProjectFolder($0) }
                }
            } header: {
                Text("개발 프로젝트 폴더")
            }

            Section {
                ForEach(store.settings.excludedPaths, id: \.self) { path in
                    HStack {
                        Label(PathUtilities.abbreviated(path), systemImage: "nosign")
                        Spacer()
                        Button("삭제") { store.settings.excludedPaths.removeAll { $0 == path } }.buttonStyle(.borderless)
                    }
                }
                Button("제외할 폴더 추가…") {
                    for url in FinderActions.chooseFolders(message: "정리에서 제외할 폴더를 선택하세요") {
                        let path = PathUtilities.canonicalPath(url.path) ?? url.path
                        if !store.settings.excludedPaths.contains(path) { store.settings.excludedPaths.append(path) }
                    }
                }
            } header: {
                Text("제외 경로")
            } footer: {
                Text("제외 경로와 그 안의 항목은 어떤 규칙으로도 정리되지 않습니다.")
            }

            Section {
                Toggle("휴지통 우선", isOn: $store.settings.preferTrash)
                Toggle("정리 전 항상 확인", isOn: .constant(true))
                    .disabled(true)
            } header: {
                Text("정리 방식")
            } footer: {
                Text("휴지통 우선을 끄면 재생성 가능한 캐시만 즉시 삭제합니다. 사용자 파일·앱·중복 파일·모델은 항상 휴지통으로 이동합니다. 정리 전 확인은 안전을 위해 끌 수 없습니다.")
            }

            Section("정리 기록") {
                Picker("보관 기간", selection: $store.settings.historyRetentionDays) {
                    Text("30일").tag(30); Text("90일").tag(90); Text("180일").tag(180); Text("1년").tag(365); Text("무제한").tag(0)
                }
                .onChange(of: store.settings.historyRetentionDays) { _, days in model.history.prune(retentionDays: days) }
                LabeledContent("저장된 기록", value: "\(model.history.records.count)개")
            }

            Section {
                Toggle("주기적으로 정리할 항목 알려주기", isOn: Binding(
                    get: { store.settings.autoScanEnabled },
                    set: { on in
                        store.settings.autoScanEnabled = on
                        if on { Task { _ = await BackgroundMonitor.requestAuthorization() } }
                    }))
                Picker("주기", selection: $store.settings.autoScanIntervalHours) {
                    Text("매일").tag(24); Text("매주").tag(168); Text("매달").tag(720)
                }
                .disabled(!store.settings.autoScanEnabled)
                Stepper("정리할 항목이 \(store.settings.reminderThresholdGB)GB 이상일 때 알림",
                        value: $store.settings.reminderThresholdGB, in: 1...200)
                    .disabled(!store.settings.autoScanEnabled)
                Toggle("로그인할 때 메뉴 막대에서 조용히 실행", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                if let error = model.loginItemError {
                    Text(error).font(ClearFont.caption).foregroundStyle(ClearColor.danger)
                }
                if let last = store.settings.lastReminderCheck {
                    LabeledContent("마지막 확인", value: last.formatted(.relative(presentation: .named)))
                }
            } header: {
                Text("정리 알림")
            } footer: {
                Text("캐시·삭제된 앱의 찌꺼기·숨겨진 캐시와 6개월 넘게 열지 않은 큰 파일을 확인해 알려 줍니다. 읽기만 하며 아무것도 자동으로 지우지 않습니다. 앱이 꺼져 있으면 확인하지 않으니, 로그인 시 실행을 함께 켜 두세요.")
            }

            Section {
                Toggle("저장공간 부족 알림", isOn: Binding(
                    get: { store.settings.lowStorageAlertEnabled },
                    set: { on in
                        store.settings.lowStorageAlertEnabled = on
                        if on { Task { _ = await BackgroundMonitor.requestAuthorization() } }
                    }))
                Stepper("기준: \(store.settings.lowStorageThresholdGB) GB 미만", value: $store.settings.lowStorageThresholdGB, in: 5...500, step: 5)
                    .disabled(!store.settings.lowStorageAlertEnabled)
            } header: {
                Text("알림")
            } footer: {
                Text("15분마다 볼륨 여유 공간만 확인합니다(파일 스캔 없음). 하루에 한 번까지만 알립니다.")
            }

            Section {
                LabeledContent("전체 디스크 접근") {
                    Label(model.hasFullDiskAccess ? "허용됨" : "허용 안 됨", systemImage: model.hasFullDiskAccess ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(model.hasFullDiskAccess ? ClearColor.success : ClearColor.textSecondary)
                }
                Button("개인정보 보호 및 보안 설정 열기") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }
                Button("권한 상태 다시 확인") { model.refreshPermissions() }
            } header: {
                Text("권한")
            } footer: {
                Text("전체 디스크 접근을 한 번 허용하면 문서·데스크탑 등 폴더마다 접근을 묻지 않고, 휴지통 비우기도 사용할 수 있습니다. 허용하지 않아도 다른 기능은 동작하며 일부 위치는 ‘접근 제한’으로 표시됩니다. Clear는 관리자 권한(sudo)을 요청하지 않고, 데이터를 외부로 보내지 않습니다.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("설정")
    }
}
