import AppKit
import SwiftUI

/// Menu bar icon with a popover. Shown or hidden following
/// `AppSettings.showMenuBarIcon` (observed with Observation).
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(close: { [weak popover] in popover?.performClose(nil) })
            .appModel(model))
        sync()
    }

    /// Applies the setting, then re-arms observation for the next change.
    private func sync() {
        let visible = withObservationTracking {
            model.settings.showMenuBarIcon
        } onChange: { [weak self] in
            Task { @MainActor in self?.sync() }
        }
        if visible, item == nil {
            let newItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            newItem.button?.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Clear")
            newItem.button?.target = self
            newItem.button?.action = #selector(toggle(_:))
            item = newItem
        } else if !visible, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refreshVolume()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
