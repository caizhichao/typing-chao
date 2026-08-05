import AppKit
import Carbon
import InputMethodKit

// 负责把 IMK 会话、完整 librime 快照、候选交互和输入法内部翻译草稿串在同一个输入会话里。
final class TypingDongnanyaInputController: IMKInputController {
    private static weak var activeOverlayController: TypingDongnanyaInputController?
    private var rimeSession: TDNRimeSession?
    private let translationService = TranslationService()
    private let translationOverlay = TranslationOverlay()
    private let candidateOverlay = CandidateOverlay()
    private let inputModeStatusOverlay = InputModeStatusOverlay()
    private var translationDraft = TranslationDraftState()
    private var translationTask: Task<Void, Never>?
    private var displayedTranslation: DisplayedTranslation?
    private let translationSessionIdentifier = UUID().uuidString
    private var isServerActive = false
    private var translationGeneration = 0
    private var currentRimeSnapshot = RimeSnapshot(dictionary: [:])
    private var overlayAnchorCache = InputOverlayAnchorCache()
    private var sessionClient: IMKTextInput?
    private var lastClient: IMKTextInput?
    private var inputMethodMenu: InputMethodMenu?

    override init(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let sharedData = Bundle.main.resourceURL?.appendingPathComponent("RimeData")
        let userData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypingDongnanya/Rime", isDirectory: true)
        if let sharedData {
            rimeSession = TDNRimeSession(
                sharedDataDirectory: sharedData.path,
                userDataDirectory: userData.path
            )
            restoreStoredRimeSettings()
        }

        candidateOverlay.setCandidateSelectionHandler { [weak self] candidateIndex in
            self?.selectCandidate(candidateIndex)
        }
        candidateOverlay.setPageHandler { [weak self] pageBackward in
            self?.changeCandidatePage(pageBackward: pageBackward)
        }
        candidateOverlay.setSettingsHandler { [weak self] in
            DispatchQueue.main.async {
                self?.showSettings()
            }
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


    // 由 InputMethodKit 在输入法菜单展开时获取当前会话状态，避免菜单缓存旧的 Rime option。
    override func menu() -> NSMenu! {
        let menuSnapshot = latestRimeSnapshot()
        let schemaList = rimeSession?.schemaList() ?? []
        let rimeSchemaList = schemaList.map { RimeSchemaItem(dictionary: $0) }
        if let inputMethodMenu {
            return inputMethodMenu.makeMenu(snapshot: menuSnapshot, schemaList: rimeSchemaList)
        }
        return NSMenu(title: "Typing 东南亚")
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // 激活时只绑定当前 IMK 会话，不启动跨进程正文或全局键盘监听。
        isServerActive = true
        if let activeController = Self.activeOverlayController,
           activeController !== self {
            activeController.resetForExternalActivation()
        }
        Self.activeOverlayController = self
        resetTranslationContext()
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
        // 输入源切出前先上屏原文，避免输入法持有的 marked draft 因会话结束而丢失。
        isServerActive = false
        commitOriginalTranslationDraft()
        resetTranslationContext()
        rimeSession?.clearComposition()
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        if Self.activeOverlayController === self {
            Self.activeOverlayController = nil
        }
        overlayAnchorCache.reset()
        lastClient = nil
        super.deactivateServer(sender)
    }

    // 隐藏面板只隐藏当前浮层，不结束仍由 marked text 持有的翻译草稿。
    override func hidePalettes() {
        cancelTranslationPresentationPreservingDraft()
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        super.hidePalettes()
    }

    // 输入会话销毁时取消所有网络和宿主变更观察任务，避免客户端代理被异步任务继续持有。
    override func inputControllerWillClose() {
        isServerActive = false
        if Self.activeOverlayController === self {
            Self.activeOverlayController = nil
        }
        commitOriginalTranslationDraft()
        resetTranslationContext()
        inputModeStatusOverlay.hide()
        overlayAnchorCache.reset()
        sessionClient = nil
        lastClient = nil
        super.inputControllerWillClose()
    }

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

    // 键盘入口优先保留系统 Command 快捷键，只把确认可交给 Rime 的按键写入引擎。
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        guard let client = sender as? IMKTextInput else { return false }
        prepareClient(client)

        if event.type != .keyDown {
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

        if event.modifierFlags.contains([.control, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "t" {
            return activateClipboardTranslationDraft(client: client, userInitiated: true)
        }
        let controlKeyName = keyName(for: event) ?? ""
        if event.modifierFlags.contains(.control),
           !TranslationPolicy.controlShortcutUsesRime(controlKeyName) {
            commitOriginalTranslationDraft()
            candidateOverlay.hide()
            return false
        }
        if event.modifierFlags.contains(.command) {
            let commandKeyName = keyName(for: event) ?? ""
            if TranslationPolicy.commandRequestsClipboardTranslation(commandKeyName) {
                return activateClipboardTranslationDraft(client: client, userInitiated: false)
            }
            commitOriginalTranslationDraft()
            candidateOverlay.hide()
            return false
        }

        guard let keyName = keyName(for: event) else { return false }
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

    // 文本输入入口只把单个 ASCII 键交给 Rime；多字符回调仅在匹配剪贴板时触发翻译。
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, let client = sender as? IMKTextInput else { return false }
        prepareClient(client)
        if string == "\u{1b}" {
            return clearInputCache(client: client)
        }
        guard let keyName = TranslationPolicy.rimeKeyName(for: string) else {
            let didActivateClipboardDraft = activateClipboardTranslationDraft(
                client: client,
                expectedText: string,
                userInitiated: false
            )
            candidateOverlay.hide()
            return didActivateClipboardDraft
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
        guard let snapshot = processRimeKey(keyName, modifiers: []) else {
            return false
        }
        guard snapshot.handled else {
            return handleUnhandledKey(keyName, client: client)
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    // 带键码文本入口保留宿主快捷键，只在收到 Command-V 或匹配剪贴板的多字符文本时翻译。
    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let string, let client = sender as? IMKTextInput else { return false }
        prepareClient(client)
        let modifierFlagSet = NSEvent.ModifierFlags(rawValue: UInt(flags))
        let textKeyName = TranslationPolicy.rimeKeyName(for: string)
        let resolvedKeyName = textKeyName ?? keyName(for: keyCode)
        if modifierFlagSet.contains([.control, .shift]),
           resolvedKeyName.lowercased() == "t" {
            return activateClipboardTranslationDraft(client: client, userInitiated: true)
        }
        if modifierFlagSet.contains(.control),
           !TranslationPolicy.controlShortcutUsesRime(resolvedKeyName) {
            commitOriginalTranslationDraft()
            candidateOverlay.hide()
            return false
        }
        if modifierFlagSet.contains(.command) {
            if TranslationPolicy.commandRequestsClipboardTranslation(resolvedKeyName) {
                return activateClipboardTranslationDraft(client: client, userInitiated: false)
            }
            commitOriginalTranslationDraft()
            candidateOverlay.hide()
            return false
        }
        if resolvedKeyName == "Escape" {
            return clearInputCache(client: client)
        }
        if textKeyName == nil, !string.isEmpty {
            let didActivateClipboardDraft = activateClipboardTranslationDraft(
                client: client,
                expectedText: string,
                userInitiated: false
            )
            candidateOverlay.hide()
            return didActivateClipboardDraft
        }
        let modifierNameList = modifierNames(for: flags)
        if handleTranslationDraftEditingKey(resolvedKeyName, client: client) {
            return true
        }
        if TranslationPolicy.shouldPassThroughHostEditingKey(
            keyName: resolvedKeyName,
            isComposing: currentRimeSnapshot.isComposing
        ) {
            resetTranslationContext()
            candidateOverlay.hide()
            return false
        }
        guard let snapshot = processRimeKey(resolvedKeyName, modifiers: modifierNameList) else {
            return false
        }
        guard snapshot.handled else {
            return handleUnhandledKey(resolvedKeyName, client: client)
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    // 外部要求结束组字时先收口 librime，再把完整内部草稿作为原文一次性提交宿主。
    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else {
            super.commitComposition(sender)
            return
        }
        prepareClient(client)
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
            "TypingDongnanya scheduled translation generation %d, source: %@, characters: %d",
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
                NSLog("TypingDongnanya skipped translation generation %d before request", requestGeneration)
                return
            }

            NSLog(
                "TypingDongnanya starting translation generation %d, characters: %d",
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
                        NSLog("TypingDongnanya translation completed without a valid overlay anchor")
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
                    NSLog("TypingDongnanya displayed translation generation %d", requestGeneration)
                }
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("TypingDongnanya translation error: %@", error.localizedDescription)
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
                        NSLog("TypingDongnanya translation error cannot be shown without a valid overlay anchor")
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
            NSLog("TypingDongnanya ignored translation action without an active draft result")
            translationOverlay.hide()
            return
        }
        guard translationDraft.resolvedSnapshot(
            clientIdentifier: currentTranslationSessionIdentifier(),
            fallbackSnapshot: displayedTranslation.sourceSnapshot
        ) != nil else {
            NSLog("TypingDongnanya rejected translation action because the marked draft changed")
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
            "TypingDongnanya committed translated draft, source characters: %d",
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
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
        let schemaList = (rimeSession?.schemaList() ?? []).map { RimeSchemaItem(dictionary: $0) }
        TypingDongnanyaApplicationDelegate.shared.showSettings(
            inputController: self,
            snapshot: latestRimeSnapshot(),
            schemaList: schemaList
        )
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
        guard let rimeSession, let lastClient else { return }
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.selectCandidate(UInt(candidateIndex))
        )
        guard snapshot.handled else { return }
        updateClient(lastClient, snapshot: snapshot)
    }

    // 翻页动作由 librime 决定是否可执行，成功后用返回页的标签和注释整体刷新候选壳。
    private func changeCandidatePage(pageBackward: Bool) {
        guard let rimeSession, let lastClient else { return }
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.changePageBackward(pageBackward)
        )
        guard snapshot.handled else { return }
        updateClient(lastClient, snapshot: snapshot)
    }

    // 同一控制器内 IMK 客户端代理可能逐次变化，只更新当前代理，不据此清空整句草稿。
    private func prepareClient(_ client: IMKTextInput) {
        if let activeController = Self.activeOverlayController,
           activeController !== self {
            activeController.resetForExternalActivation()
        }
        Self.activeOverlayController = self
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
        commitOriginalTranslationDraft()
        resetTranslationContext()
        rimeSession?.clearComposition()
        candidateOverlay.hide()
        inputModeStatusOverlay.hide()
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
            "TypingDongnanya committed original translation draft, characters: %d",
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
            NSLog("TypingDongnanya failed to commit direct symbol candidate")
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

    private func modifierNames(for flags: Int) -> [String] {
        modifierNames(for: NSEvent.ModifierFlags(rawValue: UInt(flags)))
    }
}

// 保存当前可确认译文与其对应的不可变内部草稿快照。
private struct DisplayedTranslation {
    let sourceSnapshot: TranslationSourceSnapshot
    let translatedText: String
}

final class TypingDongnanyaInputMethodDelegate: NSObject {}
