import AppKit
import Carbon
import InputMethodKit

// 候选与 AI 浮层属于输入法进程级 UI；输入控制器只在激活时绑定当前会话动作，避免每个 IMK 会话重复创建 WebKit 页面。
private final class TypingChaoOverlayManager {
    static let shared = TypingChaoOverlayManager()

    let candidateOverlay: CandidateOverlay
    private var aiInputOverlayStorage: AIInputOverlay?
    private weak var boundInputController: TypingChaoInputController?
    private var candidateSelectionHandler: ((Int) -> Void)?
    private var pageHandler: ((Bool) -> Void)?
    private var settingsHandler: (() -> Void)?
    private var commitHandler: ((String) -> Void)?
    private var resultHandler: ((String) -> Void)?
    private var serviceProviderHandler: ((AIServiceProvider) -> Void)?
    private var keyHandler: ((NSEvent) -> Bool)?

    private init() {
        candidateOverlay = CandidateOverlay()
        candidateOverlay.setCandidateSelectionHandler { [weak self] candidateIndex in
            self?.candidateSelectionHandler?(candidateIndex)
        }
        candidateOverlay.setPageHandler { [weak self] pageBackward in
            self?.pageHandler?(pageBackward)
        }
        candidateOverlay.setSettingsHandler { [weak self] in
            self?.settingsHandler?()
        }
    }

    var isAIInputVisible: Bool {
        aiInputOverlayStorage?.isVisible ?? false
    }

    var isAIInputPresented: Bool {
        aiInputOverlayStorage?.isPresented ?? false
    }

    func restoreAIInputPresentation() {
        aiInputOverlayStorage?.restorePresentation()
    }

    func ensureAIInputOverlay() -> AIInputOverlay {
        if let aiInputOverlayStorage {
            return aiInputOverlayStorage
        }
        let aiInputOverlay = AIInputOverlay()
        aiInputOverlay.setCommitHandler { [weak self] resultText in
            self?.commitHandler?(resultText)
        }
        aiInputOverlay.setResultHandler { [weak self] resultText in
            self?.resultHandler?(resultText)
        }
        aiInputOverlay.setServiceProviderHandler { [weak self] serviceProvider in
            self?.serviceProviderHandler?(serviceProvider)
        }
        aiInputOverlay.setKeyHandler { [weak self] event in
            self?.keyHandler?(event) ?? true
        }
        aiInputOverlayStorage = aiInputOverlay
        return aiInputOverlay
    }

    // 只有当前输入控制器接管输入法会话时才允许它接收共享浮层动作，避免旧会话回写新会话。
    func bind(
        inputController: TypingChaoInputController,
        candidateSelectionHandler: @escaping (Int) -> Void,
        pageHandler: @escaping (Bool) -> Void,
        settingsHandler: @escaping () -> Void,
        commitHandler: @escaping (String) -> Void,
        resultHandler: @escaping (String) -> Void,
        serviceProviderHandler: @escaping (AIServiceProvider) -> Void,
        keyHandler: @escaping (NSEvent) -> Bool
    ) {
        boundInputController = inputController
        self.candidateSelectionHandler = candidateSelectionHandler
        self.pageHandler = pageHandler
        self.settingsHandler = settingsHandler
        self.commitHandler = commitHandler
        self.resultHandler = resultHandler
        self.serviceProviderHandler = serviceProviderHandler
        self.keyHandler = keyHandler
    }

    func unbind(inputController: TypingChaoInputController) {
        guard boundInputController === inputController else {
            return
        }
        boundInputController = nil
        candidateSelectionHandler = nil
        pageHandler = nil
        settingsHandler = nil
        commitHandler = nil
        resultHandler = nil
        serviceProviderHandler = nil
        keyHandler = nil
    }

    func isBound(to inputController: TypingChaoInputController) -> Bool {
        boundInputController === inputController
    }

    func hideAIInputIfCreated() {
        aiInputOverlayStorage?.hide()
    }
}

// 负责把 IMK 会话、完整 librime 快照、候选交互和输入法内部翻译草稿串在同一个输入会话里。
final class TypingChaoInputController: IMKInputController {
    private static weak var activeOverlayController: TypingChaoInputController?
    private static weak var activeAIInputController: TypingChaoInputController?
    private var rimeSession: TDNRimeSession?
    private let translationService = TranslationService()
    private let translationOverlay = TranslationOverlay()
    private let overlayManager = TypingChaoOverlayManager.shared
    private var candidateOverlay: CandidateOverlay {
        overlayManager.candidateOverlay
    }
    private let inputModeStatusOverlay = InputModeStatusOverlay()
    private var translationDraft = TranslationDraftState()
    private var translationTask: Task<Void, Never>?
    private var displayedTranslation: DisplayedTranslation?
    private let translationSessionIdentifier = UUID().uuidString
    private var translationGeneration = 0
    private var currentRimeSnapshot = RimeSnapshot(dictionary: [:])
    private var overlayAnchorCache = InputOverlayAnchorCache()
    private var sessionClient: IMKTextInput?
    private var lastClient: IMKTextInput?
    private var inputMethodMenu: InputMethodMenu?
    private var aiInputCommandState = AIInputCommandState()
    private var pendingAIInputSelection: AIInputSelectionContext?
    private var activeAIInputSelection: AIInputSelectionContext?
    private var isPresentingAIInput = false
    private var suppressNextHostReturnAfterAICommand = false

    private func ensureAIInputOverlay() -> AIInputOverlay {
        overlayManager.ensureAIInputOverlay()
    }

    override init(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let sharedData = Bundle.main.resourceURL?.appendingPathComponent("RimeData")
        let userData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypingChao/Rime", isDirectory: true)
        if let sharedData {
            rimeSession = TDNRimeSession(
                sharedDataDirectory: sharedData.path,
                userDataDirectory: userData.path
            )
            restoreStoredRimeSettings()
        }

        translationOverlay.setActionHandler { [weak self] actionName in
            switch actionName {
            case .useTranslation:
                self?.commitDisplayedTranslation()
            case .commitOriginal:
                self?.commitOriginalTranslationDraft()
            }
        }
        sessionClient = inputClient as? IMKTextInput
        lastClient = sessionClient
        inputMethodMenu = InputMethodMenu(inputController: self)
    }

    // 共享浮层只接收当前激活控制器的业务动作，避免输入会话之间互相消费候选和 AI 结果。
    private func bindOverlayHandlers() {
        overlayManager.bind(
            inputController: self,
            candidateSelectionHandler: { [weak self] candidateIndex in
                self?.selectCandidate(candidateIndex)
            },
            pageHandler: { [weak self] pageBackward in
                self?.changeCandidatePage(pageBackward: pageBackward)
            },
            settingsHandler: { [weak self] in
                DispatchQueue.main.async {
                    self?.showSettings()
                }
            },
            commitHandler: { [weak self] resultText in
                self?.commitAIInputResult(resultText: resultText)
            },
            resultHandler: { [weak self] resultText in
                self?.updateAIInputMarkedResultPreview(resultText)
            },
            serviceProviderHandler: { serviceProvider in
                InputMethodSettings.shared.setAIServiceProvider(serviceProvider)
            },
            keyHandler: { [weak self] event in
                self?.handleAIInputOverlayKey(event) ?? true
            }
        )
    }


    // 由 InputMethodKit 在输入法菜单展开时获取当前会话状态，避免菜单缓存旧的 Rime option。
    override func menu() -> NSMenu! {
        let menuSnapshot = latestRimeSnapshot()
        let schemaList = rimeSession?.schemaList() ?? []
        let rimeSchemaList = schemaList.map { RimeSchemaItem(dictionary: $0) }
        if let inputMethodMenu {
            return inputMethodMenu.makeMenu(snapshot: menuSnapshot, schemaList: rimeSchemaList)
        }
        return NSMenu(title: "Typing Chao")
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // AI 面板成为第一响应者时 IMK 可能重新激活当前控制器，此处不能把刚打开的面板按普通切换流程关闭。
        if isAIInputPresentationActive {
            overlayManager.restoreAIInputPresentation()
            return
        }
        // 激活时只绑定当前 IMK 会话，不启动跨进程正文或全局键盘监听。
        if let activeController = Self.activeOverlayController,
           activeController !== self {
            activeController.resetForExternalActivation()
        }
        Self.activeOverlayController = self
        bindOverlayHandlers()
        aiInputCommandState.reset()
        suppressNextInputTextEqualsCallback = false
        suppressNextKeyDownEqualsCallback = false
        resetTranslationContext()
        closeAIInput()
        rimeSession?.clearComposition()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        var inputClient = sessionClient
        if let senderClient = sender as? IMKTextInput {
            inputClient = senderClient
        }
        if let currentClient = client() {
            inputClient = currentClient
        }
        if let inputClient {
            prepareClient(inputClient)
        }
    }

