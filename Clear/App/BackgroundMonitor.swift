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
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.checkInterval ?? .seconds(900))
                guard let self else { return }
                await self.tick()
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
            let last = model.settingsStore.lastScan?.date ?? .distantPast
            if Date().timeIntervalSince(last) > Double(settings.autoScanIntervalHours) * 3600 {
                await model.scanGeneral().value
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "clear.lowStorage", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
