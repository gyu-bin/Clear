import SwiftUI

/// How the Smart Cleanup summary groups candidates.
enum JunkGroup: String, CaseIterable, Identifiable {
    case userCache, browserCache, xcode, developer, aiTools, logs, screenshots, downloads, mail, leftovers, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCache: "사용자 캐시"
        case .browserCache: "브라우저 캐시"
        case .xcode: "Xcode 파일"
        case .developer: "개발 도구 캐시"
        case .aiTools: "AI 도구 캐시"
        case .logs: "로그 파일"
        case .screenshots: "스크린샷·화면 기록"
        case .downloads: "다운로드의 큰 파일"
        case .mail: "메일 첨부파일"
        case .leftovers: "삭제된 앱 잔여·깨진 항목"
        case .other: "임시 파일·기타"
        }
    }

    var symbol: String {
        switch self {
        case .userCache: "square.stack.3d.up"
        case .browserCache: "safari"
        case .xcode: "hammer"
        case .developer: "cube"
        case .aiTools: "sparkles"
        case .logs: "doc.text"
        case .screenshots: "camera.viewfinder"
        case .downloads: "arrow.down.circle"
        case .mail: "paperclip"
        case .leftovers: "questionmark.app.dashed"
        case .other: "clock.arrow.circlepath"
        }
    }

    var color: Color {
        let index = JunkGroup.allCases.firstIndex(of: self) ?? 0
        return ClearColor.chart[index % ClearColor.chart.count]
    }

    static func of(_ c: CleanupCandidate) -> JunkGroup {
        switch c.category {
        case .appCache, .systemCache, .hiddenCache: .userCache
        case .browserCache: .browserCache
        case .xcode, .simulator, .swiftPackages: .xcode
        case .node, .expo, .gradle, .android, .homebrew, .docker: .developer
        case .aiCache, .aiModels: .aiTools
        case .logs, .aiLogs: .logs
        case .screenshots: .screenshots
        case .downloads: .downloads
        case .mailAttachments: .mail
        case .orphanedAppData, .brokenLoginItem, .softwareUpdates: .leftovers
        default: .other
        }
    }
}