    override func deactivateServer(_ sender: Any!) {
        // AI 面板可见时仍由当前控制器处理面板按键，不能因辅助层回调提前结束会话。
        if isAIInputPresentationActive {
            overlayManager.restoreAIInputPresentation()
            return
        }
        let isBoundOverlayController = overlayManager.isBound(to: self)
        // 输入源切出前先上屏原文，避免输入法持有的 marked draft 因会话结束而丢失。
        discardPendingAIInputCommand(client: lastClient)
        closeAIInput()
        commitOriginalTranslationDraft()
        resetTranslationContext()
        rimeSession?.clearComposition()
        if isBoundOverlayController {
            candidateOverlay.hide()
        }
        inputModeStatusOverlay.hide()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        if Self.activeOverlayController === self {
            Self.activeOverlayController = nil
        }
        overlayManager.unbind(inputController: self)
        overlayAnchorCache.reset()
        lastClient = nil
        super.deactivateServer(sender)
    }

    // 隐藏面板只隐藏当前浮层，不结束仍由 marked text 持有的翻译草稿。
    override func hidePalettes() {
        if isAIInputPresentationActive {
            overlayManager.restoreAIInputPresentation()
            return
        }
        closeAIInput()
        cancelTranslationPresentationPreservingDraft()
        if overlayManager.isBound(to: self) {
            candidateOverlay.hide()
        }
        inputModeStatusOverlay.hide()
        super.hidePalettes()
    }

    // 输入会话销毁时取消所有网络和宿主变更观察任务，避免客户端代理被异步任务继续持有。
    override func inputControllerWillClose() {
        discardPendingAIInputCommand(client: lastClient)
        closeAIInput()
        if Self.activeOverlayController === self {
            Self.activeOverlayController = nil
        }
        overlayManager.unbind(inputController: self)
        commitOriginalTranslationDraft()
        resetTranslationContext()
        inputModeStatusOverlay.hide()
        overlayAnchorCache.reset()
        sessionClient = nil
        lastClient = nil
        super.inputControllerWillClose()
    }

    // 由 InputMethodKit 把首个组合键 keyDown 交给输入法，避免等待按键重复事件。
    override func recognizedEvents(_ sender: Any!) -> Int {
        let eventMask: NSEvent.EventTypeMask = [
            .keyDown,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
        ]
        return Int(eventMask.rawValue)
    }

    // IMK 原始事件入口统一处理普通按键和现有输入法命令，AI 面板打开后复用同一主链。
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        prepareClient(client)

