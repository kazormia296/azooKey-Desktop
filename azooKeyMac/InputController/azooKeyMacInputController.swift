import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

@objc(azooKeyMacInputController)
class azooKeyMacInputController: IMKInputController, NSMenuItemValidation { // swiftlint:disable:this type_name
    var segmentsManager: SegmentsManager
    let converterServerClient = ConverterServerClient()
    private var currentConverterView: ConverterSessionSnapshot?
    private var lastGrimodexClientContext: GrimodexClientContext?
    private var desiredGrimodexClientContext: GrimodexClientContext?
    private var grimodexClientContextGeneration: UInt64 = 0
    private var isRevokingSecureInput = false
    private var localConversionBlocked = false
    private var activationGeneration: UInt64 = 0
    private var replaceSuggestionRequestGeneration: UInt64 = 0
    private(set) var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem
    var transformSelectedTextMenuItem: NSMenuItem

    private var candidatesWindow: NSWindow
    private var candidatesViewController: CandidatesViewController

    private var predictionWindow: NSWindow
    private var predictionViewController: PredictionCandidatesViewController
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    private var replaceSuggestionWindow: NSWindow
    private var replaceSuggestionsViewController: ReplaceSuggestionsViewController

    var promptInputWindow: PromptInputWindow
    var isPromptWindowVisible: Bool = false

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    // ピン留めプロンプトのキャッシュ（パフォーマンス向上のため）
    private var pinnedPromptsCache: [PromptHistoryItem] = []

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        // Chromium 系アプリの deadlock 回避のため、初期化時に client への
        // 問い合わせを行わない（Chromium issue 503787240）。
        // ウィンドウは直後に orderOut されるため origin はユーザーから不可視であり、
        // 最初の候補表示時に refreshCandidateWindow() で正しい位置に再配置される。
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    /// ピン留めプロンプトのキャッシュを更新
    func reloadPinnedPromptsCache() {
        guard let data = Config.data(forKey: Config.PromptHistory.key),
              let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) else {
            self.pinnedPromptsCache = []
            return
        }
        self.pinnedPromptsCache = history.filter { $0.isPinned }
    }

    // MARK: - カスタムプロンプトショートカット検出
    private func checkCustomPromptShortcut(event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }

        let key = characters.lowercased()
        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        // 修飾キーがない場合は早期リターン（通常の入力）
        if eventModifiers.isEmpty {
            return nil
        }

        // キャッシュからショートカット付きのピン留めプロンプトを検索
        if let matched = self.pinnedPromptsCache.first(where: { item in
            guard let itemShortcut = item.shortcut else {
                return false
            }
            return itemShortcut.key == key && itemShortcut.modifiers == eventModifiers
        }) {
            return matched.prompt
        }

        return nil
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let applicationDirectoryURL = AppGroup.memoryDirectoryURL()
        let containerURL = AppGroup.containerURL()
        self.segmentsManager = SegmentsManager(
            kanaKanjiConverter: (NSApplication.shared.delegate as? AppDelegate)!.kanaKanjiConverter,
            applicationDirectoryURL: applicationDirectoryURL,
            containerURL: containerURL
        )

        self.appMenu = NSMenu(title: "azooKey")
        self.liveConversionToggleMenuItem = NSMenuItem()
        self.transformSelectedTextMenuItem = NSMenuItem()

        let candidatesViewController = CandidatesViewController()
        let predictionViewController = PredictionCandidatesViewController()
        let replaceSuggestionsViewController = ReplaceSuggestionsViewController()

        self.candidatesViewController = candidatesViewController
        self.predictionViewController = predictionViewController
        self.replaceSuggestionsViewController = replaceSuggestionsViewController

        self.candidatesWindow = Self.makeCandidateWindow(contentViewController: candidatesViewController)
        self.predictionWindow = Self.makeCandidateWindow(contentViewController: predictionViewController)
        self.replaceSuggestionWindow = Self.makeCandidateWindow(contentViewController: replaceSuggestionsViewController)

        // PromptInputWindowの初期化
        self.promptInputWindow = PromptInputWindow()

        super.init(server: server, delegate: delegate, client: inputClient)

        // デリゲートの設定を super.init の後に移動
        self.candidatesViewController.delegate = self
        self.replaceSuggestionsViewController.delegate = self
        self.segmentsManager.delegate = self
        self.converterServerClient.onLog = { [weak self] message in
            self?.segmentsManager.appendDebugMessage(message)
        }
        self.setupMenu()
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // アプリケーションサポートのディレクトリを準備しておく
        self.prepareApplicationSupportDirectory()
        // Register custom input table (if available) for `.tableName` usage
        CustomInputTableStore.registerIfExists()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateTransformSelectedTextMenuItemEnabledState()
        // ピン留めプロンプトのキャッシュを更新
        self.reloadPinnedPromptsCache()
        self.segmentsManager.activate()
        let grimodexClientContext = (sender as? IMKTextInput).map {
            self.makeGrimodexClientContext(client: $0)
        } ?? GrimodexClientContext(bundleIdentifier: nil, secureInput: IsSecureEventInputEnabled())
        if grimodexClientContext.secureInput,
           let client = sender as? IMKTextInput {
            self.revokeCompositionForSecureInput(client: client)
        }
        self.activationGeneration &+= 1
        if grimodexClientContext.secureInput {
            self.lastGrimodexClientContext = grimodexClientContext
            self.converterServerClient.sendIfSessionOpen(
                { _ in .updateClientContext(grimodexClientContext) },
                completion: { _ in }
            )
        } else if self.converterServerClient.openSessionSync() != nil,
           self.converterServerClient.sendIfSessionOpenSync({ _ in
               .updateClientContext(grimodexClientContext)
           }) != nil {
            self.lastGrimodexClientContext = grimodexClientContext
            self.restoreLocalConversionAfterSecureInput()
            _ = self.syncConverterServerSessionConfigSync()
            if let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
                .lifecycle(.activate)
            }) {
                self.currentConverterView = response.snapshot
            }
        } else if let client = sender as? IMKTextInput {
            self.clearClientComposition(client: client)
        }

        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        }
        // Chromium 系アプリで JS コンパイル中に activate された場合、
        // client.attributes(forCharacterIndex:) の同期呼び出しが deadlock を
        // 引き起こすため呼び出さない（Chromium issue 503787240）。
        // refreshCandidateWindow / refreshPredictionWindow は composing/selecting 状態で
        // client.attributes(...) を呼ぶ経路があるため、activate 中は使わずウィンドウを
        // 明示的に閉じる。
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
        self.hidePredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        self.activationGeneration &+= 1
        self.segmentsManager.deactivate()
        self.converterServerClient.sendIfSessionOpen({ _ in .lifecycle(.deactivate) }, completion: { _ in })
        self.currentConverterView = nil
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.replaceSuggestionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func inputControllerWillClose() {
        self.activationGeneration &+= 1
        self.converterServerClient.closeSession()
        self.lastGrimodexClientContext = nil
        self.desiredGrimodexClientContext = nil
        super.inputControllerWillClose()
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        if let client = (sender as? IMKTextInput) ?? self.client(),
           self.shouldBlockForGrimodexContext(client: client) {
            return
        }
        // Unicode入力モードの場合は状態だけリセットして終了
        // マウスクリック等でOSがMarkedTextを確定した場合、IME側からは消せないため
        if case .unicodeInput = self.inputState {
            self.inputState = .none
            return
        }
        if self.currentConverterView?.isEmpty == false,
           let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
            .composition(.commit(inputState: ConverterInputState(self.inputState)))
           }) {
            self.currentConverterView = response.snapshot
            if let client = sender as? IMKTextInput {
                for effect in response.effects {
                    self.apply(effect, client: client)
                }
            }
        }
        self.segmentsManager.stopComposition()
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }

        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            let englishMode = value == "com.apple.inputmethod.Roman"

            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバーやshortcut経由の切り替えに対応する。
                // composing中でも英数キーMarkedTextを保ったまま英語入力へ移る。
                if self.inputLanguage == .japanese {
                    self.inputLanguage = .english
                    self.segmentsManager.stopJapaneseInput()
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                }
            }
        }
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else {
            return false
        }
        guard event.type == .keyDown else {
            return false
        }

        if self.shouldBlockForGrimodexContext(client: client) {
            return false
        }

        // カスタムプロンプトショートカットのチェック
        if let matchedPrompt = checkCustomPromptShortcut(event: event) {
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            if aiBackendEnabled && !self.isPromptWindowVisible {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: matchedPrompt) {
                        return true
                    }
                }
            }
            // ショートカットがマッチした場合はイベントを消費して他のハンドラに渡さない
            return true
        }

        let userAction = UserAction.getUserAction(eventCore: event.keyEventCore, inputLanguage: inputLanguage)

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "english") {
                        return true
                    }
                }
            }
        }

        // かなキー（keyCode 104）の処理（ダブルタップで日本語への翻訳）
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "japanese") {
                        return true
                    }
                }
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            let selectedRange = client.selectedRange()
            self.segmentsManager.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                guard aiBackendEnabled else {
                    self.segmentsManager.appendDebugMessage("Suggest action ignored: AI backend is off")
                    return false
                }
                self.segmentsManager.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                self.showPromptInputWindow()
                return true
            } else {
                self.segmentsManager.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        if let handled = self.handleKeyEventWithConverterServer(
            event: event.keyEventCore,
            client: client,
            enableSuggestion: aiBackendEnabled,
            optionDirectInputText: event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option))
        ) {
            return handled
        }

        return false
    }

    @MainActor
    private func handleKeyEventWithConverterServer(
        event: KeyEventCore,
        client: IMKTextInput,
        enableSuggestion: Bool,
        optionDirectInputText: String? = nil
    ) -> Bool? {
        guard self.converterServerClient.canSendOrReconnect else {
            return nil
        }
        if !self.segmentsManager.isEmpty {
            self.segmentsManager.stopComposition()
        }

        let request = ConverterKeyEventRequest(
            event: event,
            inputState: ConverterInputState(self.inputState),
            inputLanguage: self.inputLanguage,
            inputStyle: ConverterInputStyle(self.inputStyle),
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: enableSuggestion,
            enablePredictiveTyping: Config.DebugPredictiveTyping().value,
            enableTypoCorrection: Config.DebugTypoCorrection().value,
            enableOptionDirectFullWidthInput: Config.OptionDirectFullWidthInput().value,
            typeBackSlash: Config.TypeBackSlash().value,
            optionDirectInputText: optionDirectInputText,
            context: self.currentConverterTextContext()
        )
        guard let response = self.converterServerClient.sendSync({ _ in
            .handleKeyEvent(request)
        }) else {
            return nil
        }

        if response.effects.contains(.fallthroughToApplication), !response.handled {
            return false
        }

        if let inputLanguage = response.inputLanguage {
            self.inputLanguage = inputLanguage
        }
        self.inputState = response.inputState.inputState
        self.currentConverterView = response.snapshot
        for effect in response.effects {
            self.apply(effect, client: client)
        }
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
        return response.handled
    }

    @MainActor
    func requestPredictiveSuggestionWithConverterServer(client: IMKTextInput) -> Bool {
        guard !self.shouldBlockForGrimodexContext(client: client) else {
            return false
        }
        return self.handleKeyEventWithConverterServer(
            event: KeyEventCore(
                modifierFlags: [.control],
                characters: "s",
                charactersIgnoringModifiers: "s",
                keyCode: 1
            ),
            client: client,
            enableSuggestion: Config.AIBackendPreference().value != .off
        ) ?? false
    }

    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    private func apply(_ effect: ConverterClientEffect, client: IMKTextInput) {
        guard !self.shouldBlockForGrimodexContext(client: client) else {
            return
        }
        switch effect {
        case .insertText(let text):
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .switchInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .requestPredictiveSuggestion:
            self.requestReplaceSuggestion()
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.selectReplaceSuggestionCandidate(offset: 1)
        case .selectPreviousReplaceSuggestionCandidate:
            self.selectReplaceSuggestionCandidate(offset: -1)
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate()
        case .hideReplaceSuggestionWindow:
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
        case .showPromptInputWindow:
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        case .fallthroughToApplication:
            break
        }
    }

    private var inputStyle: InputStyle {
        switch Config.InputStyle().value {
        case .default:
            .mapped(id: .defaultRomanToKana)
        case .defaultAZIK:
            .mapped(id: .defaultAZIK)
        case .defaultKanaUS:
            .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS:
            .mapped(id: .defaultKanaJIS)
        case .custom:
            if CustomInputTableStore.exists() {
                .mapped(id: .tableName(CustomInputTableStore.tableName))
            } else {
                .mapped(id: .defaultRomanToKana)
            }
        }
    }

    private var converterServerSessionConfig: ConverterSessionConfig {
        ConverterSessionConfig(
            aiBackendPreference: Config.AIBackendPreference().value,
            openAIModelName: Config.OpenAiModelName().value,
            openAIEndpoint: Config.OpenAiApiEndpoint().value,
            openAIAPIKey: .init(Config.OpenAiApiKey().value),
            includeContextInAITransform: Config.IncludeContextInAITransform().value
        )
    }

    @MainActor
    private func makeGrimodexClientContext(
        client: IMKTextInput
    ) -> GrimodexClientContext {
        let bundleIdentifier = client.bundleIdentifier()
        let secureInput = IsSecureEventInputEnabled()
        if let desiredGrimodexClientContext,
           desiredGrimodexClientContext.bundleIdentifier == bundleIdentifier,
           desiredGrimodexClientContext.secureInput == secureInput {
            return desiredGrimodexClientContext
        }
        grimodexClientContextGeneration &+= 1
        let context = GrimodexClientContext(
            bundleIdentifier: bundleIdentifier,
            secureInput: secureInput,
            generation: grimodexClientContextGeneration
        )
        desiredGrimodexClientContext = context
        return context
    }

    @MainActor
    @discardableResult
    private func syncGrimodexClientContext(
        _ context: GrimodexClientContext
    ) -> Bool {
        if lastGrimodexClientContext == context,
           converterServerClient.hasOpenSession {
            return true
        }
        guard converterServerClient.canSendOrReconnect else {
            return false
        }
        let response = converterServerClient.sendSync({ _ in
            .updateClientContext(context)
        })
        if response != nil {
            lastGrimodexClientContext = context
        }
        return response != nil
    }

    @MainActor
    @discardableResult
    func shouldBlockForGrimodexContext(client: IMKTextInput) -> Bool {
        let context = makeGrimodexClientContext(client: client)
        if context.secureInput {
            revokeCompositionForSecureInput(client: client)
            if lastGrimodexClientContext != context {
                // Secure input must never wait for XPC. An existing session is
                // revoked best-effort; a later nonsecure event synchronizes
                // before any converter command is allowed.
                lastGrimodexClientContext = context
                converterServerClient.sendIfSessionOpen(
                    { _ in .updateClientContext(context) },
                    completion: { _ in }
                )
            }
            return true
        }

        guard syncGrimodexClientContext(context) else {
            localConversionBlocked = true
            segmentsManager.applyGrimodexRevision(
                GrimodexIntegrationRevision(
                    generation: 0,
                    payload: nil,
                    allowsLearning: false,
                    secureInput: false
                )
            )
            clearClientComposition(client: client)
            return true
        }
        restoreLocalConversionAfterSecureInput()
        return false
    }

    @MainActor
    private func revokeCompositionForSecureInput(client: IMKTextInput) {
        guard !isRevokingSecureInput else {
            return
        }
        isRevokingSecureInput = true
        defer { isRevokingSecureInput = false }
        localConversionBlocked = true
        let revoked = GrimodexIntegrationRevision(
            generation: 0,
            payload: nil,
            allowsLearning: false,
            secureInput: true
        )
        segmentsManager.applyGrimodexRevision(revoked)
        clearClientComposition(client: client)
    }

    @MainActor
    private func clearClientComposition(client: IMKTextInput) {
        replaceSuggestionRequestGeneration &+= 1
        segmentsManager.stopComposition()
        currentConverterView = nil
        inputState = .none
        predictionHideWorkItem?.cancel()
        predictionHideWorkItem = nil
        lastPredictionCandidates = []
        lastPredictionUpdateTime = 0

        candidatesViewController.updateCandidatePresentations(
            [],
            selectionIndex: nil,
            cursorLocation: .zero
        )
        candidatesWindow.setIsVisible(false)
        candidatesWindow.orderOut(nil)
        predictionWindow.setIsVisible(false)
        predictionWindow.orderOut(nil)
        replaceSuggestionsViewController.updateCandidatePresentations(
            [],
            selectionIndex: nil,
            cursorLocation: .zero
        )
        replaceSuggestionWindow.setIsVisible(false)
        replaceSuggestionWindow.orderOut(nil)
        client.setMarkedText(
            NSAttributedString(string: ""),
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @MainActor
    private func restoreLocalConversionAfterSecureInput() {
        guard localConversionBlocked else {
            return
        }
        segmentsManager.applyGrimodexRevision(
            GrimodexIntegrationRevision(
                generation: 0,
                payload: nil,
                allowsLearning: true,
                secureInput: false
            )
        )
        localConversionBlocked = false
    }

    @discardableResult
    private func syncConverterServerSessionConfigSync() -> Bool {
        let config = self.converterServerSessionConfig
        return self.converterServerClient.sendIfSessionOpenSync({ _ in
            .updateConfig(config)
        }) != nil
    }

    private func refreshConverterViewForCurrentInputState() {
        guard let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
            .composition(.snapshot(inputState: ConverterInputState(self.inputState)))
        }) else {
            return
        }
        self.currentConverterView = response.snapshot
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        self.inputLanguage = language
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("com.miyakey.grimodex.inputmethod.Roman")
            self.segmentsManager.stopJapaneseInput()
        case .japanese:
            client.selectMode("com.miyakey.grimodex.inputmethod.Japanese")
        }
    }

    private func discardConverterServerComposition() {
        self.currentConverterView = nil
        self.converterServerClient.sendIfSessionOpen(
            { _ in .composition(.stopComposition) },
            completion: { _ in }
        )
    }

    func refreshCandidateWindow() {
        if let currentConverterView {
            self.refreshCandidateWindow(currentConverterView.candidateWindow)
            return
        }
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
    }

    private func refreshCandidateWindow(_ candidateWindow: ConverterCandidateWindow) {
        switch candidateWindow {
        case .selecting(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = true
            self.candidatesViewController.updateCandidatePresentations(
                candidates.map(\.candidatePresentation),
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = false
            self.candidatesViewController.updateCandidatePresentations(
                candidates.map(\.candidatePresentation),
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
            self.candidatesViewController.hide()
        }
    }

    @MainActor private func refreshReplaceSuggestionWindow() {
        guard self.inputState == .replaceSuggestion,
              let currentConverterView,
              !currentConverterView.replaceSuggestionCandidates.isEmpty else {
            self.replaceSuggestionsViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
            return
        }
        self.replaceSuggestionsViewController.updateCandidatePresentations(
            currentConverterView.replaceSuggestionCandidates.map(\.candidatePresentation),
            selectionIndex: currentConverterView.replaceSuggestionSelectionIndex,
            cursorLocation: self.getCursorLocation()
        )
        self.replaceSuggestionWindow.setIsVisible(true)
        self.replaceSuggestionWindow.makeKeyAndOrderFront(nil)
    }

    @MainActor private func selectReplaceSuggestionCandidate(offset: Int) {
        guard let view = self.currentConverterView,
              !view.replaceSuggestionCandidates.isEmpty else {
            return
        }
        let count = view.replaceSuggestionCandidates.count
        let current = view.replaceSuggestionSelectionIndex ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + count) % count
        if let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
            .replaceSuggestion(.selectReplaceSuggestionCandidate(index: next))
        }) {
            self.currentConverterView = response.snapshot
            self.inputState = response.inputState.inputState
            self.refreshMarkedText()
            self.refreshReplaceSuggestionWindow()
        }
    }

    @MainActor private func showReplaceSuggestionError(message: String) {
        self.segmentsManager.appendDebugMessage("APIリクエストエラー: \(message)")
        let alert = NSAlert()
        alert.messageText = "変換に失敗しました"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func refreshPredictionWindow() {
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        guard let predictions = self.currentConverterView?.predictionCandidates else {
            self.hidePredictionWindow()
            return
        }
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        let candidates = predictions.map { prediction in
            Candidate(
                text: prediction.displayText,
                value: 0,
                composingCount: .surfaceCount(prediction.displayText.count),
                lastMid: 0,
                data: []
            )
        }

        self.lastPredictionCandidates = candidates.map(\.text)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: rect.origin
        )

        if Config.LiveConversion().value {
            self.predictionWindow.orderFront(nil)
            return
        }

        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // アンカーである候補ウィンドウの中心が乗っているスクリーンを基準にする。
        // predictionWindow.screen / candidatesWindow.screen はマルチディスプレイ遷移直後に
        // 古いディスプレイを返すことがあるため、frame の中心点で能動的に判定する。
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    private func showCachedPredictionWindow() {
        let candidates = self.lastPredictionCandidates.map { text in
            Candidate(
                text: text,
                value: 0,
                composingCount: .surfaceCount(text.count),
                lastMid: 0,
                data: []
            )
        }
        guard !candidates.isEmpty else {
            return
        }
        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: rect.origin
        )
        self.predictionWindow.orderFront(nil)
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    var retryCount = 0
    let maxRetries = 3

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.segmentsManager.appendDebugMessage(errorMessage)
    }

    func getCursorLocation() -> CGPoint {
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.segmentsManager.appendDebugMessage("カーソル位置取得: \(rect.origin)")
        return rect.origin
    }

    func refreshMarkedText() {
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        let currentMarkedText = self.currentMarkedText()
        for part in currentMarkedText.elements where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            }
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: attributes
                )
            )
        }
        self.client()?.setMarkedText(
            text,
            selectionRange: currentMarkedText.selectionRange.nsRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func currentMarkedText() -> ConverterMarkedText {
        switch self.inputState {
        case .attachDiacritic, .unicodeInput:
            return ConverterMarkedText(self.segmentsManager.getCurrentMarkedText(inputState: self.inputState))
        case .none, .composing, .previewing, .selecting, .replaceSuggestion:
            break
        }
        if let currentConverterView {
            return currentConverterView.markedText
        }
        return ConverterSessionSnapshot.empty.markedText
    }
}

