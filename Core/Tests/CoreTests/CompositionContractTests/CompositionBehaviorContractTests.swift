import Core
import Crypto
import Foundation
import Testing

private struct ContractLock: Decodable {
    let contractVersion: String
    let files: [String: String]

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case files
    }
}

private struct ContractScenario: Decodable {
    struct Action: Decodable {
        let type: String
    }

    let contractVersion: String
    let scenarioID: String
    let actions: [Action]
    let statuses: [String]
    let snapshots: [ContractSnapshot]

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case scenarioID = "scenario_id"
        case actions, statuses, snapshots
    }
}

private struct ContractSnapshot: Decodable {
    let revision: UInt64
    let phase: String
}

private let requiredScenarios: Set<String> = [
    "composing-basic", "cursor-editing", "escape-backspace", "partial-commit",
    "secure-input", "segment-editing", "server-failure", "stale-candidate",
    "unicode-caret"
]

private let expectedSemanticActionTypes: Set<String> = [
    "insert_text", "delete_backward", "delete_forward", "move_cursor",
    "move_cursor_to_start", "move_cursor_to_end", "start_conversion",
    "navigate_candidate", "navigate_candidate_page", "resize_segment",
    "commit_selected", "commit_all", "cancel", "select_candidate",
    "transform_active_segment", "forget_candidate", "reconvert",
    "secure_input_changed", "capability_changed", "deactivate",
    "focus_changed", "server_restarted"
]

private let semanticActionMappings: [String: String] = [
    "insert_text": "ClientAction.appendPieceToMarkedText",
    "delete_backward": "ClientAction.removeLastMarkedText",
    "delete_forward": "marked-text range adapter",
    "move_cursor": "marked-text range adapter",
    "move_cursor_to_start": "marked-text range adapter",
    "move_cursor_to_end": "marked-text range adapter",
    "start_conversion": "ClientAction.enterFirstCandidatePreviewMode",
    "navigate_candidate": "ClientAction.selectNextCandidate/selectPrevCandidate",
    "navigate_candidate_page": "candidate presentation adapter",
    "resize_segment": "ClientAction.editSegment",
    "commit_selected": "ClientAction.submitSelectedCandidate",
    "commit_all": "ClientAction.commitMarkedText",
    "cancel": "InputState escape transitions",
    "select_candidate": "ClientAction.selectNumberCandidate",
    "transform_active_segment": "ConverterServer.transformedCandidate",
    "forget_candidate": "ClientAction.forgetMemory/SegmentsManager.forgetMemory",
    "secure_input_changed": "Grimodex composition epoch policy",
    "capability_changed": "InputMethodKit marked-text capability adapter",
    "deactivate": "ConverterServerRequest.deactivate",
    "focus_changed": "InputMethodKit session lifecycle",
    "server_restarted": "ConverterSession generation recovery"
]

private let semanticActionExceptions: [String: String] = [
    "reconvert": "native selected-range Japanese reconversion is not implemented"
]

@Suite("Composition Behavior Contract v1")
struct CompositionBehaviorContractTests {
    @Test func fixtureLockAndScenarioCoverageAreReproducible() throws {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/composition-behavior-v1")
        let lock = try JSONDecoder().decode(
            ContractLock.self,
            from: Data(contentsOf: root.appendingPathComponent("contract-lock.json"))
        )
        #expect(lock.contractVersion == "composition-behavior-v1")

        let mappedActions = Set(semanticActionMappings.keys)
        let exceptedActions = Set(semanticActionExceptions.keys)
        #expect(mappedActions.isDisjoint(with: exceptedActions))
        #expect(mappedActions.union(exceptedActions) == expectedSemanticActionTypes)

        var observed = Set<String>()
        var observedActions = Set<String>()
        for (filename, expectedHash) in lock.files {
            let data = try Data(
                contentsOf: root.appendingPathComponent("scenarios/\(filename)")
            )
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(actualHash == expectedHash)

            let scenario = try JSONDecoder().decode(ContractScenario.self, from: data)
            #expect(scenario.contractVersion == "composition-behavior-v1")
            #expect(scenario.actions.count == scenario.statuses.count)
            #expect(scenario.actions.count == scenario.snapshots.count)
            #expect(scenario.snapshots.map(\.revision) == scenario.snapshots.map(\.revision).sorted())
            for action in scenario.actions {
                #expect(
                    semanticActionMappings[action.type] != nil
                        || semanticActionExceptions[action.type] != nil
                )
                observedActions.insert(action.type)
            }
            observed.insert(scenario.scenarioID)
        }
        #expect(observed == requiredScenarios)
        #expect(observedActions.isDisjoint(with: exceptedActions))
    }

    @Test func sharedConversionAndSegmentActionsReachNativeInputStateTransitions() {
        let event = KeyEventCore(
            modifierFlags: [],
            characters: " ",
            charactersIgnoringModifiers: " ",
            keyCode: 49
        )

        let (previewAction, previewCallback) = InputState.composing.event(
            eventCore: event,
            userAction: .space(prefersFullWidthWhenInput: false),
            inputLanguage: .japanese,
            liveConversionEnabled: false,
            enableDebugWindow: false,
            enableSuggestion: false
        )
        guard case .enterFirstCandidatePreviewMode = previewAction,
              case .transition(.previewing) = previewCallback else {
            Issue.record("segment-editing start_conversion did not enter previewing")
            return
        }

        let (segmentAction, segmentCallback) = InputState.previewing.event(
            eventCore: event,
            userAction: .editSegment(1),
            inputLanguage: .japanese,
            liveConversionEnabled: false,
            enableDebugWindow: false,
            enableSuggestion: false
        )
        guard case .editSegment(1) = segmentAction,
              case .transition(.selecting) = segmentCallback else {
            Issue.record("segment-editing resize_segment did not enter selecting")
            return
        }

        let (cancelAction, cancelCallback) = InputState.previewing.event(
            eventCore: event,
            userAction: .escape,
            inputLanguage: .japanese,
            liveConversionEnabled: false,
            enableDebugWindow: false,
            enableSuggestion: false
        )
        guard case .hideCandidateWindow = cancelAction,
              case .transition(.composing) = cancelCallback else {
            Issue.record("escape-backspace cancel did not return to composing")
            return
        }
    }
}
