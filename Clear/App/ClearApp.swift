import SwiftUI

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !model.isRunningTests else { return }
        statusItem = StatusItemController(model: model)
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
