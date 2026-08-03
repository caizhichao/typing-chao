import AppKit
import Carbon
import InputMethodKit

// 负责把 IMK 会话、完整 librime 快照、候选交互和稳定原文翻译串在同一个输入会话里。
final class TypingDongnanyaInputController: IMKInputController {
    private static weak var activeOverlayController: TypingDongnanyaInputController?
    private var rimeSession: TDNRimeSession?
    private let translationService = TranslationService()
    private let translationOverlay = TranslationOverlay()
    private let candidateOverlay = CandidateOverlay()
    private var translationDraft = TranslationDraftState()
    private var translationTask: Task<Void, Never>?
    private var translationGeneration = 0
    private var displayedTranslation: DisplayedTranslation?
    private var currentRimeSnapshot = RimeSnapshot(dictionary: [:])
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
        translationOverlay.setTranslationSelectionHandler { [weak self] in
            self?.replaceSourceTextWithTranslation()
        }
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
        // 激活回调的 sender 不是可靠的文本客户端，当前客户端必须由输入事件重新绑定。
        resetTranslationContext()
        rimeSession?.clearComposition()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        candidateOverlay.hide()
        lastClient = nil
    }

    override func deactivateServer(_ sender: Any!) {
        // 输入源切出时清空组合态和浮层，避免旧会话在其它输入法激活后继续显示。
        resetTranslationContext()
        rimeSession?.clearComposition()
        candidateOverlay.hide()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        if Self.activeOverlayController === self {
            Self.activeOverlayController = nil
        }
        lastClient = nil
        super.deactivateServer(sender)
    }

    // 系统要求隐藏输入法面板时同时收口候选与异步译文，避免孤立浮窗残留在其它应用。
    override func hidePalettes() {
        resetTranslationContext()
        rimeSession?.clearComposition()
        candidateOverlay.hide()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        if Self.activeOverlayController === self {
            Self.activeOverlayController = nil
        }
        super.hidePalettes()
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    // 键盘入口优先保留系统 Command 快捷键，只把确认可交给 Rime 的按键写入引擎。
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        guard event.type == .keyDown else { return false }
        guard let client = sender as? IMKTextInput else { return false }
        prepareClient(client)

        if event.modifierFlags.contains([.control, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "t" {
            guard isRemoteTranslationAllowed else {
                return false
            }
            scheduleCurrentTranslation(userInitiated: true)
            return true
        }
        if event.modifierFlags.contains(.command) {
            resetTranslationContext()
            candidateOverlay.hide()
            return false
        }

        guard let keyName = keyName(for: event) else { return false }
        let modifierNameList = modifierNames(for: event.modifierFlags)
        guard let rimeSession else { return false }
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.processKey(keyName, modifiers: modifierNameList)
        )
        guard snapshot.handled else {
            handleUnhandledKey(keyName)
            return false
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    // 文本输入入口沿用同一 Rime 快照更新链，避免系统走不同回调时丢失候选和翻译状态。
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, let client = sender as? IMKTextInput else { return false }
        prepareClient(client)
        guard let keyName = printableRimeKeyName(for: string) else {
            handleUnhandledKey(string)
            return false
        }
        guard let rimeSession else { return false }
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.processKey(keyName, modifiers: [])
        )
        guard snapshot.handled else {
            handleUnhandledKey(keyName)
            return false
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    // 带键码文本入口只负责解析系统键码，后续状态仍走统一的 updateClient 主链路。
    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard let string, let client = sender as? IMKTextInput else { return false }
        prepareClient(client)
        guard let rimeSession else { return false }
        let modifierNameList = modifierNames(for: flags)
        let resolvedKeyName = printableRimeKeyName(for: string) ?? keyName(for: keyCode)
        let snapshot = RimeSnapshot(
            dictionary: rimeSession.processKey(resolvedKeyName, modifiers: modifierNameList)
        )
        guard snapshot.handled else {
            handleUnhandledKey(resolvedKeyName)
            return false
        }
        updateClient(client, snapshot: snapshot)
        return true
    }

    // 外部要求结束组字时提交 librime 已生成文本，并把该文本纳入同一翻译草稿。
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
                client.insertText(
                    snapshot.commitText,
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                handleCommittedText(snapshot.commitText, client: client)
                rimeSession.clearComposition()
                candidateOverlay.hide()
                return
            }
        }
        super.commitComposition(sender)
    }

    // 完整快照是 marked text、候选壳与提交文本的唯一状态来源，避免各层自行推断分页和光标。
    private func updateClient(_ client: IMKTextInput, snapshot: RimeSnapshot) {
        let wasComposing = currentRimeSnapshot.isComposing
        currentRimeSnapshot = snapshot
        if snapshot.isComposing {
            postponeTranslationUntilCompositionSettles()
        }
        if !snapshot.commitText.isEmpty {
            client.insertText(
                snapshot.commitText,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            handleCommittedText(
                snapshot.commitText,
                client: client,
                shouldScheduleTranslation: !snapshot.isComposing
            )
        }

        guard snapshot.isComposing else {
            client.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            candidateOverlay.hide()
            if wasComposing, snapshot.commitText.isEmpty {
                scheduleCurrentTranslation(userInitiated: false)
            }
            return
        }

        let markedText = markedText(for: snapshot)
        var markedSelectionRange = NSRange(location: snapshot.caretOffset, length: 0)
        if snapshot.selectionRange.length > 0 {
            markedSelectionRange = snapshot.selectionRange
        }
        client.setMarkedText(
            markedText,
            selectionRange: markedSelectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        guard let anchor = InputOverlayAnchor(client: client) else {
            candidateOverlay.hide()
            translationOverlay.hide()
            return
        }
        candidateOverlay.show(snapshot: snapshot, anchor: anchor)
        translationOverlay.updatePosition(anchor: anchor, candidateFrame: candidateOverlay.visibleFrame)
    }

    // marked text 只补充组合范围和当前选中码段，不在客户端重复绘制候选文本。
    private func markedText(for snapshot: RimeSnapshot) -> NSAttributedString {
        let markedText = NSMutableAttributedString(string: snapshot.preeditText)
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
        if snapshot.selectionRange.length > 0,
           NSMaxRange(snapshot.selectionRange) <= markedText.length {
            markedText.addAttribute(
                .backgroundColor,
                value: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 0.18),
                range: snapshot.selectionRange
            )
        }
        return markedText
    }

    // 每次 Rime commit 都先进入稳定缓冲，只有组合态结束后才开始计算一秒稳定期。
    private func handleCommittedText(
        _ committedText: String,
        client: IMKTextInput,
        shouldScheduleTranslation: Bool = true
    ) {
        guard InputMethodSettings.shared.isTranslationEnabled else {
            resetTranslationContext()
            return
        }
        guard !isSecureInputActive else {
            resetTranslationContext()
            return
        }
        guard let sourceSnapshot = translationDraft.appendCommittedText(committedText, client: client) else {
            return
        }
        let sentenceFinished = committedText.rangeOfCharacter(
            from: TranslationPolicy.sentenceBoundaryCharacters
        ) != nil || committedText.rangeOfCharacter(from: .newlines) != nil
        if shouldScheduleTranslation {
            scheduleTranslation(
                fallbackSnapshot: sourceSnapshot,
                client: client,
                userInitiated: false
            )
        }
        if sentenceFinished {
            translationDraft.startNextSentence()
        }
    }

    // 手动翻译快捷键使用当前稳定草稿，不读取候选中的未提交拼音。
    private func scheduleCurrentTranslation(userInitiated: Bool) {
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

    // 每个请求固定原文、请求代次与提交时锚点；自动请求必须等输入稳定一秒。
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
        let scheduledAnchor = InputOverlayAnchor(client: client)
        translationTask?.cancel()
        displayedTranslation = nil
        translationOverlay.hide()
        translationTask = Task { [weak self] in
            guard let self else { return }
            var delayMilliseconds = TranslationPolicy.stableInputDelayMilliseconds
            if userInitiated {
                delayMilliseconds = TranslationPolicy.userInitiatedDelayMilliseconds
            }
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled else { return }

            let sourceSnapshot = await MainActor.run {
                self.translationDraft.resolvedSnapshot(
                    client: client,
                    fallbackSnapshot: fallbackSnapshot
                )
            }
            guard !sourceSnapshot.sourceText.isEmpty else {
                return
            }
            let requestCanStart = await MainActor.run {
                guard self.translationGeneration == requestGeneration,
                      self.isRemoteTranslationAllowed,
                      self.isActiveOverlayController,
                      !self.currentRimeSnapshot.isComposing,
                      self.clientMatches(sourceSnapshot.clientIdentifier) else {
                    return false
                }
                if TranslationPolicy.shouldRestartStableDelay(
                    scheduledSourceText: fallbackSnapshot.sourceText,
                    resolvedSourceText: sourceSnapshot.sourceText,
                    userInitiated: userInitiated
                ) {
                    self.scheduleTranslation(
                        fallbackSnapshot: sourceSnapshot,
                        client: client,
                        userInitiated: false
                    )
                    return false
                }
                return true
            }
            guard requestCanStart else {
                return
            }

            do {
                let translatedText = try await self.translationService.translate(sourceSnapshot.sourceText)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.translationGeneration == requestGeneration,
                          self.isRemoteTranslationAllowed,
                          self.isActiveOverlayController,
                          !self.currentRimeSnapshot.isComposing,
                          self.clientMatches(sourceSnapshot.clientIdentifier),
                          let currentSourceSnapshot = self.currentTranslationSnapshot(
                              fallbackSnapshot: sourceSnapshot
                          ) else {
                        return
                    }
                    if currentSourceSnapshot.sourceText != sourceSnapshot.sourceText {
                        guard let lastClient = self.lastClient else { return }
                        self.scheduleTranslation(
                            fallbackSnapshot: currentSourceSnapshot,
                            client: lastClient,
                            userInitiated: false
                        )
                        return
                    }
                    let anchor = InputOverlayAnchor(client: self.lastClient) ?? scheduledAnchor
                    var replacementRange: NSRange?
                    if currentSourceSnapshot.canReplaceSource {
                        replacementRange = currentSourceSnapshot.replacementRange
                    }
                    self.displayedTranslation = DisplayedTranslation(
                        sourceText: currentSourceSnapshot.sourceText,
                        translatedText: translatedText,
                        replacementRange: replacementRange,
                        clientIdentifier: currentSourceSnapshot.clientIdentifier
                    )
                    guard let anchor else {
                        NSLog("TypingDongnanya translation completed without a valid overlay anchor")
                        return
                    }
                    self.translationOverlay.showTranslation(
                        translatedText: translatedText,
                        languagePair: self.translationService.languagePairTitle,
                        replacementEnabled: currentSourceSnapshot.canReplaceSource,
                        anchor: anchor,
                        candidateFrame: self.candidateOverlay.visibleFrame
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("TypingDongnanya translation error: %@", error.localizedDescription)
                await MainActor.run {
                    guard self.translationGeneration == requestGeneration,
                          self.isRemoteTranslationAllowed,
                          self.isActiveOverlayController,
                          !self.currentRimeSnapshot.isComposing,
                          self.clientMatches(sourceSnapshot.clientIdentifier),
                          let currentSourceSnapshot = self.currentTranslationSnapshot(
                              fallbackSnapshot: sourceSnapshot
                          ) else {
                        return
                    }
                    if currentSourceSnapshot.sourceText != sourceSnapshot.sourceText {
                        guard let lastClient = self.lastClient else { return }
                        self.scheduleTranslation(
                            fallbackSnapshot: currentSourceSnapshot,
                            client: lastClient,
                            userInitiated: false
                        )
                        return
                    }
                    guard let anchor = InputOverlayAnchor(client: self.lastClient) ?? scheduledAnchor else {
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

    // 返回结果必须重新绑定当前文档快照，源文本变化时废弃旧结果并为最终文本重新计时。
    private func currentTranslationSnapshot(
        fallbackSnapshot: TranslationSourceSnapshot
    ) -> TranslationSourceSnapshot? {
        guard let lastClient,
              clientMatches(fallbackSnapshot.clientIdentifier) else {
            return nil
        }
        return translationDraft.resolvedSnapshot(
            client: lastClient,
            fallbackSnapshot: fallbackSnapshot
        )
    }

    // 点击替换前必须再次核对客户端、光标和原文正文，任何变化都只降为可阅读译文。
    private func replaceSourceTextWithTranslation() {
        guard let displayedTranslation, let lastClient else {
            translationOverlay.hide()
            return
        }
        guard let replacementRange = displayedTranslation.replacementRange else {
            showStaleTranslation(displayedTranslation, client: lastClient)
            return
        }

        let currentClientIdentifier = ObjectIdentifier(lastClient as AnyObject)
        let selectedRange = lastClient.selectedRange()
        let expectedSelectionLocation = NSMaxRange(replacementRange)
        let currentSourceText = lastClient.attributedSubstring(from: replacementRange)?.string
        guard currentClientIdentifier == displayedTranslation.clientIdentifier,
              selectedRange.location == expectedSelectionLocation,
              selectedRange.length == 0,
              currentSourceText == displayedTranslation.sourceText else {
            showStaleTranslation(displayedTranslation, client: lastClient)
            return
        }

        translationGeneration += 1
        translationTask?.cancel()
        lastClient.insertText(
            displayedTranslation.translatedText,
            replacementRange: replacementRange
        )
        translationDraft.reset()
        self.displayedTranslation = nil
        translationOverlay.hide()
    }

    // 原文变化后保留译文用于阅读，但立即清除可写入状态，不能继续使用旧范围覆盖文本。
    private func showStaleTranslation(_ translation: DisplayedTranslation, client: IMKTextInput) {
        displayedTranslation = nil
        guard let anchor = InputOverlayAnchor(client: client) else {
            translationOverlay.hide()
            return
        }
        translationOverlay.showStale(
            translatedText: translation.translatedText,
            languagePair: translationService.languagePairTitle,
            anchor: anchor,
            candidateFrame: candidateOverlay.visibleFrame
        )
    }

    // 菜单切换 Rime 状态前先取消旧草稿，避免新字形或输入模式沿用旧句的可替换译文。
    func applyRimeOptionStateList(_ optionStateList: [RimeOptionState]) {
        guard let rimeSession, !optionStateList.isEmpty else {
            return
        }
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

    // 输入方案选择只切换当前 librime 会话，绝不选择或改变 macOS 当前系统输入源。
    func selectRimeSchema(_ schemaIdentifier: String) {
        guard let rimeSession, !schemaIdentifier.isEmpty else {
            return
        }
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
        InputMethodSettings.shared.setTranslationEnabled(enabled)
        resetTranslationContext()
    }

    // 目标语言改变后取消旧请求，下一段稳定文本必须按新语言重新翻译。
    func setTranslationTargetLanguage(_ targetLanguage: TranslationTargetLanguage) {
        InputMethodSettings.shared.setTargetLanguage(targetLanguage)
        resetTranslationContext()
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
        currentRimeSnapshot = snapshot
        guard let lastClient else {
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

    // 进程内只允许当前实际输入会话保留浮层，切换编辑器时先关闭旧控制器的窗口和异步状态。
    private func prepareClient(_ client: IMKTextInput) {
        if let activeController = Self.activeOverlayController,
           activeController !== self {
            activeController.resetForExternalActivation()
        }
        Self.activeOverlayController = self
        let nextClientIdentifier = ObjectIdentifier(client as AnyObject)
        if let lastClient {
            let currentClientIdentifier = ObjectIdentifier(lastClient as AnyObject)
            if currentClientIdentifier != nextClientIdentifier {
                resetTranslationContext()
                candidateOverlay.hide()
            }
        }
        lastClient = client
    }

    private func clientMatches(_ clientIdentifier: ObjectIdentifier) -> Bool {
        guard let lastClient else { return false }
        return ObjectIdentifier(lastClient as AnyObject) == clientIdentifier
    }

    private var isActiveOverlayController: Bool {
        Self.activeOverlayController === self
    }

    // 系统启用安全事件输入时禁止把已提交文本交给远程翻译服务。
    private var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
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
        resetTranslationContext()
        rimeSession?.clearComposition()
        candidateOverlay.hide()
        currentRimeSnapshot = RimeSnapshot(dictionary: [:])
        lastClient = nil
    }

    // 组合码仍在编辑时只取消旧请求和旧译文，不清空已经提交的整句草稿。
    private func postponeTranslationUntilCompositionSettles() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        displayedTranslation = nil
        translationOverlay.hide()
    }

    // 未被 Rime 接管的按键可能由宿主直接改写文本，因此统一结束旧草稿和替换范围。
    private func handleUnhandledKey(_ keyName: String) {
        if keyName == "Shift_L" || keyName == "Shift_R" {
            return
        }
        resetTranslationContext()
        candidateOverlay.hide()
    }

    // 输入会话、发送动作或上下文切换后统一取消旧请求并清空可点击替换状态。
    private func resetTranslationContext() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translationDraft.reset()
        displayedTranslation = nil
        translationOverlay.hide()
    }

    // 文本回调只把单个 ASCII 可打印键交给 Rime，多字符粘贴和直接文本必须保留给宿主。
    private func printableRimeKeyName(for textValue: String) -> String? {
        guard textValue.utf8.count == 1,
              let scalarValue = textValue.unicodeScalars.first?.value,
              scalarValue >= 0x20,
              scalarValue <= 0x7e else {
            return nil
        }
        return textValue
    }

    private func keyName(for event: NSEvent) -> String? {
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
        switch keyCode {
        case 36: return "Return"
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

// 保存已经展示给用户的译文及其原始文档事务边界，点击时不再读取可变草稿状态。
private struct DisplayedTranslation {
    let sourceText: String
    let translatedText: String
    let replacementRange: NSRange?
    let clientIdentifier: ObjectIdentifier
}

final class TypingDongnanyaInputMethodDelegate: NSObject {}
