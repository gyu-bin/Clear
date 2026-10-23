import SwiftUI

/// Injects `AppModel` through a concrete environment key.
///
/// SwiftUI's `environment(_ object:)` / `@Environment(Type.self)` resolve a
/// *generic* key path at runtime; on this toolchain that intermittently crashed
/// at launch inside the Swift runtime (stack exhausted in
/// `SubstGenericParametersFromMetadata::buildEnvironmentPath`). A plain key avoids
/// generic key-path instantiation entirely. Observation still works because
/// `@Observable` tracks property reads, not how the object reached the view.
private struct AppModelKey: EnvironmentKey {
    static let defaultValue: AppModel? = nil
}

extension EnvironmentValues {
    /// Writable storage (written with `.appModel(_:)`). Optional so that SwiftUI can
    /// read it before the first write.
    var appModelStorage: AppModel? {
        get { self[AppModelKey.self] }
        set { self[AppModelKey.self] = newValue }
    }

    /// Read-only accessor for views: `@Environment(\.appModel)`.
    var appModel: AppModel {
        guard let model = self[AppModelKey.self] else { preconditionFailure("AppModel was not injected into the environment") }
        return model
    }
}

extension View {
    func appModel(_ model: AppModel) -> some View { environment(\.appModelStorage, model) }
}