extension azooKeyMacInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            guard let client = self.client(),
                  !self.shouldBlockForGrimodexContext(client: client) else {
                return
            }
            if self.currentConverterView != nil {
                if let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
                    .candidate(.submitSelectedCandidate(context: self.currentConverterTextContext()))
                }) {
                    self.currentConverterView = response.snapshot
                    for effect in response.effects {
                        self.apply(effect, client: client)
                    }
                    self.inputState = response.inputState.inputState
                    self.refreshConverterViewForCurrentInputState()
                    self.refreshMarkedText()
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                    return
                }
            }
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Task { @MainActor in
            guard let client = self.client(),
                  !self.shouldBlockForGrimodexContext(client: client) else {
                return
            }
            if self.currentConverterView != nil,
               let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
                .candidate(.selectCandidate(index: row))
               }) {
                self.currentConverterView = response.snapshot
                self.refreshMarkedText()
                return
            }
        }
    }
}

extension azooKeyMacInputController: SegmentManagerDelegate {
    private func currentConverterTextContext() -> ConverterTextContext {
        guard !IsSecureEventInputEnabled() else {
            return ConverterTextContext()
        }
        return ConverterTextContext(
            leftSideContext: self.getLeftSideContext(),
            rightSideContext: self.getRightSideContext()
        )
    }

