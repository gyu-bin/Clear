import Foundation
import UserNotifications

/// Optional background behaviour, both off by default:
/// * low-storage notification (cheap volume capacity query only)
/// * periodic Smart Cleanup scan (no deletion — results are only shown)
@MainActor
final class BackgroundMonitor {
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    private var lastAlert: Date?
    private let checkInterval: Duration = .seconds(15 * 60)

    init(model: AppModel) { self.model = model }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            // First check shortly after launch (e.g. after a login launch), then every 15 minutes.
            try? await Task.sleep(for: .seconds(120))
            while !Task.isCancelled {
                guard let first = self else { return }
                await first.tick()
                try? await Task.sleep(for: self?.checkInterval ?? .seconds(900))
            }
        }
    }

    func stop() { task?.cancel() }

    private func tick() async {
        guard let model else { return }
        let settings = model.settings
        if settings.lowStorageAlertEnabled {
            model.refreshVolume()
            if let volume = model.volume,
               volume.availableForImportantUsage < Int64(settings.lowStorageThresholdGB) * 1_000_000_000,
               lastAlert.map({ Date().timeIntervalSince($0) > 24 * 3600 }) ?? true {
                lastAlert = Date()
                await Self.notify(title: "저장공간이 부족합니다",
                                  body: "사용 가능 공간이 \(volume.availableForImportantUsage.formattedBytes) 남았습니다. Clear에서 정리 후보를 확인하세요.")
            }
        }
        if settings.autoScanEnabled, !model.isScanningMac, !model.general.isLoading, !model.cleanup.isRunning {
            let last = settings.lastReminderCheck ?? .distantPast
            if Date().timeIntervalSince(last) > Double(settings.autoScanIntervalHours) * 3600 {
                await runReminder(model)
            }
        }
    }

    /// Periodic "things you could clean" check. Scans read-only, never deletes;
    /// notifies only when the total reaches the user's threshold.
    private func runReminder(_ model: AppModel) async {
        model.settingsStore.settings.lastReminderCheck = Date()
        await model.scanGeneral().value
        await model.largeFiles.scan()?.value

        let junk = (model.general.value?.candidates ?? []).filter { $0.risk != .blocked && $0.category != .downloads }
        let installers = (model.general.value?.candidates ?? []).filter { $0.category == .downloads }
        let cutoff = Date().addingTimeInterval(-182 * 86_400)
        let oldLarge = (model.largeFiles.state.value?.items ?? []).filter { $0.allocatedSize >= 500 * 1024 * 1024 && $0.lastUsed < cutoff }

        let junkBytes = junk.reduce(0) { $0 + $1.estimatedBytes }
        let installerBytes = installers.reduce(0) { $0 + $1.estimatedBytes }
        let largeBytes = oldLarge.reduce(0) { $0 + $1.allocatedSize }
        let total = junkBytes + installerBytes + largeBytes
        guard total >= Int64(model.settings.reminderThresholdGB) * 1_000_000_000 else { return }

        var parts: [String] = []
        if junkBytes > 0 { parts.append("캐시·찌꺼기 \(junkBytes.formattedBytes)") }
        if !installers.isEmpty { parts.append("다운로드의 큰 파일 \(installers.count)개") }
        if !oldLarge.isEmpty { parts.append("6개월 넘게 안 연 큰 파일 \(oldLarge.count)개(\(largeBytes.formattedBytes))") }
        let target: SidebarItem = largeBytes > junkBytes + installerBytes ? .largeFiles : .smartCleanup
        await Self.notify(title: "정리할 수 있는 항목 \(total.formattedBytes)",
                          body: parts.joined(separator: " · ") + ". 눌러서 확인하세요. 아무것도 자동으로 지우지 않습니다.",
                          identifier: "clear.reminder", target: target)
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func notify(title: String, body: String, identifier: String = "clear.lowStorage",
                       target: SidebarItem = .overview) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["target": target.rawValue]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
