import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct ClearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Clear", id: "main") {
            RootView()
                .appModel(appDelegate.model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands { ClearCommands(model: appDelegate.model) }

        Settings {
            SettingsView()
                .appModel(appDelegate.model)
                .frame(width: 640, height: 640)
        }
    }
}

/// Owns the single `AppModel` and the menu bar item.
///
/// The menu bar item is an AppKit `NSStatusItem` instead of a SwiftUI
/// `MenuBarExtra` scene: with `MenuBarExtra` the app intermittently crashed at
/// launch (re-entrant scene graph updates exhausting the main-thread stack).
/// Keeping it outside the scene graph removed the crash (verified by repeated
/// launch tests, see scripts/launch-test.sh).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !model.isRunningTests else { return }
        statusItem = StatusItemController(model: model)
        UNUserNotificationCenter.current().delegate = self
        // Started at login: stay quietly in the menu bar (when the icon is enabled).
        if launchedAsLoginItem && model.settings.showMenuBarIcon {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true { window.close() }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["target"] as? String
        await MainActor.run {
            if let raw, let target = SidebarItem(rawValue: raw) { model.selection = target }
            model.openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.openMainWindow?() }
        return true
    }
}

struct ClearCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Mac 스캔") { model.scanMac() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("스마트 정리") { model.smartClean() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandMenu("이동") {
            ForEach(SidebarItem.allCases) { item in
                if let key = item.shortcut {
                    Button(item.title) { model.selection = item }.keyboardShortcut(key, modifiers: [.command])
                }
            }
        }
    }
}