    func getLeftSideContext(maxCount: Int = ConverterTextContext.transportCharacterLimit) -> String? {
        guard !IsSecureEventInputEnabled() else {
            return nil
        }
        let endIndex = self.contextRange().location
        let leftRange = NSRange(location: max(endIndex - maxCount, 0), length: min(endIndex, maxCount))
        var actual = NSRange()
        // 同じ行の文字のみコンテキストに含める
        let leftSideContext = self.client().string(from: leftRange, actualRange: &actual)
        self.segmentsManager.appendDebugMessage(
            "\(#function): length=\(leftSideContext?.count ?? 0)"
        )
        return leftSideContext
    }

    func getRightSideContext(maxCount: Int = ConverterTextContext.transportCharacterLimit) -> String? {
        guard !IsSecureEventInputEnabled() else {
            return nil
        }
        let range = self.contextRange()
        let startIndex = range.location + range.length
        let documentLength = self.client().length()
        guard startIndex < documentLength else {
            return nil
        }
        let rightRange = NSRange(location: startIndex, length: min(documentLength - startIndex, maxCount))
        var actual = NSRange()
        let rightSideContext = self.client().string(from: rightRange, actualRange: &actual)
        self.segmentsManager.appendDebugMessage(
            "\(#function): length=\(rightSideContext?.count ?? 0)"
        )
        return rightSideContext
    }

