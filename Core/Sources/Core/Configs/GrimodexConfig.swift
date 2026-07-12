import Foundation

extension Config {
    /// Controls where project-scoped Grimodex vocabulary may be injected.
    public struct GrimodexScope: CustomCodableConfigItem {
        public typealias Value = GrimodexScopeMode

        public init() {}

        static let `default`: GrimodexScopeMode = .grimodexOnly
        public static let key = "com.miyakey.grimodex.inputmethod.preference.grimodexScope"
    }
}
