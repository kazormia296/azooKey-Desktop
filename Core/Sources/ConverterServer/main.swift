import Core
import Darwin
import Dispatch
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

private enum ConverterServerXPC {
    static let machServiceName = "com.miyakey.grimodex.inputmethod.ConverterServer"
}

@objc private protocol ConverterServerXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

final class ConverterServer: NSObject, ConverterServerXPCProtocol, @unchecked Sendable {
    private var sessions: [String: ConverterSession] = [:]
    let grimodexRuntime: GrimodexMacRuntime

    init(grimodexRuntime: GrimodexMacRuntime = .processGlobal()) {
        self.grimodexRuntime = grimodexRuntime
        super.init()
    }

    func openSession(with reply: @escaping @Sendable (String) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let sessionID = UUID().uuidString
                let session = ConverterSession(manager: Self.makeSegmentsManager())
                session.refreshGrimodexRevision(
                    snapshot: self.grimodexRuntime.snapshotManager.latest()
                )
                self.sessions[sessionID] = session
                reply(sessionID)
            }
        }
    }

    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let removed = self.sessions.removeValue(forKey: sessionID)
                removed?.manager.deactivate()
                reply(removed != nil)
            }
        }
    }

    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) {
        reply("ConverterServer: \(message)")
    }

    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void) {
        Task { @MainActor in
            do {
                let command = try ConverterServerCodec.decodeCommand(from: data)
                let response = try await self.handle(command)
                reply(try ConverterServerCodec.encode(response), nil)
            } catch {
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    @MainActor
    private func handle(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
        switch command {
        case .shutdown:
            Self.scheduleShutdown()
            return ConverterServerResponse(snapshot: .empty)
        case .session(let sessionID, let command):
            return try await handle(command, sessionID: sessionID)
        }
    }

    @MainActor
    private func handle(_ command: ConverterSessionCommand, sessionID: String) async throws -> ConverterServerResponse {
        let session = try getSession(sessionID)
        switch command {
        case .lifecycle(let command):
            return handle(command, session: session)
        case .settings(let command):
            return try handle(command, session: session)
        case .updateConfig(let config):
            session.config = config
            return makeResponse(for: session, inputState: .none)
        case .updateClientContext(let context):
            session.updateGrimodexClientContext(
                context,
                snapshot: grimodexRuntime.snapshotManager.latest()
            )
            return makeResponse(for: session, inputState: .none)
        case .handleKeyEvent(let request):
            return try handleKeyEvent(sessionID: sessionID, request: request)
        case .composition(let command):
            return handle(command, session: session)
        case .candidate(let command):
            return handle(command, session: session)
        case .replaceSuggestion(let command):
            return try await handle(command, session: session)
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterSessionLifecycleCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .activate:
            session.refreshGrimodexRevision(
                snapshot: grimodexRuntime.snapshotManager.latest()
            )
            session.manager.activate()
            return makeResponse(for: session, inputState: .none)
        case .deactivate:
            session.manager.deactivate()
            session.endGrimodexComposition(
                snapshot: grimodexRuntime.snapshotManager.latest()
            )
            return makeResponse(for: session, inputState: .none)
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterSettingsCommand,
        session: ConverterSession
    ) throws -> ConverterServerResponse {
        switch command {
        case .list(let capabilities):
            return makeResponse(
                for: session,
                inputState: .none,
                settings: Self.makeSettingDescriptors(capabilities: capabilities)
            )
        case .update(let key, let value):
            try Self.updateSetting(key: key, value: value)
            session.refreshGrimodexRevision(
                snapshot: grimodexRuntime.snapshotManager.latest()
            )
            return makeResponse(for: session, inputState: .none)
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterCompositionCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        if session.isGrimodexSecureInput {
            session.manager.stopComposition()
            return makeResponse(
                for: session,
                inputState: .none,
                handled: false,
                responseInputState: .none
            )
        }
        switch command {
        case .snapshot(let inputState):
            return makeResponse(for: session, inputState: inputState.inputState)
        case .stopComposition:
            session.manager.stopComposition()
            session.endGrimodexComposition(
                snapshot: grimodexRuntime.snapshotManager.latest()
            )
            return makeResponse(for: session, inputState: .none)
        case .forgetMemory:
            session.manager.forgetMemory()
            return makeResponse(for: session, inputState: .none)
        case .commit(let inputState):
            let text = session.manager.commitMarkedText(inputState: inputState.inputState)
            session.endGrimodexComposition(
                snapshot: grimodexRuntime.snapshotManager.latest()
            )
            let effects: [ConverterClientEffect] = text.isEmpty ? [] : [.insertText(text)]
            return makeResponse(for: session, inputState: .none, effects: effects, responseInputState: ConverterInputState.none)
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterCandidateCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        if session.isGrimodexSecureInput {
            return makeResponse(
                for: session,
                inputState: .none,
                handled: false,
                responseInputState: .none
            )
        }
        switch command {
        case .selectCandidate(let index):
            session.manager.requestSelectingRow(index)
            return makeResponse(for: session, inputState: .selecting)
        case .submitSelectedCandidate(let context):
            session.setContext(context)
            var effects: [ConverterClientEffect] = []
            submitSelectedCandidate(
                manager: session.manager,
                leftSideContext: session.conversionLeftSideContext(),
                effects: &effects
            )
            if session.manager.isEmpty {
                session.endGrimodexComposition(
                    snapshot: grimodexRuntime.snapshotManager.latest()
                )
            }
            let nextInputState: InputState = session.manager.isEmpty ? .none : .previewing
            return makeResponse(
                for: session,
                inputState: nextInputState,
                effects: effects,
                responseInputState: ConverterInputState(nextInputState)
            )
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterReplaceSuggestionCommand,
        session: ConverterSession
    ) async throws -> ConverterServerResponse {
        if session.isGrimodexSecureInput {
            session.clearReplaceSuggestions()
            return makeResponse(
                for: session,
                inputState: .none,
                handled: false,
                responseInputState: .none
            )
        }
        switch command {
        case .request(let context):
            session.setContext(context)
            let compositionEpoch = session.compositionEpoch
            try await requestReplaceSuggestion(
                session: session,
                compositionEpoch: compositionEpoch
            )
            guard session.compositionEpoch == compositionEpoch else {
                return ConverterServerResponse(
                    handled: false,
                    inputState: .none,
                    snapshot: .empty
                )
            }
            return makeResponse(for: session, inputState: .replaceSuggestion, responseInputState: .replaceSuggestion)
        case .selectReplaceSuggestionCandidate(let index):
            session.selectReplaceSuggestion(at: index)
            return makeResponse(for: session, inputState: .replaceSuggestion, responseInputState: .replaceSuggestion)
        case .submitSelectedReplaceSuggestion:
            var effects: [ConverterClientEffect] = []
            let didSubmit = submitSelectedReplaceSuggestion(session: session, effects: &effects)
            if didSubmit {
                session.endGrimodexComposition(
                    snapshot: grimodexRuntime.snapshotManager.latest()
                )
            }
            let nextInputState: InputState = didSubmit ? .none : .replaceSuggestion
            return makeResponse(
                for: session,
                inputState: nextInputState,
                effects: effects,
                responseInputState: ConverterInputState(nextInputState)
            )
        }
    }

    private static func scheduleShutdown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(EXIT_SUCCESS)
        }
    }

    @MainActor
    func getSession(_ sessionID: String) throws -> ConverterSession {
        guard let session = sessions[sessionID] else {
            throw ConverterServerError.unknownSession(sessionID)
        }
        return session
    }

}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let server = ConverterServer()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
        connection.exportedObject = server
        connection.resume()
        return true
    }
}

if ProcessInfo.processInfo.environment["GRIMODEX_VALIDATE_APP_GROUP"] == "1" {
    if AppGroup.containerURL() == nil {
        NSLog("Configured Grimodex app group is unavailable")
        exit(EXIT_FAILURE)
    }
    exit(EXIT_SUCCESS)
}

private let grimodexRuntime = GrimodexMacRuntime.processGlobal()
private let isGrimodexProcessE2E = GrimodexMacRuntime.isProcessE2E()

private func validateGrimodexProcessE2ESnapshot() -> Bool {
    guard let expectedProjectID = ProcessInfo.processInfo.environment[
        "GRIMODEX_PROCESS_E2E_EXPECT_PROJECT_ID"
    ] else {
        return true
    }
    let snapshot = grimodexRuntime.snapshotManager.latest()
    guard snapshot.diagnostic == .loaded,
          let payload = snapshot.payload,
          payload.projectID == expectedProjectID,
          payload.dictionaryEntries.count == 1,
          payload.dictionaryEntries[0].ruby == "リュウセイコウ",
          payload.dictionaryEntries[0].word == "龍星港",
          payload.conditions.topic == "宇宙港の物語",
          payload.conditions.style == nil,
          payload.conditions.preference == nil else {
        return false
    }
    return true
}

private func retryGrimodexRuntimeStartup() {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
        do {
            try grimodexRuntime.start()
            NSLog("Recovered Grimodex macOS integration after startup failure")
        } catch {
            NSLog("Grimodex macOS integration retry failed: \(error)")
            retryGrimodexRuntimeStartup()
        }
    }
}

do {
    try grimodexRuntime.start()
} catch {
    NSLog("Failed to start Grimodex macOS integration: \(error)")
    if isGrimodexProcessE2E {
        exit(EXIT_FAILURE)
    }
    retryGrimodexRuntimeStartup()
}

if isGrimodexProcessE2E {
    if !validateGrimodexProcessE2ESnapshot() {
        NSLog("Grimodex process E2E snapshot validation failed")
        exit(EXIT_FAILURE)
    }
    dispatchMain()
} else {
    let listener = NSXPCListener(machServiceName: ConverterServerXPC.machServiceName)
    let delegate = ServiceDelegate()
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime((listener, delegate)) {
        RunLoop.current.run()
    }
}