    private func contextRange() -> NSRange {
        let markedRange = self.client().markedRange()
        if markedRange.location != NSNotFound {
            return markedRange
        }
        let selectedRange = self.client().selectedRange()
        if selectedRange.location != NSNotFound {
            return selectedRange
        }
        return NSRange(location: 0, length: 0)
    }
}

extension azooKeyMacInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        guard let client = self.client(),
              !self.shouldBlockForGrimodexContext(client: client) else {
            return
        }
        guard self.currentConverterView?.replaceSuggestionSelectionIndex != row else {
            return
        }
        if let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
            .replaceSuggestion(.selectReplaceSuggestionCandidate(index: row))
        }) {
            self.currentConverterView = response.snapshot
            self.inputState = response.inputState.inputState
            self.refreshMarkedText()
            self.refreshReplaceSuggestionWindow()
        }
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            self.submitSelectedSuggestionCandidate()
        }
    }
}

// Suggest Candidate
extension azooKeyMacInputController {
    // MARK: - Replace Suggestion Request Handling
    @MainActor func requestReplaceSuggestion() {
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 開始")

        guard let client = self.client(),
              !self.shouldBlockForGrimodexContext(client: client) else {
            return
        }

        // リクエスト開始時に前回の候補をクリアし、ウィンドウを非表示にする
        self.replaceSuggestionsViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)

