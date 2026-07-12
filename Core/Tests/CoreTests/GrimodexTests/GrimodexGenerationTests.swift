@testable import Core
import Testing

@Test func grimodexSecureInputRevokesCompositionImmediately() {
    var pin = GrimodexCompositionGenerationPin()
    let active = grimodexRevision(generation: 3, projectID: "project-a")
    _ = pin.beginComposition(latest: active)
    #expect(pin.isComposing)

    guard let revoked = pin.revokeImmediately(GrimodexIntegrationRevision(
        generation: 3,
        payload: nil
    )) else {
        Issue.record("Expected secure input to revoke the active composition")
        return
    }
    #expect(!pin.isComposing)
    #expect(pin.pinned == nil)
    #expect(pin.pending == nil)
    #expect(pin.applied == revoked)
    #expect(revoked.payload == nil)
    #expect(!revoked.allowsLearning)
    #expect(revoked.secureInput)
}

@Test func grimodexCompositionPinsGenerationAndSwitchesAtTheEndBoundary() {
    var pin = GrimodexCompositionGenerationPin()
    let generation1 = grimodexRevision(generation: 1, projectID: "project-a")
    let generation2 = grimodexRevision(generation: 2, projectID: "project-b")

    #expect(pin.beginComposition(latest: generation1) == generation1)
    #expect(pin.pinned == generation1)
    #expect(pin.observe(generation2) == nil)
    #expect(pin.pinned == generation1)
    #expect(pin.pending == generation2)
    #expect(pin.applied == generation1)

    #expect(pin.endComposition(latest: generation2) == generation2)
    #expect(!pin.isComposing)
    #expect(pin.pinned == nil)
    #expect(pin.pending == nil)
    #expect(pin.applied == generation2)
}

private func grimodexRevision(
    generation: UInt64,
    projectID: String
) -> GrimodexIntegrationRevision {
    GrimodexIntegrationRevision(
        generation: generation,
        payload: GrimodexIntegrationPayload(
            projectID: projectID,
            projectName: projectID,
            dictionaryEntries: [],
            conditions: .empty
        )
    )
}