        if event.type != .keyDown {
            discardPendingAIInputCommand(client: client)
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                overlayAnchorCache.reset()
                _ = resolvedOverlayAnchor(client: client, allowsCachedAnchor: false)
                if currentRimeSnapshot.isComposing || translationDraft.hasText {
                    commitComposition(client)
                } else {
                    resetTranslationContext()
                }
            }
            if event.type == .leftMouseUp || event.type == .rightMouseUp {
                candidateOverlay.hide()
            }
            return false
        }

        let keyName = keyName(for: event) ?? ""
        if keyName == "Return",
           suppressNextHostReturnAfterAICommand {
            suppressNextHostReturnAfterAICommand = false
            return true
        }
        if overlayManager.isAIInputVisible {
            return handleAIInputKey(event: event, keyName: keyName, client: client)
        }
        let candidateAnchorBeforeEquals = keyName == AIInputCommandState.triggerText &&
            isPlainAIInputCommandKey(event)
            ? resolvedOverlayAnchor(client: client, allowsCachedAnchor: false)
            : nil
        let wasPendingAIInputCommand = aiInputCommandState.isPending
        if handleAIInputCommandKey(event: event, keyName: keyName, client: client) {
            return true
        }
        let showsAIInputCandidateAfterEquals = !wasPendingAIInputCommand &&
            aiInputCommandState.isPending &&
            keyName == AIInputCommandState.triggerText
        if showsAIInputCandidateAfterEquals {
            markPendingAIInputEquals(
                client: client,
                fallbackAnchor: candidateAnchorBeforeEquals
            )
            return true
        }
        if event.modifierFlags.contains([.control, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "t" {
            return activateClipboardTranslationDraft(client: client, userInitiated: true)
        }
        if event.modifierFlags.contains(.control),
           !TranslationPolicy.controlShortcutUsesRime(keyName) {
            commitOriginalTranslationDraft()
            candidateOverlay.hide()
            return false
        }
        if event.modifierFlags.contains(.command) {
            if TranslationPolicy.commandRequestsClipboardTranslation(keyName) {
                return activateClipboardTranslationDraft(client: client, userInitiated: false)
            }
            commitOriginalTranslationDraft()
            candidateOverlay.hide()
            return false
        }
        if keyName == "Escape" {
            return clearInputCache(client: client)
        }
        if handleTranslationDraftEditingKey(keyName, client: client) {
            return true
        }
        if TranslationPolicy.shouldPassThroughHostEditingKey(
            keyName: keyName,
            isComposing: currentRimeSnapshot.isComposing
        ) {
            resetTranslationContext()
            candidateOverlay.hide()
            return false
        }
        if let shiftedKeyName = shiftedCharacterKeyName(for: event) {
            let shiftedSnapshot = processRimeKey(
                shiftedKeyName,
                modifiers: []
            )
            guard let shiftedSnapshot else {
                return false
            }
            guard shiftedSnapshot.handled else {
                return handleUnhandledKey(shiftedKeyName, client: client)
            }
            updateClient(client, snapshot: shiftedSnapshot)
            return true
        }
        let modifierNameList = modifierNames(for: event.modifierFlags)
        guard let snapshot = processRimeKey(keyName, modifiers: modifierNameList) else {
            return false
        }
        guard snapshot.handled else {
            return handleUnhandledKey(keyName, client: client)
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    // IMK 的 Return 可能从 inputText 入口再次到达；AI 候选确认期间必须在该入口也截断宿主回车。
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let client = sender as? IMKTextInput else {
            return super.inputText(string, client: sender)
        }
        prepareClient(client)
        // AI 面板仍复用当前控制器的 IMK 会话；同一轮 Return 可能再次经 inputText 回传，必须全部截断，不能交给宿主。
        if overlayManager.isAIInputVisible {
            let aiInputOverlay = ensureAIInputOverlay()
            guard let inputKeyName = TranslationPolicy.rimeKeyName(for: string) else {
                return true
            }
            if inputKeyName == "BackSpace" || inputKeyName == "Delete" {
                return true
            }
            if inputKeyName == "Return" {
                if suppressNextHostReturnAfterAICommand {
                    suppressNextHostReturnAfterAICommand = false
                } else if aiInputOverlay.acceptsPromptInput {
                    aiInputOverlay.submitPrompt()
                }
            }
            return true
        }
        guard let inputKeyName = TranslationPolicy.rimeKeyName(for: string) else {
            discardPendingAIInputCommand(client: client)
            return super.inputText(string, client: sender)
        }
        if inputKeyName == AIInputCommandState.triggerText {
            let candidateAnchorBeforeEquals = resolvedOverlayAnchor(
                client: client,
                allowsCachedAnchor: false
            )
            if suppressNextInputTextEqualsCallback {
                suppressNextInputTextEqualsCallback = false
                return true
            }
            let wasPending = aiInputCommandState.isPending
            let isHandled = handleAIInputCommand(
                keyName: inputKeyName,
                isPlainKey: true,
                client: client
            )
            if isHandled {
                return true
            }
            if !wasPending, aiInputCommandState.isPending {
                armNextKeyDownEqualsSuppression()
                markPendingAIInputEquals(
                    client: client,
                    fallbackAnchor: candidateAnchorBeforeEquals
                )
                return true
            }
            if wasPending {
                return processStandaloneEquals(client: client)
            }
        }
        if aiInputCommandState.isPending,
           inputKeyName != "Return" {
            discardPendingAIInputCommand(client: client)
        }
        guard inputKeyName == "Return" else {
            return super.inputText(string, client: sender)
        }
        if suppressNextHostReturnAfterAICommand {
            suppressNextHostReturnAfterAICommand = false
            return true
        }
        if aiInputCommandState.isPending, aiInputCommandState.isTriggerReady {
            suppressNextHostReturnAfterAICommand = true
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextHostReturnAfterAICommand = false
            }
            showAIInput(client: client)
            return true
        }
        return super.inputText(string, client: sender)
    }

    // 外部要求结束组字时先收口 librime，再把完整内部草稿作为原文一次性提交宿主。
    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else {
            super.commitComposition(sender)
            return
        }
        prepareClient(client)
        if overlayManager.isAIInputVisible {
            return
        }
        if aiInputCommandState.isPending, aiInputCommandState.isTriggerReady {
            suppressNextHostReturnAfterAICommand = true
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextHostReturnAfterAICommand = false
            }
            showAIInput(client: client)
            return
        }
        if let rimeSession {
            let snapshot = RimeSnapshot(dictionary: rimeSession.commitComposition())
            currentRimeSnapshot = snapshot
            if !snapshot.commitText.isEmpty {
                handleConfirmedTextInput(
                    snapshot.commitText,
                    client: client,
                    shouldScheduleTranslation: false
                )
            }
            rimeSession.clearComposition()
            currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession.currentSnapshot())
            candidateOverlay.hide()
            if translationDraft.hasText {
                commitOriginalTranslationDraft()
            }
            return
        }
        super.commitComposition(sender)
    }

    // 完整快照是 marked text、候选壳与提交文本的唯一状态来源，避免各层自行推断分页和光标。
    private func updateClient(_ client: IMKTextInput, snapshot: RimeSnapshot) {
        let previousSnapshot = currentRimeSnapshot
        let wasComposing = previousSnapshot.isComposing
        let statusMessage = InputModeStatusMessage.resolve(
            previous: previousSnapshot,
            current: snapshot
        )
        persistChangedCharacterOptionState(previous: previousSnapshot, current: snapshot)
        currentRimeSnapshot = snapshot
        if snapshot.isComposing {
            cancelTranslationPresentationPreservingDraft()
        }
        if !snapshot.commitText.isEmpty {
            handleConfirmedTextInput(
                snapshot.commitText,
                client: client,
                shouldScheduleTranslation: !snapshot.isComposing
            )
        }

        guard snapshot.isComposing else {
            refreshMarkedText(client: client, snapshot: snapshot)
            candidateOverlay.hide()
            if let statusMessage,
               let anchor = resolvedOverlayAnchor(client: client, allowsCachedAnchor: false) {
                inputModeStatusOverlay.show(
                    message: statusMessage,
                    anchor: anchor,
                    candidateFrame: translationOverlay.visibleFrame
                )
            }
            if translationDraft.hasText,
               wasComposing,
               snapshot.commitText.isEmpty {
                scheduleCommittedTextTranslation(userInitiated: false)
            }
            return
        }

        let markedText = markedText(for: snapshot)
        let draftUTF16Length = translationDraft.textValue.utf16.count
        var markedSelectionRange = NSRange(
            location: draftUTF16Length + snapshot.caretOffset,
            length: 0
        )
        if snapshot.selectionRange.length > 0 {
            markedSelectionRange = NSRange(
                location: draftUTF16Length + snapshot.selectionRange.location,
                length: snapshot.selectionRange.length
            )
        }
        client.setMarkedText(
            markedText,
            selectionRange: markedSelectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        guard let anchor = resolvedOverlayAnchor(client: client, allowsCachedAnchor: false) else {
            candidateOverlay.hide()
            translationOverlay.hide()
            return
        }
        candidateOverlay.show(snapshot: snapshot, anchor: anchor)
        if isTranslationDraftModeActive {
            translationOverlay.showWaiting(
                languagePair: translationService.languagePairTitle,
                anchor: anchor,
                candidateFrame: candidateOverlay.visibleFrame
            )
        } else {
            translationOverlay.updatePosition(anchor: anchor, candidateFrame: candidateOverlay.visibleFrame)
        }
        if let statusMessage {
            inputModeStatusOverlay.show(
                message: statusMessage,
                anchor: anchor,
                candidateFrame: candidateOverlay.visibleFrame
            )
        }
    }

    // marked text 由已确认中文草稿和当前 librime preedit 组成，宿主正文只显示这一份原文。
    private func markedText(for snapshot: RimeSnapshot) -> NSAttributedString {
        let draftText = translationDraft.textValue
        let markedText = NSMutableAttributedString(string: draftText + snapshot.preeditText)
        let fullRange = NSRange(location: 0, length: markedText.length)
        markedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: fullRange
        )
        markedText.addAttribute(
            .underlineColor,
            value: NSColor(calibratedWhite: 0.45, alpha: 0.65),
            range: fullRange
        )
        let draftUTF16Length = draftText.utf16.count
        let selectedPreeditRange = NSRange(
            location: draftUTF16Length + snapshot.selectionRange.location,
            length: snapshot.selectionRange.length
        )
        if selectedPreeditRange.length > 0,
           NSMaxRange(selectedPreeditRange) <= markedText.length {
            markedText.addAttribute(
                .backgroundColor,
                value: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 0.18),
                range: selectedPreeditRange
            )
        }
        return markedText
    }

    // 翻译模式只把确认文本追加到内部草稿；关闭翻译或安全输入时才直接写入宿主。
    private func handleConfirmedTextInput(
        _ inputText: String,
        client: IMKTextInput,
        shouldScheduleTranslation: Bool = true
    ) {
        guard isTranslationDraftModeActive else {
            commitOriginalTranslationDraft(
                client: client,
                includesCurrentComposition: false
            )
            insertConfirmedText(inputText, client: client)
            return
        }
        let sourceSnapshot = translationDraft.appendConfirmedText(
            inputText,
            clientIdentifier: currentTranslationSessionIdentifier()
        )
        refreshMarkedText(client: client, snapshot: currentRimeSnapshot)
        if shouldScheduleTranslation, let sourceSnapshot {
            scheduleTranslation(
                fallbackSnapshot: sourceSnapshot,
                client: client,
                userInitiated: false
            )
        } else if sourceSnapshot == nil {
            showTranslationDraftWaiting(client: client)
        }
    }

    // 组合结束但本轮没有新提交时，复用本输入法已知的稳定提交草稿。
    private func scheduleCommittedTextTranslation(userInitiated: Bool) {
        guard isRemoteTranslationAllowed,
              let lastClient,
              let sourceSnapshot = translationDraft.currentSnapshot() else {
            return
        }
        scheduleTranslation(
            fallbackSnapshot: sourceSnapshot,
            client: lastClient,
            userInitiated: userInitiated
        )
    }

    // 只有宿主明确转发粘贴或用户手动触发时，剪贴板文本才成为新的 marked draft。
    private func activateClipboardTranslationDraft(
        client: IMKTextInput,
        expectedText: String? = nil,
        userInitiated: Bool
    ) -> Bool {
        guard isTranslationDraftModeActive else { return false }
        guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
            return false
        }
        if let expectedText {
            let normalizedExpectedText = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedClipboardText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedExpectedText.isEmpty,
                  normalizedExpectedText == normalizedClipboardText else {
                return false
            }
        }
        let sourceSnapshot = translationDraft.synchronizeClipboardText(
            clipboardText,
            clientIdentifier: currentTranslationSessionIdentifier()
        )
        guard translationDraft.hasText else { return false }
        rimeSession?.clearComposition()
        currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession?.currentSnapshot() ?? [:])
        candidateOverlay.hide()
        refreshMarkedText(client: client, snapshot: currentRimeSnapshot)
        if let sourceSnapshot {
            scheduleTranslation(
                fallbackSnapshot: sourceSnapshot,
                client: client,
                userInitiated: userInitiated
            )
        } else {
            showTranslationDraftWaiting(client: client)
        }
        return true
    }

    // 每个请求固定完整 marked draft、请求代次与锚点；自动请求等待一秒稳定期。
    private func scheduleTranslation(
        fallbackSnapshot: TranslationSourceSnapshot,
        client: IMKTextInput,
        userInitiated: Bool
    ) {
        guard isRemoteTranslationAllowed else {
            resetTranslationContext()
            return
        }
        translationGeneration += 1
        let requestGeneration = translationGeneration
        let scheduledAnchor = resolvedOverlayAnchor(client: client)
        var sourceKindName = "input-method-draft"
        if fallbackSnapshot.sourceKind == .clipboardDraft {
            sourceKindName = "clipboard"
        }
        NSLog(
            "TypingChao scheduled translation generation %d, source: %@, characters: %d",
            requestGeneration,
            sourceKindName,
            fallbackSnapshot.sourceText.count
        )
        translationTask?.cancel()
        displayedTranslation = nil
        showTranslationDraftWaiting(client: client, fallbackAnchor: scheduledAnchor)
        translationTask = Task { [weak self] in
            guard let self else { return }
            var delayMilliseconds = TranslationPolicy.stableInputDelayMilliseconds
            if userInitiated {
                delayMilliseconds = TranslationPolicy.userInitiatedDelayMilliseconds
            }
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }

            let requestCanStart = await MainActor.run {
                self.translationGeneration == requestGeneration &&
                    self.isRemoteTranslationAllowed &&
                    self.isActiveOverlayController &&
                    !self.currentRimeSnapshot.isComposing &&
                    self.translationDraft.resolvedSnapshot(
                        clientIdentifier: self.currentTranslationSessionIdentifier(),
                        fallbackSnapshot: fallbackSnapshot
                    ) != nil
            }
            guard requestCanStart else {
                NSLog("TypingChao skipped translation generation %d before request", requestGeneration)
                return
            }

            NSLog(
                "TypingChao starting translation generation %d, characters: %d",
                requestGeneration,
                fallbackSnapshot.sourceText.count
            )
            await MainActor.run {
                guard self.translationGeneration == requestGeneration,
                      let anchor = self.resolvedOverlayAnchor(client: self.lastClient) ?? scheduledAnchor else {
                    return
                }
                self.translationOverlay.showLoading(
                    languagePair: self.translationService.languagePairTitle,
                    anchor: anchor,
                    candidateFrame: self.candidateOverlay.visibleFrame
                )
            }

            do {
                let translatedText = try await self.translationService.translate(fallbackSnapshot.sourceText)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.translationGeneration == requestGeneration,
                          self.isRemoteTranslationAllowed,
                          self.isActiveOverlayController,
                          !self.currentRimeSnapshot.isComposing,
                          self.translationDraft.resolvedSnapshot(
                              clientIdentifier: self.currentTranslationSessionIdentifier(),
                              fallbackSnapshot: fallbackSnapshot
                          ) != nil else {
                        return
                    }
                    self.translationTask = nil
                    guard let anchor = self.resolvedOverlayAnchor(client: self.lastClient) ?? scheduledAnchor else {
                        NSLog("TypingChao translation completed without a valid overlay anchor")
                        return
                    }
                    self.displayedTranslation = DisplayedTranslation(
                        sourceSnapshot: fallbackSnapshot,
                        translatedText: translatedText
                    )
                    self.translationOverlay.showTranslation(
                        translatedText: translatedText,
                        languagePair: self.translationService.languagePairTitle,
                        anchor: anchor,
                        candidateFrame: self.candidateOverlay.visibleFrame
                    )
                    NSLog("TypingChao displayed translation generation %d", requestGeneration)
                }
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("TypingChao translation error: %@", error.localizedDescription)
                await MainActor.run {
                    guard self.translationGeneration == requestGeneration,
                          self.isRemoteTranslationAllowed,
                          self.isActiveOverlayController,
                          !self.currentRimeSnapshot.isComposing,
                          self.translationDraft.resolvedSnapshot(
                              clientIdentifier: self.currentTranslationSessionIdentifier(),
                              fallbackSnapshot: fallbackSnapshot
                          ) != nil else {
                        return
                    }
                    self.translationTask = nil
                    self.displayedTranslation = nil
                    guard let anchor = self.resolvedOverlayAnchor(client: self.lastClient) ?? scheduledAnchor else {
                        NSLog("TypingChao translation error cannot be shown without a valid overlay anchor")
                        return
                    }
                    self.translationOverlay.showError(
                        message: error.localizedDescription,
                        languagePair: self.translationService.languagePairTitle,
                        anchor: anchor,
                        candidateFrame: self.candidateOverlay.visibleFrame
                    )
                }
            }
        }
    }

    // 使用译文只校验当前内部草稿快照，随后把译文一次性提交为宿主正文。
    private func commitDisplayedTranslation() {
        guard let displayedTranslation, let lastClient else {
            NSLog("TypingChao ignored translation action without an active draft result")
            translationOverlay.hide()
            return
        }
        guard translationDraft.resolvedSnapshot(
            clientIdentifier: currentTranslationSessionIdentifier(),
            fallbackSnapshot: displayedTranslation.sourceSnapshot
        ) != nil else {
            NSLog("TypingChao rejected translation action because the marked draft changed")
            self.displayedTranslation = nil
            showTranslationDraftWaiting(client: lastClient)
            return
        }

        translationGeneration += 1
        translationTask?.cancel()
        lastClient.insertText(
            displayedTranslation.translatedText,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        NSLog(
            "TypingChao committed translated draft, source characters: %d",
            displayedTranslation.sourceSnapshot.sourceText.count
        )
        translationDraft.reset()
        self.displayedTranslation = nil
        currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession?.currentSnapshot() ?? [:])
        translationOverlay.hide()
    }


    // 菜单切换 Rime 状态前先取消旧草稿，避免新字形或输入模式继续展示旧译文。
    func applyRimeOptionStateList(_ optionStateList: [RimeOptionState]) {
        guard let rimeSession, !optionStateList.isEmpty else {
            return
        }
        commitOriginalTranslationDraft()
        resetTranslationContext()
        rimeSession.clearComposition()
        var snapshotDictionary = rimeSession.currentSnapshot()
        for optionState in optionStateList {
            snapshotDictionary = rimeSession.setOption(
                optionState.optionName.rawValue,
                enabled: optionState.isEnabled
            )
        }
        InputMethodSettings.shared.persistRimeOptionStateList(optionStateList)
        refreshAfterRimeMenuAction(snapshotDictionary)
    }

    // Rime 快捷键产生的半/全角和标点变化必须同步持久化，不能只在菜单操作时保存。
    private func persistChangedCharacterOptionState(previous: RimeSnapshot, current: RimeSnapshot) {
        guard !previous.schemaIdentifier.isEmpty else { return }
        var optionStateList: [RimeOptionState] = []
        if previous.isFullShape != current.isFullShape {
            optionStateList.append(
                RimeOptionState(optionName: .fullShape, isEnabled: current.isFullShape)
            )
        }
        if previous.isAsciiPunctuation != current.isAsciiPunctuation {
            optionStateList.append(
                RimeOptionState(optionName: .asciiPunctuation, isEnabled: current.isAsciiPunctuation)
            )
        }
        guard !optionStateList.isEmpty else { return }
        InputMethodSettings.shared.persistRimeOptionStateList(optionStateList)
    }

    // 输入方案选择只切换当前 librime 会话，绝不选择或改变 macOS 当前系统输入源。
    func selectRimeSchema(_ schemaIdentifier: String) {
        guard let rimeSession, !schemaIdentifier.isEmpty else {
            return
        }
        commitOriginalTranslationDraft()
        resetTranslationContext()
        rimeSession.clearComposition()
        let snapshotDictionary = rimeSession.selectSchema(schemaIdentifier)
        let snapshot = RimeSnapshot(dictionary: snapshotDictionary)
        guard snapshot.schemaIdentifier == schemaIdentifier else {
            return
        }
        InputMethodSettings.shared.setSelectedSchemaIdentifier(schemaIdentifier)
        refreshAfterRimeMenuAction(snapshotDictionary)
    }

    // 关闭翻译时立即取消请求和浮层，避免当前输入内容在设置切换后仍被发送。
    func setTranslationEnabled(_ enabled: Bool) {
        if !enabled {
            commitOriginalTranslationDraft()
        }
        InputMethodSettings.shared.setTranslationEnabled(enabled)
        resetTranslationContext()
    }

    // 目标语言改变后保留 marked draft，并按新目标语言重新等待稳定期。
    func setTranslationTargetLanguage(_ targetLanguage: TranslationTargetLanguage) {
        InputMethodSettings.shared.setTargetLanguage(targetLanguage)
        cancelTranslationPresentationPreservingDraft()
        scheduleCommittedTextTranslation(userInitiated: false)
    }

    // 候选条与输入法菜单共用同一个设置入口，窗口打开时读取当前会话快照。
    func showSettings() {
        discardPendingAIInputCommand(client: lastClient)
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        let schemaList = (rimeSession?.schemaList() ?? []).map { RimeSchemaItem(dictionary: $0) }
        TypingChaoApplicationDelegate.shared.showSettings(
            inputController: self,
            snapshot: latestRimeSnapshot(),
            schemaList: schemaList
        )
    }

    // 菜单动作可能在 IMK 暂时回调 deactivateServer 后到达，因此优先重新取得当前会话客户端，不能只依赖已清空的 lastClient。
    func showAIInput() {
        guard let inputClient = currentInputClient() else {
            NSLog("TypingChao cannot show AI input without an active client")
            return
        }
        prepareClient(inputClient)
        showAIInput(
            client: inputClient,
            selectionContext: selectedAIInputSelectionContext(from: inputClient)
        )
    }

    private func currentInputClient() -> IMKTextInput? {
        if let currentClient = client() {
            return currentClient
        }
        return sessionClient ?? lastClient
    }




    // 新会话先恢复本项目保存的 Rime 方案和开关；英文模式按 schema 默认值保持会话级行为。
    private func restoreStoredRimeSettings() {
        guard let rimeSession else {
            return
        }
        if let schemaIdentifier = InputMethodSettings.shared.selectedSchemaIdentifier {
            let schemaList = rimeSession.schemaList()
            let hasStoredSchema = schemaList.contains { schema in
                schema["identifier"] == schemaIdentifier
            }
            if hasStoredSchema {
                _ = rimeSession.selectSchema(schemaIdentifier)
            }
        }
        for optionState in InputMethodSettings.shared.persistedRimeOptionStateList() {
            _ = rimeSession.setOption(
                optionState.optionName.rawValue,
                enabled: optionState.isEnabled
            )
        }
        currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession.currentSnapshot())
    }

    private func latestRimeSnapshot() -> RimeSnapshot {
        guard let rimeSession else {
            return currentRimeSnapshot
        }
        let snapshot = RimeSnapshot(dictionary: rimeSession.currentSnapshot())
        if !snapshot.schemaIdentifier.isEmpty {
            currentRimeSnapshot = snapshot
        }
        return currentRimeSnapshot
    }

    private func refreshAfterRimeMenuAction(_ snapshotDictionary: [String: Any]) {
        let snapshot = RimeSnapshot(dictionary: snapshotDictionary)
        guard let lastClient else {
            currentRimeSnapshot = snapshot
            candidateOverlay.hide()
            return
        }
        updateClient(lastClient, snapshot: snapshot)
    }

    // 鼠标选词执行 librime 当前页选择并复用键盘提交的同一更新链。
    private func selectCandidate(_ candidateIndex: Int) {
        guard let lastClient else { return }
        if aiInputCommandState.isTriggerReady, candidateIndex == 0 {
            showAIInput(client: lastClient)
            return
        }
        guard let rimeSession else { return }
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.selectCandidate(UInt(candidateIndex))
        )
        guard snapshot.handled else { return }
        if overlayManager.isAIInputVisible {
            updateAIInputOverlay(client: lastClient, snapshot: snapshot)
            return
        }
        updateClient(lastClient, snapshot: snapshot)
    }

    // 翻页动作由 librime 决定是否可执行，成功后用返回页的标签和注释整体刷新候选壳。
    private func changeCandidatePage(pageBackward: Bool) {
        guard let rimeSession, let lastClient else { return }
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.changePageBackward(pageBackward)
        )
        guard snapshot.handled else { return }
        if overlayManager.isAIInputVisible {
            updateAIInputOverlay(client: lastClient, snapshot: snapshot)
            return
        }
        updateClient(lastClient, snapshot: snapshot)
    }

    // 同一控制器内 IMK 客户端代理可能逐次变化，只更新当前代理，不据此清空整句草稿。
    private func prepareClient(_ client: IMKTextInput) {
        if let activeController = Self.activeOverlayController,
           activeController !== self {
            activeController.resetForExternalActivation()
        }
        if Self.activeOverlayController !== self {
            Self.activeOverlayController = self
            bindOverlayHandlers()
        }
        sessionClient = client
        lastClient = client
    }


    // 翻译草稿绑定当前控制器生命周期，不使用会在同一编辑框内抖动的 IMK 客户端标识。
    private func currentTranslationSessionIdentifier() -> String {
        translationSessionIdentifier
    }

    // 翻译层允许短暂复用同一 IMK 会话最近一次可信锚点，候选层仍只接受本次实时坐标。
    private func resolvedOverlayAnchor(
        client: IMKTextInput?,
        allowsCachedAnchor: Bool = true
    ) -> InputOverlayAnchor? {
        guard let client else { return nil }
        let clientIdentifier = overlayClientIdentifier(client)
        let currentAnchor = InputOverlayAnchor(client: client)
        if !allowsCachedAnchor, currentAnchor == nil {
            return nil
        }
        return overlayAnchorCache.resolve(
            currentAnchor: currentAnchor,
            clientIdentifier: clientIdentifier
        )
    }

    private func overlayClientIdentifier(_ client: IMKTextInput) -> String {
        let bundleIdentifier = client.bundleIdentifier() ?? "<unknown>"
        if let uniqueIdentifier = client.uniqueClientIdentifierString(),
           !uniqueIdentifier.isEmpty {
            return bundleIdentifier + ":" + uniqueIdentifier
        }
        return bundleIdentifier + ":" + String(describing: ObjectIdentifier(client as AnyObject))
    }

    private var isActiveOverlayController: Bool {
        Self.activeOverlayController === self
    }

    // AI 面板展示期间忽略 IMK 的暂时性会话切换，避免面板刚置前就被生命周期清理。
    private var isAIInputPresentationActive: Bool {
        isPresentingAIInput || overlayManager.isAIInputPresented
    }

    private var isActiveAIInputController: Bool {
        Self.activeAIInputController === self && isAIInputPresentationActive
    }

    // 系统启用安全事件输入时禁止把已提交文本交给远程翻译服务。
    private var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    // 翻译开关开启且不处于安全输入时，确认文本由 marked draft 持有而不是立即上屏。
    private var isTranslationDraftModeActive: Bool {
        InputMethodSettings.shared.isTranslationEnabled && !isSecureInputActive
    }

    // 发送前和异步回写前共用同一资格判断，避免安全输入或设置变化后的旧任务继续运行。
    private var isRemoteTranslationAllowed: Bool {
        TranslationPolicy.allowsRemoteTranslation(
            isTranslationEnabled: InputMethodSettings.shared.isTranslationEnabled,
            isSecureInputActive: isSecureInputActive
        )
    }

    // 其它输入会话接管时只收口本会话，不触碰新会话的 Rime 状态。
    private func resetForExternalActivation() {
        guard !isActiveAIInputController else {
            return
        }
        discardPendingAIInputCommand(client: lastClient)
        closeAIInput()
        commitOriginalTranslationDraft()
        resetTranslationContext()
        rimeSession?.clearComposition()
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        overlayManager.unbind(inputController: self)
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        overlayAnchorCache.reset()
        lastClient = nil
    }

    // 组合码变化时取消旧请求和旧结果，但保留输入法内部已经确认的中文草稿。
    private func cancelTranslationPresentationPreservingDraft() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        displayedTranslation = nil
        translationOverlay.hide()
    }

    // marked text 始终由内部草稿和当前 preedit 共同生成，避免宿主正文出现重复原文。
    private func refreshMarkedText(client: IMKTextInput, snapshot: RimeSnapshot) {
        guard isTranslationDraftModeActive, translationDraft.hasText || snapshot.isComposing else {
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return
        }
        let draftUTF16Length = translationDraft.textValue.utf16.count
        var selectionRange = NSRange(
            location: draftUTF16Length + snapshot.caretOffset,
            length: 0
        )
        if snapshot.selectionRange.length > 0 {
            selectionRange = NSRange(
                location: draftUTF16Length + snapshot.selectionRange.location,
                length: snapshot.selectionRange.length
            )
        }
        client.setMarkedText(
            markedText(for: snapshot),
            selectionRange: selectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    // 草稿存在时稳定展示翻译模式，等待、超长和候选组合态共用同一光标锚点。
    private func showTranslationDraftWaiting(
        client: IMKTextInput,
        fallbackAnchor: InputOverlayAnchor? = nil
    ) {
        guard isTranslationDraftModeActive,
              let anchor = resolvedOverlayAnchor(client: client) ?? fallbackAnchor else {
            translationOverlay.hide()
            return
        }
        if translationDraft.exceedsCharacterLimit {
            translationOverlay.showError(
                message: "内容超过 600 个字符，请先上屏原文后继续输入",
                languagePair: translationService.languagePairTitle,
                anchor: anchor,
                candidateFrame: candidateOverlay.visibleFrame
            )
            return
        }
        translationOverlay.showWaiting(
            languagePair: translationService.languagePairTitle,
            anchor: anchor,
            candidateFrame: candidateOverlay.visibleFrame
        )
    }

    // 空组合态的退格编辑内部草稿，回车确认原文，避免按键落到宿主后再追溯读取。
    private func handleTranslationDraftEditingKey(
        _ keyName: String,
        client: IMKTextInput
    ) -> Bool {
        guard isTranslationDraftModeActive,
              !currentRimeSnapshot.isComposing,
              translationDraft.hasText else {
            return false
        }
        if keyName == "BackSpace" {
            cancelTranslationPresentationPreservingDraft()
            let sourceSnapshot = translationDraft.removeLastCharacter(
                clientIdentifier: currentTranslationSessionIdentifier()
            )
            refreshMarkedText(client: client, snapshot: currentRimeSnapshot)
            if let sourceSnapshot {
                scheduleTranslation(
                    fallbackSnapshot: sourceSnapshot,
                    client: client,
                    userInitiated: false
                )
            } else if translationDraft.hasText {
                showTranslationDraftWaiting(client: client)
            } else {
                translationOverlay.hide()
            }
            return true
        }
        if keyName == "Return" {
            commitOriginalTranslationDraft(client: client)
            return true
        }
        if keyName == "Delete" {
            return true
        }
        return false
    }

    // 未被 Rime 接管的确定文本进入内部草稿；未知编辑动作先确认原文再交还宿主。
    private func handleUnhandledKey(_ keyName: String, client: IMKTextInput) -> Bool {
        if keyName == "Shift_L" || keyName == "Shift_R" {
            return false
        }
        guard let passThroughText = TranslationPolicy.passThroughText(for: keyName) else {
            commitOriginalTranslationDraft(client: client)
            candidateOverlay.hide()
            return false
        }
        guard isTranslationDraftModeActive else {
            return false
        }
        let sourceSnapshot = translationDraft.appendConfirmedText(
            passThroughText,
            clientIdentifier: currentTranslationSessionIdentifier()
        )
        refreshMarkedText(client: client, snapshot: currentRimeSnapshot)
        if let sourceSnapshot {
            scheduleTranslation(
                fallbackSnapshot: sourceSnapshot,
                client: client,
                userInitiated: false
            )
        } else {
            showTranslationDraftWaiting(client: client)
        }
        candidateOverlay.hide()
        return true
    }

    // 非翻译模式下确认文本直接写入宿主，不维护历史正文或替换范围。
    private func insertConfirmedText(_ inputText: String, client: IMKTextInput) {
        client.insertText(
            inputText,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    // 上屏原文会先收口当前 librime preedit，再把完整 marked draft 一次性提交宿主。
    private func commitOriginalTranslationDraft(
        client: IMKTextInput? = nil,
        includesCurrentComposition: Bool = true
    ) {
        let targetClient = client ?? lastClient
        if includesCurrentComposition,
           currentRimeSnapshot.isComposing,
           let rimeSession {
            let committedSnapshot = RimeSnapshot(dictionary: rimeSession.commitComposition())
            if !committedSnapshot.commitText.isEmpty {
                _ = translationDraft.appendConfirmedText(
                    committedSnapshot.commitText,
                    clientIdentifier: currentTranslationSessionIdentifier()
                )
            }
            rimeSession.clearComposition()
            currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession.currentSnapshot())
        }
        guard let targetClient, translationDraft.hasText else {
            return
        }
        let originalText = translationDraft.textValue
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        displayedTranslation = nil
        targetClient.insertText(
            originalText,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        NSLog(
            "TypingChao committed original translation draft, characters: %d",
            originalText.count
        )
        translationDraft.reset()
        candidateOverlay.hide()
        translationOverlay.hide()
    }

    // Esc 只取消当前拼音和译文展示，已经确认的 marked draft 保留给后续继续输入。
    private func clearInputCache(client: IMKTextInput) -> Bool {
        let hadActiveInputState = currentRimeSnapshot.isComposing ||
            translationDraft.hasText ||
            translationTask != nil
        cancelTranslationPresentationPreservingDraft()
        rimeSession?.clearComposition()
        let snapshotDictionary = rimeSession?.currentSnapshot() ?? [:]
        currentRimeSnapshot = RimeSnapshot(dictionary: snapshotDictionary)
        refreshMarkedText(client: client, snapshot: currentRimeSnapshot)
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        overlayAnchorCache.reset()
        return hadActiveInputState
    }

    // 输入会话结束或最终提交后统一取消旧请求并清空内部草稿。
    private func resetTranslationContext() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translationDraft.reset()
        displayedTranslation = nil
        translationOverlay.hide()
    }

    // 输入法内部入口直接展示 AI 输入，不依赖宿主可能提前消费的全局快捷键。
    private func showAIInput(
        client: IMKTextInput,
        selectionContext: AIInputSelectionContext? = nil
    ) {
        if let activeAIInputController = Self.activeAIInputController {
            if activeAIInputController !== self {
                return
            }
            overlayManager.restoreAIInputPresentation()
            return
        }
        guard !overlayManager.isAIInputVisible else {
            overlayManager.restoreAIInputPresentation()
            return
        }
        guard !isSecureInputActive else {
            return
        }
        let resolvedSelectionContext = selectionContext ?? pendingAIInputSelection
        Self.activeAIInputController = self
        isPresentingAIInput = true
        defer { isPresentingAIInput = false }
        presentAIInput(
            client: client,
            anchor: resolvedOverlayAnchor(client: client),
            selectionContext: resolvedSelectionContext
        )
    }

    // AI 输入统一收口当前草稿和辅助浮层；没有可信光标时由面板居中展示。
    private func presentAIInput(
        client: IMKTextInput,
        anchor: InputOverlayAnchor?,
        selectionContext: AIInputSelectionContext?
    ) {
        commitOriginalTranslationDraft(client: client)
        resetTranslationContext()
        rimeSession?.clearComposition()
        currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession?.currentSnapshot() ?? [:])
        // 快速入口保留 marked 等号作为结果替换范围，菜单和选区入口才清空旧组合文本。
        if !aiInputCommandState.isPending {
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        candidateOverlay.hide()
        translationOverlay.hide()
        inputModeStatusOverlay.hide()
        activeAIInputSelection = selectionContext
        ensureAIInputOverlay().show(
            anchor: anchor,
            prefilledPromptText: selectionContext?.selectedText ?? ""
        )
    }

    // 快速等号入口同步更新宿主 marked text，让结果可见但仍保持未提交状态。
    private func updateAIInputMarkedResultPreview(_ resultText: String) {
        guard aiInputCommandState.isPending,
              activeAIInputSelection == nil,
              let lastClient,
              !resultText.isEmpty else {
            return
        }
        let markedText = NSMutableAttributedString(string: resultText)
        markedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: markedText.length)
        )
        lastClient.setMarkedText(
            markedText,
            selectionRange: NSRange(location: markedText.length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    // AI 结果先替换宿主 marked text，再关闭面板，避免触发等号残留或再次翻译。
    private func commitAIInputResult(resultText: String) {
        guard let lastClient, !resultText.isEmpty else {
            NSLog("TypingChao ignored AI input result without an active client")
            closeAIInput()
            return
        }
        let replacementRange = activeAIInputSelection.flatMap { selectionContext in
            guard lastClient.selectedRange() == selectionContext.replacementRange else {
                return nil
            }
            return selectionContext.replacementRange
        } ?? NSRange(location: NSNotFound, length: 0)
        lastClient.insertText(
            resultText,
            replacementRange: replacementRange
        )
        aiInputCommandState.reset()
        closeAIInput()
    }

    // 关闭 AI 面板时恢复未完成的等号输入，并通知 React 取消当前直连请求。
    private func closeAIInput() {
        discardPendingAIInputCommand(client: lastClient)
        isPresentingAIInput = false
        pendingAIInputSelection = nil
        activeAIInputSelection = nil
        rimeSession?.clearComposition()
        currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession?.currentSnapshot() ?? [:])
        if overlayManager.isBound(to: self) {
            candidateOverlay.hide()
            overlayManager.hideAIInputIfCreated()
        }
        if Self.activeAIInputController === self {
            Self.activeAIInputController = nil
        }
    }

    // AI 面板成为第一响应者后仍复用当前 Rime 会话，确保焦点和回退键只作用于面板。
    private func handleAIInputOverlayKey(_ event: NSEvent) -> Bool {
        guard let client = lastClient,
              let keyName = keyName(for: event),
              !keyName.isEmpty else {
            return true
        }
        return handleAIInputKey(event: event, keyName: keyName, client: client)
    }

    // AI 面板输入用 Enter、Command-Enter、Escape 收口主要操作，减少鼠标依赖。
    private func handleAIInputKey(
        event: NSEvent,
        keyName: String,
        client: IMKTextInput
    ) -> Bool {
        let aiInputOverlay = ensureAIInputOverlay()
        if keyName == "Escape" {
            if currentRimeSnapshot.isComposing {
                clearAIInputComposition()
            } else {
                closeAIInput()
            }
            return true
        }
        guard aiInputOverlay.acceptsPromptInput else { return true }
        if keyName == "BackSpace", !currentRimeSnapshot.isComposing {
            aiInputOverlay.deleteBackwardPromptText()
            return true
        }
        if keyName == "Delete" {
            return true
        }
        if event.modifierFlags.contains(.command) {
            if keyName == "Return", aiInputOverlay.canCommitResult {
                aiInputOverlay.commitResult()
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "v",
               let pastedText = NSPasteboard.general.string(forType: .string),
               !pastedText.isEmpty {
                clearAIInputComposition()
                aiInputOverlay.appendPromptText(pastedText)
            }
            return true
        }
        if keyName == "Return", !currentRimeSnapshot.isComposing {
            aiInputOverlay.submitPrompt()
            return true
        }
        let previousSnapshot = currentRimeSnapshot
        if !previousSnapshot.isComposing,
           let literalText = aiInputLiteralText(for: event, keyName: keyName) {
            aiInputOverlay.appendPromptText(literalText)
            return true
        }
        let shiftedKeyName = shiftedCharacterKeyName(for: event)
        let inputKeyName = shiftedKeyName ?? keyName
        let inputModifierNames = shiftedKeyName == nil
            ? modifierNames(for: event.modifierFlags)
            : []
        guard let snapshot = processRimeKey(
            inputKeyName,
            modifiers: inputModifierNames
        ) else {
            if keyName == "BackSpace", !previousSnapshot.isComposing {
                aiInputOverlay.deleteBackwardPromptText()
            }
            return true
        }
        if let shiftedKeyName, !snapshot.handled {
            aiInputOverlay.appendPromptText(shiftedKeyName)
            return true
        }
        updateAIInputOverlay(client: client, snapshot: snapshot)
        if keyName == "BackSpace",
           !previousSnapshot.isComposing,
           !snapshot.isComposing,
           snapshot.commitText.isEmpty {
            aiInputOverlay.deleteBackwardPromptText()
        }
        return true
    }

    // AI 面板只复用 Rime 的中文组字；空组合态的数字、符号、空格和大写字母按普通文本输入。
    private func aiInputLiteralText(for event: NSEvent, keyName: String) -> String? {
        let blockingModifierFlags: NSEvent.ModifierFlags = [.control, .option, .command]
        guard event.modifierFlags.intersection(blockingModifierFlags).isEmpty else {
            return nil
        }
        if keyName == "space" {
            return " "
        }
        if let shiftedKeyName = shiftedCharacterKeyName(for: event) {
            return shiftedKeyName
        }
        guard let characters = event.characters,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              CharacterSet.decimalDigits.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar) else {
            return nil
        }
        return characters
    }

    // 只读取用户当前明确选中的范围，不读取宿主正文或后台内容。
    private func selectedAIInputSelectionContext(from client: IMKTextInput) -> AIInputSelectionContext? {
        let selectedRange = client.selectedRange()
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              let attributedText = client.attributedSubstring(from: selectedRange) else {
            return nil
        }
        let selectedText = attributedText.string
        guard !selectedText.isEmpty else {
            return nil
        }
        return AIInputSelectionContext(
            selectedText: selectedText,
            replacementRange: selectedRange
        )
    }

    private var suppressNextInputTextEqualsCallback = false
    private var suppressNextKeyDownEqualsCallback = false

    // 单独等号保持为可见 marked text，使候选确认期间回车继续由输入法消费。
    private func markPendingAIInputEquals(
        client: IMKTextInput,
        fallbackAnchor: InputOverlayAnchor?
    ) {
        let markedText = NSMutableAttributedString(string: AIInputCommandState.triggerText)
        markedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: markedText.length)
        )
        client.setMarkedText(
            markedText,
            selectionRange: NSRange(location: markedText.length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        showAIInputCommandCandidate(
            client: client,
            fallbackAnchor: fallbackAnchor
        )
    }

    // 重复等号先提交上一枚 marked 等号，再按普通 Rime 符号继续处理当前按键。
    private func processStandaloneEquals(client: IMKTextInput) -> Bool {
        guard let snapshot = processRimeKey(
            AIInputCommandState.triggerText,
            modifiers: []
        ) else {
            return false
        }
        guard snapshot.handled else {
            return handleUnhandledKey(
                AIInputCommandState.triggerText,
                client: client
            )
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    private func armNextInputTextEqualsSuppression() {
        suppressNextInputTextEqualsCallback = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressNextInputTextEqualsCallback = false
        }
    }

    private func armNextKeyDownEqualsSuppression() {
        suppressNextKeyDownEqualsCallback = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressNextKeyDownEqualsCallback = false
        }
    }

    // 单独等号进入可见 marked 状态；其它按键先提交它，再继续原输入链路。
    private func handleAIInputCommandKey(
        event: NSEvent,
        keyName: String,
        client: IMKTextInput
    ) -> Bool {
        let isPlainKey = isPlainAIInputCommandKey(event)
        if isPlainKey,
           keyName == AIInputCommandState.triggerText,
           suppressNextKeyDownEqualsCallback {
            suppressNextKeyDownEqualsCallback = false
            return true
        }
        let wasPending = aiInputCommandState.isPending
        let isHandled = handleAIInputCommand(
            keyName: keyName,
            isPlainKey: isPlainKey,
            client: client
        )
        if !isHandled,
           !wasPending,
           aiInputCommandState.isPending,
           keyName == AIInputCommandState.triggerText {
            armNextInputTextEqualsSuppression()
        }
        return isHandled
    }

    // 统一处理 keyDown 和 inputText 两条 IMK 入口，确保单等号不会从另一条路径漏回宿主。
    private func handleAIInputCommand(
        keyName: String,
        isPlainKey: Bool,
        client: IMKTextInput
    ) -> Bool {
        if aiInputCommandState.isPending {
            if isPlainKey,
               keyName == AIInputCommandState.triggerText {
                discardPendingAIInputCommand(client: client)
                return false
            }
            if isPlainKey,
               (keyName == "1" || keyName == "Return") {
                if keyName == "Return" {
                    suppressNextHostReturnAfterAICommand = true
                    DispatchQueue.main.async { [weak self] in
                        self?.suppressNextHostReturnAfterAICommand = false
                    }
                }
                showAIInput(client: client)
                return true
            }
            if isPlainKey,
               keyName == "Escape" {
                discardPendingAIInputCommand(client: client)
                return true
            }
            discardPendingAIInputCommand(client: client)
            return false
        }

        guard !currentRimeSnapshot.isComposing,
              !translationDraft.hasText,
              !isSecureInputActive,
              isPlainKey,
              keyName == AIInputCommandState.triggerText,
              aiInputCommandState.activateTrigger(
                  keyName: keyName,
                  isPlainKey: isPlainKey
              ) else {
            return false
        }
        pendingAIInputSelection = nil
        return false
    }

    // 等号已经由普通输入链路写入，这里只在其上方附加 AI 候选，不修改宿主文本。
    private func showAIInputCommandCandidate(
        client: IMKTextInput,
        fallbackAnchor: InputOverlayAnchor? = nil
    ) {
        guard aiInputCommandState.isTriggerReady else {
            candidateOverlay.hide()
            return
        }
        let anchor = fallbackAnchor ??
            resolvedOverlayAnchor(client: client, allowsCachedAnchor: false)
        guard let anchor else {
            candidateOverlay.hide()
            return
        }
        candidateOverlay.showAIInputTrigger(anchor: anchor)
    }

    // AI 候选取消或输入其它按键时先提交可见等号，再清理候选状态。
    private func discardPendingAIInputCommand(client: IMKTextInput?) {
        if aiInputCommandState.isPending,
           let client {
            client.insertText(
                AIInputCommandState.triggerText,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
        }
        aiInputCommandState.reset()
        suppressNextInputTextEqualsCallback = false
        suppressNextKeyDownEqualsCallback = false
        candidateOverlay.hide()
        pendingAIInputSelection = nil
    }

    private func isPlainAIInputCommandKey(_ event: NSEvent) -> Bool {
        let commandModifierFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        return event.modifierFlags.intersection(commandModifierFlags).isEmpty
    }

    // AI 输入复用 librime 选词和翻页，但只更新面板草稿，绝不把中间文本写入宿主编辑框。
    private func updateAIInputOverlay(client: IMKTextInput, snapshot: RimeSnapshot) {
        let aiInputOverlay = ensureAIInputOverlay()
        currentRimeSnapshot = snapshot
        if !snapshot.commitText.isEmpty {
            aiInputOverlay.appendPromptText(snapshot.commitText)
        }
        aiInputOverlay.updatePromptComposition(snapshot.preeditText)
        guard snapshot.isComposing,
              let anchor = resolvedOverlayAnchor(client: client, allowsCachedAnchor: false) else {
            candidateOverlay.hide()
            return
        }
        candidateOverlay.show(snapshot: snapshot, anchor: anchor)
    }

    // 取消 AI 面板内当前拼音组合，不影响已累积的 AI 提示词或宿主正文。
    private func clearAIInputComposition() {
        let aiInputOverlay = ensureAIInputOverlay()
        rimeSession?.clearComposition()
        currentRimeSnapshot = RimeSnapshot(dictionary: rimeSession?.currentSnapshot() ?? [:])
        aiInputOverlay.updatePromptComposition(currentRimeSnapshot.preeditText)
        candidateOverlay.hide()
    }

    // 符号产生多选标点时在 UI 刷新前直接确认目标项，避免首符号或拼音后的符号拉起候选条。
    private func processRimeKey(_ keyName: String, modifiers: [String]) -> RimeSnapshot? {
        guard let rimeSession else { return nil }
        let previousSnapshot = currentRimeSnapshot
        if let pageBackward = RimeInputPolicy.candidatePageBackward(
            keyName: keyName,
            snapshot: previousSnapshot
        ) {
            return RimeSnapshot(
                dictionary: rimeSession.changePageBackward(pageBackward)
            )
        }
        var snapshot = RimeSnapshot(
            dictionary: rimeSession.processKey(keyName, modifiers: modifiers)
        )
        guard let candidateIndex = RimeInputPolicy.directSymbolCandidateIndex(
            keyName: keyName,
            previousSnapshot: previousSnapshot,
            currentSnapshot: snapshot
        ) else {
            return snapshot
        }
        let committedSnapshot = RimeSnapshot(
            dictionary: rimeSession.selectCandidate(UInt(candidateIndex))
        )
        if committedSnapshot.handled {
            snapshot = committedSnapshot
        } else {
            NSLog("TypingChao failed to commit direct symbol candidate")
        }
        return snapshot
    }

    private func keyName(for event: NSEvent) -> String? {
        // Shift-Space 必须保留为 Rime 命名键，不能被可打印空格分支降成普通字符而绕过 full_shape 绑定。
        if event.keyCode == UInt16(kVK_Space) {
            return "space"
        }
        if let characters = event.charactersIgnoringModifiers,
           characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           scalar.value >= 0x20,
           scalar.value <= 0x7e {
            return String(characters)
        }
        return keyName(for: Int(event.keyCode))
    }

    // Shift 加字母或标点使用实际字符重新交给 Rime，避免把修饰键状态误当成未修饰输入。
    private func shiftedCharacterKeyName(for event: NSEvent) -> String? {
        let blockingModifierFlags: NSEvent.ModifierFlags = [.control, .option, .command]
        guard event.modifierFlags.contains(.shift),
              event.modifierFlags.intersection(blockingModifierFlags).isEmpty,
              event.keyCode != UInt16(kVK_Space),
              let characters = event.characters,
              characters != event.charactersIgnoringModifiers,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              CharacterSet.letters.contains(scalar) ||
              CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar) else {
            return nil
        }
        return characters
    }

    private func keyName(for keyCode: Int) -> String {
        if let pagingKeyName = RimeInputPolicy.candidatePagingKeyName(
            forPhysicalKeyCode: keyCode
        ) {
            return pagingKeyName
        }
        switch keyCode {
        case 36: return "Return"
        case 76: return "Return"
        case 48: return "Tab"
        case 49: return "space"
        case 51: return "BackSpace"
        case 53: return "Escape"
        case 56: return "Shift_L"
        case 60: return "Shift_R"
        case 115: return "Home"
        case 116: return "Page_Up"
        case 117: return "Delete"
        case 119: return "End"
        case 121: return "Page_Down"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default: return "0x\(String(keyCode, radix: 16))"
        }
    }

    private func modifierNames(for flags: NSEvent.ModifierFlags) -> [String] {
        var nameList: [String] = []
        if flags.contains(.shift) { nameList.append("Shift") }
        if flags.contains(.control) { nameList.append("Control") }
        if flags.contains(.option) { nameList.append("Alt") }
        if flags.contains(.command) { nameList.append("Super") }
        if flags.contains(.capsLock) { nameList.append("CapsLock") }
        return nameList
    }

}

// 保存当前可确认译文与其对应的不可变内部草稿快照。
private struct DisplayedTranslation {
    let sourceSnapshot: TranslationSourceSnapshot
    let translatedText: String
}

final class TypingChaoInputMethodDelegate: NSObject {}