        guard let currentConverterView, !currentConverterView.isEmpty else {
            self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: skipped because converter server composition is empty")
            return
        }
        guard self.syncConverterServerSessionConfigSync() else {
            self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: skipped because session config sync failed")
            return
        }
        self.replaceSuggestionRequestGeneration &+= 1
        let requestGeneration = self.replaceSuggestionRequestGeneration
        let activationGeneration = self.activationGeneration
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.request(context: self.currentConverterTextContext())) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    guard self.activationGeneration == activationGeneration,
                          self.replaceSuggestionRequestGeneration == requestGeneration else {
                        return
                    }
                    guard let response else {
                        self.showReplaceSuggestionError(message: "ConverterServerから候補を取得できませんでした")
                        return
                    }
                    guard self.currentConverterView?.convertTarget == response.snapshot.convertTarget else {
                        self.segmentsManager.appendDebugMessage("候補ウィンドウ更新をスキップ: composition changed")
                        return
                    }
                    self.currentConverterView = response.snapshot
                    self.inputState = response.inputState.inputState
                    self.refreshMarkedText()
                    self.refreshReplaceSuggestionWindow()
                }
            }
        )
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 終了")
    }

    // MARK: - Window Management
    @MainActor func hideReplaceSuggestionCandidateView() {
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)
    }

    @MainActor func submitSelectedSuggestionCandidate() {
        guard let client = self.client(),
              !self.shouldBlockForGrimodexContext(client: client) else {
            return
        }
        guard let response = self.converterServerClient.sendIfSessionOpenSync({ _ in
            .replaceSuggestion(.submitSelectedReplaceSuggestion)
        }) else {
            return
        }
        self.currentConverterView = response.snapshot
        for effect in response.effects {
            self.apply(effect, client: client)
        }
        self.inputState = response.inputState.inputState
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
    }

    @MainActor private func finishReplaceSuggestionComposition() {
        if self.currentConverterView != nil {
            self.discardConverterServerComposition()
        }
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
    }

    // MARK: - Helper Methods
    private func retrySuggestionRequestIfNeeded(cursorPosition: CGPoint) {
        if retryCount < maxRetries {
            retryCount += 1
            self.segmentsManager.appendDebugMessage("再試行中... (\(retryCount)回目)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestReplaceSuggestion()
            }
        } else {
            self.segmentsManager.appendDebugMessage("再試行上限に達しました。")
            retryCount = 0
        }
    }

}
