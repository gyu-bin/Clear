import AppKit

@MainActor
enum FinderActions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Shows an open panel restricted to folders. Returns the chosen URLs.
    static func chooseFolders(message: String, allowsMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.canCreateDirectories = false
        panel.message = message
        panel.prompt = "선택"
        return panel.runModal() == .OK ? panel.urls : []
    }
}
