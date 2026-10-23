import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, smartCleanup, diskExplorer, applications, duplicates, developer, aiTools, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "홈"
        case .smartCleanup: "스마트 청소"
        case .diskExplorer: "디스크 분석"
        case .applications: "앱 관리"
        case .duplicates: "중복 파일"
        case .developer: "개발자 도구"
        case .aiTools: "AI 도구"
        case .history: "정리 기록"
        case .settings: "설정"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "저장공간 상태와 정리 추천"
        case .smartCleanup: "캐시·로그·임시 파일 정리"
        case .diskExplorer: "폴더별 사용량 트리맵"
        case .applications: "앱과 관련 파일 제거"
        case .duplicates: "동일 파일·비슷한 사진"
        case .developer: "개발 도구 캐시와 프로젝트"
        case .aiTools: "AI 도구 캐시·로그·모델"
        case .history: "정리 실행 기록"
        case .settings: "앱 설정"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .smartCleanup: "sparkles"
        case .diskExplorer: "square.grid.3x3.square"
        case .applications: "square.stack.3d.down.right"
        case .duplicates: "doc.on.doc"
        case .developer: "hammer"
        case .aiTools: "brain"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .developer: ClearColor.developer
        case .aiTools: ClearColor.ai
        case .duplicates: ClearColor.warning
        default: ClearColor.accent
        }
    }

    var shortcut: KeyEquivalent? {
        switch self {
        case .overview: "1"
        case .smartCleanup: "2"
        case .diskExplorer: "3"
        case .applications: "4"
        case .duplicates: "5"
        case .developer: "6"
        case .aiTools: "7"
        case .history: "8"
        case .settings: nil
        }
    }

    static let primary: [SidebarItem] = [.overview, .smartCleanup, .diskExplorer, .applications, .duplicates]
    static let tools: [SidebarItem] = [.developer, .aiTools]
    static let other: [SidebarItem] = [.history, .settings]
}
