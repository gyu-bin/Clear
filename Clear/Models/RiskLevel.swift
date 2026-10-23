import Foundation

/// How much confidence Clear has that removing an item is harmless.
///
/// The level is decided by the classification step and then re-checked by
/// `CleanupValidator` right before anything is touched.
enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// Allowed by policy and passed every runtime check. Eligible for one-click cleanup.
    case safe
    /// Probably fine, but the user should look at it first. Never auto-selected.
    case review
    /// Needs a deliberate, per-item choice (user files, models, app bundles).
    case manual
    /// Must not be removed. Shown for information only.
    case blocked

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .manual: 2
        case .blocked: 3
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }

    var title: String {
        switch self {
        case .safe: "안전"
        case .review: "검토"
        case .manual: "직접 선택"
        case .blocked: "보호됨"
        }
    }

    var explanation: String {
        switch self {
        case .safe: "정책상 허용되고 실행 조건 검증을 통과한 재생성 가능한 데이터"
        case .review: "삭제해도 대부분 문제없지만 확인이 필요한 데이터"
        case .manual: "직접 확인하고 개별적으로 선택해야 하는 데이터"
        case .blocked: "보호 대상이므로 삭제할 수 없는 데이터"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .manual: "hand.raised.fill"
        case .blocked: "lock.fill"
        }
    }

    var isSelectable: Bool { self != .blocked }
}
