import Foundation

/// Curated knowledge about entries in `~/Library/Caches`.
///
/// Only names listed in `knownRegenerable` are SAFE. Everything else is REVIEW —
/// "it lives in Caches" is not by itself proof that deleting it is harmless.
enum CacheKnowledgeBase {
    /// Never touch: account state, sync engines, in-flight downloads, security data.
    static let blocked: [String: String] = [
        "CloudKit": "iCloud 동기화 상태",
        "com.apple.bird": "iCloud Drive 동기화 엔진",
        "com.apple.nsurlsessiond": "진행 중인 백그라운드 다운로드",
        "com.apple.akd": "Apple 계정 인증",
        "com.apple.appleaccountd": "Apple 계정",
        "com.apple.amsaccountsd": "Apple 미디어 계정",
        "com.apple.AuthenticationServicesCore.AuthenticationServicesAgent": "인증 서비스",
        "com.apple.HomeKit": "홈 데이터",
        "com.apple.homed": "홈 데이터",
        "com.apple.containermanagerd": "앱 컨테이너 관리",
        "familycircled": "가족 공유",
        "com.apple.Family-Settings.extension": "가족 공유",
        "com.apple.passd": "Wallet",
        "PassKit": "Wallet",
        "com.apple.icloudmailagent": "iCloud 메일",
        "com.apple.iCloudNotificationAgent": "iCloud 알림",
        "com.apple.cache_delete": "macOS 저장공간 관리",
        "com.apple.Safari.SafeBrowsing": "Safari 보안 데이터베이스",
        "com.apple.XProtectFramework.plugins.BadGacha": "XProtect 보안",
        "com.apple.ScreenTimeAgent": "스크린 타임",
        "com.apple.findmy.fmipcore": "나의 찾기",
        "TemporaryItems": "시스템 임시 항목",
    ]

    /// Caches known to be fully rebuilt by their owner. Still guarded by the app's process.
    static let knownRegenerable: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.figma.Desktop": "Figma",
        "com.figma.agent": "Figma Agent",
        "notion.id": "Notion",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.brave.Browser": "Brave",
        "com.operasoftware.Opera": "Opera",
        "Arc": "Arc",
        "Firefox": "Firefox",
        "com.google.GoogleUpdater": "Google Updater",
        "org.sparkle-project.DownloaderService": "Sparkle 업데이트 다운로드",
        "notion-updater": "Notion 업데이트",
        "SentryCrash": "Sentry 충돌 보고서 캐시",
        "io.sentry": "Sentry 캐시",
        "segment": "분석 SDK 캐시",
        "amplitude": "분석 SDK 캐시",
        "com.datadoghq": "Datadog SDK 캐시",
    ]

    /// Bundle IDs whose folder name differs from the running app bundle ID.
    static let guardOverrides: [String: ProcessGuard] = [
        "Arc": .app("company.thebrowser.Browser", "Arc"),
        "Firefox": .app("org.mozilla.firefox", "Firefox"),
        "Google": .app("com.google.Chrome", "Google Chrome"),
        "notion-updater": .app("notion.id", "Notion"),
    ]

    /// Folders owned by Developer / AI Tools adapters. Smart Cleanup skips them so the
    /// same bytes are never offered (or summed) twice.
    static let ownedByAdapters: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.dt.xcodebuild", "com.apple.dt.Xcode.ITunesSoftwareService",
        "org.swift.swiftpm", "Homebrew", "Yarn", "node-gyp", "pip", "CocoaPods", "ms-playwright",
        "typescript", "pnpm", "claude-cli-nodejs", "com.anthropic.claudefordesktop",
        "com.anthropic.claudefordesktop.ShipIt", "com.openai.codex", "Codex", "cursor-compile-cache",
        "com.todesktop.230313mzl4w4u92", "com.todesktop.230313mzl4w4u92.ShipIt", "JetBrains",
        "eas-cli", "com.vercel.cli", "main.kts.compiled.cache", "JNA", "deno", "bun",
    ]

    static func isUpdaterLeftover(_ name: String) -> Bool {
        name.hasSuffix(".ShipIt")
    }

    /// Bundle id guarding a cache folder, if the name looks like one.
    static func guardFor(folder name: String, appName: String?) -> ProcessGuard? {
        if let override = guardOverrides[name] { return override }
        var base = name
        if base.hasSuffix(".ShipIt") { base.removeLast(".ShipIt".count) }
        guard base.contains("."), !base.hasPrefix(".") else { return nil }
        return .app(base, appName ?? base)
    }
}
