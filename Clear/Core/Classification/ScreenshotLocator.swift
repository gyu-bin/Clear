import Foundation

/// Where macOS saves screenshots, and which files look like screenshots.
enum ScreenshotLocator {
    /// `defaults read com.apple.screencapture location`, falling back to the Desktop.
    static func folder(home: URL) -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        return home.appendingPathComponent("Desktop")
    }

    static let prefixes = ["스크린샷", "Screenshot", "Screen Shot", "화면 기록", "Screen Recording", "스크린 샷", "CleanShot"]
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mov", "mp4", "gif"]

    static func isScreenshot(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased()) && prefixes.contains { name.hasPrefix($0) }
    }
}
