import Foundation

/// Which part of the app a cleanup candidate belongs to.
enum CleanupDomain: String, Codable, Sendable, CaseIterable {
    case general, developer, aiTools, applications, duplicates, projects

    var title: String {
        switch self {
        case .general: "일반 청소"
        case .developer: "개발자 도구"
        case .aiTools: "AI 도구"
        case .applications: "앱 관리"
        case .duplicates: "중복 파일"
        case .projects: "개발 프로젝트"
        }
    }
}

enum CleanupCategory: String, Codable, Sendable, CaseIterable {
    case appCache
    case systemCache
    case logs
    case temporary
    case savedState
    case downloads
    case xcode
    case simulator
    case swiftPackages
    case node
    case expo
    case gradle
    case android
    case homebrew
    case docker
    case projectBuild
    case projectDependencies
    case aiCache
    case aiLogs
    case aiModels
    case appBundle
    case appLeftover
    case duplicate
    case similarPhoto
    case trash

    var title: String {
        switch self {
        case .appCache: "앱 캐시"
        case .systemCache: "시스템 구성요소 캐시"
        case .logs: "로그"
        case .temporary: "임시 파일"
        case .savedState: "창 복원 데이터"
        case .downloads: "다운로드 폴더"
        case .xcode: "Xcode"
        case .simulator: "시뮬레이터"
        case .swiftPackages: "Swift Package"
        case .node: "Node.js 패키지 매니저"
        case .expo: "Expo / React Native"
        case .gradle: "Gradle"
        case .android: "Android"
        case .homebrew: "Homebrew"
        case .docker: "Docker"
        case .projectBuild: "빌드 산출물"
        case .projectDependencies: "프로젝트 의존성"
        case .aiCache: "AI 도구 캐시"
        case .aiLogs: "AI 도구 로그"
        case .aiModels: "로컬 모델"
        case .appBundle: "앱 번들"
        case .appLeftover: "앱 관련 파일"
        case .duplicate: "중복 파일"
        case .similarPhoto: "비슷한 사진"
        case .trash: "휴지통"
        }
    }

    var symbol: String {
        switch self {
        case .appCache: "square.stack.3d.up"
        case .systemCache: "gearshape.2"
        case .logs: "doc.text"
        case .temporary: "clock.arrow.circlepath"
        case .savedState: "macwindow.on.rectangle"
        case .downloads: "arrow.down.circle"
        case .xcode: "hammer"
        case .simulator: "iphone"
        case .swiftPackages: "shippingbox"
        case .node: "cube"
        case .expo: "atom"
        case .gradle: "building.columns"
        case .android: "apps.iphone"
        case .homebrew: "mug"
        case .docker: "server.rack"
        case .projectBuild: "hammer.circle"
        case .projectDependencies: "cube.box"
        case .aiCache: "sparkles"
        case .aiLogs: "text.alignleft"
        case .aiModels: "brain"
        case .appBundle: "app"
        case .appLeftover: "folder.badge.questionmark"
        case .duplicate: "doc.on.doc"
        case .similarPhoto: "photo.on.rectangle"
        case .trash: "trash"
        }
    }

    var domain: CleanupDomain {
        switch self {
        case .appCache, .systemCache, .logs, .temporary, .savedState, .downloads, .trash: .general
        case .xcode, .simulator, .swiftPackages, .node, .expo, .gradle, .android, .homebrew, .docker: .developer
        case .projectBuild, .projectDependencies: .projects
        case .aiCache, .aiLogs, .aiModels: .aiTools
        case .appBundle, .appLeftover: .applications
        case .duplicate, .similarPhoto: .duplicates
        }
    }
}
