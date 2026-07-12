import Core
import KanaKanjiConverterModuleWithDefaultDictionary

final class ConverterSession: SegmentManagerDelegate {
    static let conversionContextLength = 30
    static let replaceSuggestionContextLength = 100

    let manager: SegmentsManager
    private var context = ConverterTextContext()
    private var grimodexClientContext = GrimodexClientContext(
        bundleIdentifier: nil,
        secureInput: false
    )
    private var grimodexGenerationPin = GrimodexCompositionGenerationPin()
    private(set) var compositionEpoch: UInt64 = 0
    var config = ConverterSessionConfig(
        aiBackendPreference: .off,
        openAIModelName: Config.OpenAiModelName.default,
        openAIEndpoint: Config.OpenAiApiEndpoint.default,
        openAIAPIKey: .init(""),
        includeContextInAITransform: true
    )
    var replaceSuggestions: [Candidate] = []
    var replaceSuggestionSelectionIndex: Int?
    var isGrimodexSecureInput: Bool { grimodexClientContext.secureInput }

    init(manager: SegmentsManager) {
        self.manager = manager
        self.manager.delegate = self
    }

    @MainActor
    func updateGrimodexClientContext(
        _ context: GrimodexClientContext,
        snapshot: GrimodexPublishedSnapshot
    ) {
        guard context.generation > grimodexClientContext.generation
            || context == grimodexClientContext else {
            return
        }
        if grimodexClientContext != context {
            compositionEpoch &+= 1
        }
        grimodexClientContext = context
        let revision = grimodexRevision(snapshot: snapshot)
        if context.secureInput {
            if let revoked = grimodexGenerationPin.revokeImmediately(revision) {
                manager.applyGrimodexRevision(revoked)
            }
            // Apply the learning guard before stopping so a secure-input transition
            // cannot commit the preceding composition into converter memory.
            manager.stopComposition()
            clearReplaceSuggestions()
        } else if let revision = grimodexGenerationPin.observe(revision) {
            manager.applyGrimodexRevision(revision)
        }
    }

    @MainActor
    func beginGrimodexComposition(snapshot: GrimodexPublishedSnapshot) {
        if !grimodexGenerationPin.isComposing {
            compositionEpoch &+= 1
        }
        if let revision = grimodexGenerationPin.beginComposition(
            latest: grimodexRevision(snapshot: snapshot)
        ) {
            manager.applyGrimodexRevision(revision)
        }
    }

    @MainActor
    func endGrimodexComposition(snapshot: GrimodexPublishedSnapshot) {
        let wasComposing = grimodexGenerationPin.isComposing
        if let revision = grimodexGenerationPin.endComposition(
            latest: grimodexRevision(snapshot: snapshot)
        ) {
            manager.applyGrimodexRevision(revision)
        }
        if wasComposing {
            compositionEpoch &+= 1
        }
    }

    @MainActor
    func refreshGrimodexRevision(snapshot: GrimodexPublishedSnapshot) {
        if let revision = grimodexGenerationPin.observe(
            grimodexRevision(snapshot: snapshot)
        ) {
            manager.applyGrimodexRevision(revision)
        }
    }

    private func grimodexRevision(
        snapshot: GrimodexPublishedSnapshot
    ) -> GrimodexIntegrationRevision {
        let decision = GrimodexScopePolicy.evaluate(
            mode: Config.GrimodexScope().value,
            context: grimodexClientContext
        )
        return GrimodexIntegrationRevision(snapshot: snapshot, decision: decision)
    }

    func setContext(_ context: ConverterTextContext) {
        self.context = context
    }

    func getLeftSideContext(maxCount: Int) -> String? {
        guard let leftSideContext = context.leftSideContext else {
            return nil
        }
        return String(leftSideContext.suffix(maxCount))
    }

    func getRightSideContext(maxCount: Int) -> String? {
        guard let rightSideContext = context.rightSideContext else {
            return nil
        }
        return String(rightSideContext.prefix(maxCount))
    }

    func conversionLeftSideContext() -> String? {
        getLeftSideContext(maxCount: Self.conversionContextLength)
    }

    func replaceSuggestionPromptContext() -> String {
        let leftSideContext = getLeftSideContext(maxCount: Self.replaceSuggestionContextLength) ?? ""
        let rightSideContext = getRightSideContext(maxCount: Self.replaceSuggestionContextLength) ?? ""
        guard !leftSideContext.isEmpty || !rightSideContext.isEmpty else {
            return ""
        }
        return [
            leftSideContext.isEmpty ? nil : "Text before: ...\(leftSideContext)",
            rightSideContext.isEmpty ? nil : "Text after: \(rightSideContext)..."
        ]
        .compactMap(\.self)
        .joined(separator: "\n")
    }

    func clearReplaceSuggestions() {
        self.replaceSuggestions = []
        self.replaceSuggestionSelectionIndex = nil
    }

    func selectReplaceSuggestion(at index: Int) {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        replaceSuggestionSelectionIndex = min(max(0, index), replaceSuggestions.count - 1)
    }

    func selectNextReplaceSuggestion() {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        replaceSuggestionSelectionIndex = ((replaceSuggestionSelectionIndex ?? -1) + 1) % replaceSuggestions.count
    }

    func selectPreviousReplaceSuggestion() {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        let current = replaceSuggestionSelectionIndex ?? 0
        replaceSuggestionSelectionIndex = (current - 1 + replaceSuggestions.count) % replaceSuggestions.count
    }

    var selectedReplaceSuggestion: Candidate? {
        guard let replaceSuggestionSelectionIndex,
              replaceSuggestions.indices.contains(replaceSuggestionSelectionIndex) else {
            return nil
        }
        return replaceSuggestions[replaceSuggestionSelectionIndex]
    }
}
