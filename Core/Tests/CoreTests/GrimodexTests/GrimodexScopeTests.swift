@testable import Core
import Testing

@Test func grimodexScopeAllowsOnlyTheExactGrimodexBundleIdentifier() {
    let allowed = GrimodexScopePolicy.evaluate(
        mode: .grimodexOnly,
        context: GrimodexClientContext(
            bundleIdentifier: "com.miyakey.grimodex",
            secureInput: false
        )
    )
    #expect(allowed == GrimodexScopeDecision(
        allowsGrimodexIntegration: true,
        allowsLearning: true,
        reason: .allowedGrimodex
    ))

    let unknown = GrimodexScopePolicy.evaluate(
        mode: .grimodexOnly,
        context: GrimodexClientContext(bundleIdentifier: nil, secureInput: false)
    )
    #expect(!unknown.allowsGrimodexIntegration)
    #expect(unknown.allowsLearning)
    #expect(unknown.reason == .unknownProgram)

    for otherBundleIdentifier in [
        "com.apple.TextEdit",
        "COM.MIYAKEY.GRIMODEX",
        " com.miyakey.grimodex ",
        "com.miyakey.grimodex.helper"
    ] {
        let denied = GrimodexScopePolicy.evaluate(
            mode: .grimodexOnly,
            context: GrimodexClientContext(
                bundleIdentifier: otherBundleIdentifier,
                secureInput: false
            )
        )
        #expect(!denied.allowsGrimodexIntegration, "Unexpectedly allowed \(otherBundleIdentifier)")
        #expect(denied.allowsLearning)
        #expect(denied.reason == .otherProgram)
    }
}

@Test func grimodexSecureInputOverridesEveryScope() {
    for mode in GrimodexScopeMode.allCases {
        let decision = GrimodexScopePolicy.evaluate(
            mode: mode,
            context: GrimodexClientContext(
                bundleIdentifier: "com.miyakey.grimodex",
                secureInput: true
            )
        )
        #expect(!decision.allowsGrimodexIntegration)
        #expect(!decision.allowsLearning)
        #expect(decision.reason == .secureInput)
    }
}
