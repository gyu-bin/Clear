import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, smartCleanup, diskExplorer, largeFiles, applications, startupItems, duplicates, developer, aiTools, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "홈"
        case .smartCleanup: "스마트 청소"
        case .diskExplorer: "디스크 분석"
        case .largeFiles: "대용량 파일"
        case .applications: "앱 관리"
        case .startupItems: "시작 항목"
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
        case .largeFiles: "큰 파일·오래 안 쓴 파일"
        case .applications: "앱과 관련 파일 제거"
        case .startupItems: "로그인·부팅 시 실행되는 항목"
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
        case .largeFiles: "doc.text.magnifyingglass"
        case .applications: "square.stack.3d.down.right"
        case .startupItems: "power"
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
        case .largeFiles: "4"
        case .applications: "5"
        case .startupItems: "6"
        case .duplicates: "7"
        case .developer: "8"
        case .aiTools: "9"
        case .history: nil
        case .settings: nil
        }
    }

    static let primary: [SidebarItem] = [.overview, .smartCleanup, .diskExplorer, .largeFiles, .applications, .startupItems, .duplicates]
    static let tools: [SidebarItem] = [.developer, .aiTools]
    static let other: [SidebarItem] = [.history, .settings]
}
