import AppKit

// 提供连续对话 AI 输入面板：面板拥有独立第一响应者，但按键仍复用当前 IMK 会话。
final class AIInputOverlay {
    private static let panelSize = NSSize(width: 520, height: 500)
    private let panel: AIInputOverlayPanel
    private let contentView: AIInputOverlayContentView
    private var requestHandler: ((String, [AIConversationMessage]) -> Void)?
    private var commitHandler: ((String) -> Void)?
    private var serviceProviderHandler: ((AIServiceProvider) -> Void)?

    init() {
        let contentView = AIInputOverlayContentView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let panel = AIInputOverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.contentView = contentView
        panel.contentView = contentView
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        contentView.requestHandler = { [weak self] promptText, conversationMessageList in
            self?.requestHandler?(promptText, conversationMessageList)
        }
        contentView.commitHandler = { [weak self] resultText in
            self?.commitHandler?(resultText)
        }
        contentView.serviceProviderHandler = { [weak self] serviceProvider in
            self?.serviceProviderHandler?(serviceProvider)
        }
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var acceptsPromptInput: Bool {
        contentView.acceptsPromptInput
    }

    // 上次请求已返回结果时允许用 Command-Return 上屏，避免必须回到鼠标按钮。
    var canCommitResult: Bool {
        contentView.canCommitResult
    }

    func setRequestHandler(_ handler: @escaping (String, [AIConversationMessage]) -> Void) {
        requestHandler = handler
    }

    func setCommitHandler(_ handler: @escaping (String) -> Void) {
        commitHandler = handler
    }

    func setServiceProviderHandler(_ handler: @escaping (AIServiceProvider) -> Void) {
        serviceProviderHandler = handler
    }

    func setKeyHandler(_ handler: @escaping (NSEvent) -> Bool) {
        contentView.setKeyHandler(handler)
    }

    // 用户主动触发 AI 输入时让面板输入区获得焦点，并预填用户明确选中的原文。
    func show(anchor: InputOverlayAnchor?, prefilledPromptText: String = "") {
        contentView.reset()
        if !prefilledPromptText.isEmpty {
            contentView.appendPromptText(prefilledPromptText)
        }
        panel.setContentSize(Self.panelSize)
        if let anchor {
            panel.setFrameOrigin(anchor.translationOrigin(for: Self.panelSize, candidateFrame: nil))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        contentView.focusPromptInput()
    }

    func appendPromptText(_ textValue: String) {
        contentView.appendPromptText(textValue)
    }

    func deleteBackwardPromptText() {
        contentView.deleteBackwardPromptText()
    }

    func updatePromptComposition(_ textValue: String) {
        contentView.updatePromptComposition(textValue)
    }

    func submitPrompt() {
        contentView.submitPrompt()
    }

    // 键盘快捷键与结果按钮共用同一提交入口。
    func commitResult() {
        contentView.commitResult()
    }

    func showLoading() {
        contentView.showLoading()
    }

    func showResult(_ resultText: String) {
        contentView.showResult(resultText)
    }

    func showError(_ messageText: String) {
        contentView.showError(messageText)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// 面板只承载 AI 输入第一响应者，不创建新的 InputMethodKit 会话。
final class AIInputOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

// 使用普通 NSView 接收面板按键，避免 NSTextView 再建立一套系统输入法文本会话。
final class AIInputPromptView: NSView {
    var keyHandler: ((NSEvent) -> Bool)?

    private var displayedText = NSAttributedString()
    private var isInputEnabled = true

    override var acceptsFirstResponder: Bool {
        true
    }

    func setDisplayedText(_ text: NSAttributedString, isInputEnabled: Bool) {
        displayedText = text
        self.isInputEnabled = isInputEnabled
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        _ = keyHandler?(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyHandler?(event) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let text = displayedText.length > 0
            ? displayedText
            : NSAttributedString(
                string: "输入你想让 AI 处理的内容",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 0.82),
                ]
            )
        let textStorage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: max(0, bounds.width),
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let drawingOrigin = NSPoint(
            x: 0,
            y: max(0, floor((bounds.height - usedRect.height) / 2 - usedRect.minY))
        )
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: drawingOrigin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: drawingOrigin)

        guard window?.firstResponder === self, isInputEnabled else {
            return
        }
        drawCaret(
            layoutManager: layoutManager,
            textContainer: textContainer,
            drawingOrigin: drawingOrigin
        )
    }

    private func drawCaret(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        drawingOrigin: NSPoint
    ) {
        guard layoutManager.numberOfGlyphs > 0 else { return }
        let isPlaceholder = displayedText.length == 0
        let glyphIndex = isPlaceholder
            ? 0
            : layoutManager.glyphIndexForCharacter(at: max(0, displayedText.length - 1))
        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
        let caretX = isPlaceholder ? 0 : glyphRect.maxX
        let caretRect = NSRect(
            x: drawingOrigin.x + caretX,
            y: drawingOrigin.y + lineRect.minY,
            width: 1.5,
            height: lineRect.height
        )
        NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 0.95).setFill()
        caretRect.fill()
    }
}

// AI 面板展示当前会话消息记录，服务端不保存输入，客户端每次请求显式携带本地历史。
private final class AIInputOverlayContentView: NSView {
    var requestHandler: ((String, [AIConversationMessage]) -> Void)?
    var commitHandler: ((String) -> Void)?
    var serviceProviderHandler: ((AIServiceProvider) -> Void)?
    private let promptInputView = AIInputPromptView(frame: .zero)

    private var promptText = ""
    private var promptComposition = ""
    private var pendingPromptText = ""
    private var conversationMessageList: [AIConversationMessage] = []
    private var isPromptInputEnabled = true
    private var hasResult = false
    private var currentResultText = ""
    private let promptContainer = NSView(frame: .zero)
    private let chatContainer = NSView(frame: .zero)
    private let chatTextView = NSTextView(frame: .zero)
    private let chatScrollView = NSScrollView(frame: .zero)
    private let serviceProviderPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commitButton = NSButton(title: "上屏结果", target: nil, action: nil)

    var acceptsPromptInput: Bool {
        isPromptInputEnabled
    }

    var canCommitResult: Bool {
        hasResult && !currentResultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        promptText = ""
        promptComposition = ""
        pendingPromptText = ""
        conversationMessageList = []
        isPromptInputEnabled = true
        hasResult = false
        currentResultText = ""
        updatePromptDisplay()
        selectServiceProvider(InputMethodSettings.shared.aiServiceProvider)
        chatTextView.string = "输入消息后，AI 回复会显示在这里"
        chatTextView.textColor = NSColor(calibratedWhite: 0.42, alpha: 0.82)
        commitButton.isHidden = true
        updatePromptInputAppearance()
    }

    func setKeyHandler(_ handler: @escaping (NSEvent) -> Bool) {
        promptInputView.keyHandler = handler
    }

    func focusPromptInput() {
        guard isPromptInputEnabled else { return }
        window?.makeFirstResponder(promptInputView)
        promptInputView.needsDisplay = true
    }

    func appendPromptText(_ textValue: String) {
        guard isPromptInputEnabled, !textValue.isEmpty else { return }
        promptText += textValue
        promptComposition = ""
        updatePromptDisplay()
    }

    func deleteBackwardPromptText() {
        guard isPromptInputEnabled, !promptText.isEmpty else { return }
        let lastRange = promptText.rangeOfComposedCharacterSequence(at: promptText.index(before: promptText.endIndex))
        promptText.removeSubrange(lastRange)
        updatePromptDisplay()
    }

    func updatePromptComposition(_ textValue: String) {
        guard isPromptInputEnabled else { return }
        promptComposition = textValue
        updatePromptDisplay()
    }

    func submitPrompt() {
        guard isPromptInputEnabled else { return }
        let textValue = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textValue.isEmpty else {
            chatTextView.string = "请输入内容后再发送"
            chatTextView.textColor = NSColor(calibratedWhite: 0.42, alpha: 0.82)
            return
        }
        pendingPromptText = textValue
        promptText = ""
        promptComposition = ""
        updatePromptDisplay()
        requestHandler?(textValue, conversationMessageList)
    }

    func showLoading() {
        isPromptInputEnabled = false
        updatePromptDisplay()
        updatePromptInputAppearance()
        hasResult = false
        currentResultText = ""
        renderChatTranscript(
            pendingAssistantText: "正在生成…",
            pendingAssistantTextColor: NSColor(calibratedWhite: 0.42, alpha: 0.82)
        )
        commitButton.isHidden = true
    }

    func showResult(_ resultText: String) {
        isPromptInputEnabled = true
        updatePromptDisplay()
        updatePromptInputAppearance()
        hasResult = true
        currentResultText = resultText
        conversationMessageList.append(
            AIConversationMessage(roleName: "user", contentText: pendingPromptText)
        )
        conversationMessageList.append(
            AIConversationMessage(roleName: "assistant", contentText: resultText)
        )
        pendingPromptText = ""
        renderChatTranscript()
        commitButton.isHidden = false
    }

    func showError(_ messageText: String) {
        isPromptInputEnabled = true
        updatePromptDisplay()
        updatePromptInputAppearance()
        hasResult = false
        currentResultText = ""
        renderChatTranscript(
            pendingAssistantText: messageText,
            pendingAssistantTextColor: NSColor(calibratedRed: 0.78, green: 0.18, blue: 0.12, alpha: 0.92)
        )
        commitButton.isHidden = true
    }

    @objc private func commitAIInput() {
        commitResult()
    }

    // 只有真实返回结果才允许上屏，避免把占位文案或错误文案写入宿主。
    func commitResult() {
        guard canCommitResult else { return }
        let resultText = currentResultText.trimmingCharacters(in: .whitespacesAndNewlines)
        commitHandler?(resultText)
    }

    @objc private func changeServiceProvider(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let serviceProvider = AIServiceProvider(rawValue: rawValue) else {
            return
        }
        serviceProviderHandler?(serviceProvider)
    }

    private func updatePromptDisplay() {
        let textValue = promptText + promptComposition
        guard !textValue.isEmpty else {
            promptInputView.setDisplayedText(
                NSAttributedString(),
                isInputEnabled: isPromptInputEnabled
            )
            return
        }
        let attributedText = NSMutableAttributedString(
            string: textValue,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 0.94),
            ]
        )
        if !promptComposition.isEmpty {
            let compositionRange = NSRange(
                location: promptText.utf16.count,
                length: promptComposition.utf16.count
            )
            attributedText.addAttributes([
                .foregroundColor: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: compositionRange)
        }
        promptInputView.setDisplayedText(
            attributedText,
            isInputEnabled: isPromptInputEnabled
        )
    }

    // 当前面板只清空已提交的输入框，已完成的对话和正在处理的消息继续保留在滚动区。
    private func renderChatTranscript(
        pendingAssistantText: String? = nil,
        pendingAssistantTextColor: NSColor? = nil
    ) {
        let transcript = NSMutableAttributedString()
        for message in conversationMessageList {
            let isUserMessage = message.roleName == "user"
            appendChatMessage(
                roleText: isUserMessage ? "你" : "AI",
                messageText: message.contentText,
                roleColor: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1),
                messageColor: isUserMessage
                    ? NSColor(calibratedWhite: 0.14, alpha: 0.94)
                    : NSColor(calibratedWhite: 0.16, alpha: 0.94),
                to: transcript
            )
        }
        if !pendingPromptText.isEmpty {
            appendChatMessage(
                roleText: "你",
                messageText: pendingPromptText,
                roleColor: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1),
                messageColor: NSColor(calibratedWhite: 0.14, alpha: 0.94),
                to: transcript
            )
        }
        if let pendingAssistantText {
            appendChatMessage(
                roleText: "AI",
                messageText: pendingAssistantText,
                roleColor: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1),
                messageColor: pendingAssistantTextColor ?? NSColor(calibratedWhite: 0.16, alpha: 0.94),
                to: transcript
            )
        }
        guard transcript.length > 0 else {
            chatTextView.string = "输入消息后，AI 回复会显示在这里"
            chatTextView.textColor = NSColor(calibratedWhite: 0.42, alpha: 0.82)
            return
        }
        chatTextView.textStorage?.setAttributedString(transcript)
        scrollChatToVisibleContent()
    }

    // 内容未超过可视区时保持顶部，不让第一条消息因每次刷新都被强制滚到末尾。
    private func scrollChatToVisibleContent() {
        guard let textContainer = chatTextView.textContainer,
              let layoutManager = chatTextView.layoutManager else {
            return
        }
        layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height + chatTextView.textContainerInset.height * 2
        let visibleHeight = chatScrollView.contentView.bounds.height
        guard visibleHeight > 0 else {
            return
        }
        if usedHeight > visibleHeight + 1 {
            chatTextView.scrollToEndOfDocument(nil)
            return
        }
        chatTextView.scrollToBeginningOfDocument(nil)
    }

    // 用角色标签和段落间距构成轻量聊天记录，避免引入新的富文本或聊天组件依赖。
    private func appendChatMessage(
        roleText: String,
        messageText: String,
        roleColor: NSColor,
        messageColor: NSColor,
        to transcript: NSMutableAttributedString
    ) {
        let roleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: roleColor,
        ]
        let messageAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
            .foregroundColor: messageColor,
        ]
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 5
        paragraphStyle.lineSpacing = 2
        var messageAttributesWithParagraph = messageAttributes
        messageAttributesWithParagraph[.paragraphStyle] = paragraphStyle
        transcript.append(NSAttributedString(string: "\(roleText)\n", attributes: roleAttributes))
        transcript.append(NSAttributedString(string: "\(messageText)\n\n", attributes: messageAttributesWithParagraph))
    }

    private func buildView() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.16).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.96).cgColor

        let visualEffectView = NSVisualEffectView(frame: bounds)
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.96).cgColor
        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let titleIconLabel = NSTextField(labelWithString: "✦")
        titleIconLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleIconLabel.textColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1)
        let titleLabel = NSTextField(labelWithString: "AI 输入")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.14, alpha: 0.94)
        let subtitleLabel = NSTextField(labelWithString: "连续对话 · 当前会话保留上下文")
        subtitleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.42, alpha: 0.82)

        let titleStack = NSStackView(views: [titleIconLabel, titleLabel, subtitleLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6

        for serviceProvider in AIServiceProvider.allCases {
            let menuItem = NSMenuItem(title: serviceProvider.displayName, action: nil, keyEquivalent: "")
            menuItem.representedObject = serviceProvider.rawValue
            serviceProviderPopUpButton.menu?.addItem(menuItem)
        }
        serviceProviderPopUpButton.target = self
        serviceProviderPopUpButton.action = #selector(changeServiceProvider(_:))
        serviceProviderPopUpButton.widthAnchor.constraint(equalToConstant: 148).isActive = true
        let headerSpacer = NSView(frame: .zero)
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerStack = NSStackView(views: [titleStack, headerSpacer, serviceProviderPopUpButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8

        styleCard(chatContainer)
        promptContainer.translatesAutoresizingMaskIntoConstraints = false
        chatContainer.translatesAutoresizingMaskIntoConstraints = false

        promptInputView.translatesAutoresizingMaskIntoConstraints = false
        promptContainer.addSubview(promptInputView)
        NSLayoutConstraint.activate([
            promptInputView.leadingAnchor.constraint(equalTo: promptContainer.leadingAnchor, constant: 12),
            promptInputView.trailingAnchor.constraint(equalTo: promptContainer.trailingAnchor, constant: -12),
            promptInputView.topAnchor.constraint(equalTo: promptContainer.topAnchor, constant: 8),
            promptInputView.bottomAnchor.constraint(equalTo: promptContainer.bottomAnchor, constant: -8),
        ])

        chatTextView.isEditable = false
        chatTextView.isSelectable = true
        chatTextView.drawsBackground = false
        chatTextView.font = NSFont.systemFont(ofSize: 13.5)
        chatTextView.textContainerInset = NSSize(width: 12, height: 10)
        chatTextView.textContainer?.lineFragmentPadding = 0
        chatTextView.minSize = NSSize(width: 0, height: 0)
        chatTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        chatTextView.isVerticallyResizable = true
        chatTextView.isHorizontallyResizable = false
        chatTextView.autoresizingMask = [.width]
        chatTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        chatTextView.textContainer?.widthTracksTextView = true
        chatScrollView.documentView = chatTextView
        chatScrollView.hasVerticalScroller = true
        chatScrollView.scrollerStyle = .overlay
        chatScrollView.borderType = .noBorder
        chatScrollView.drawsBackground = false
        chatScrollView.translatesAutoresizingMaskIntoConstraints = false
        chatContainer.addSubview(chatScrollView)
        chatContainer.addSubview(promptContainer)
        NSLayoutConstraint.activate([
            chatScrollView.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor),
            chatScrollView.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor),
            chatScrollView.topAnchor.constraint(equalTo: chatContainer.topAnchor),
            chatScrollView.bottomAnchor.constraint(equalTo: promptContainer.topAnchor, constant: -8),
            promptContainer.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 10),
            promptContainer.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -10),
            promptContainer.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor, constant: -10),
            promptContainer.heightAnchor.constraint(equalToConstant: 48),
        ])

        configureActionButton(commitButton, backgroundColor: NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1), textColor: .white)
        commitButton.target = self
        commitButton.action = #selector(commitAIInput)

        let buttonSpacer = NSView(frame: .zero)
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonStack = NSStackView(views: [buttonSpacer, commitButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill

        let pageStack = NSStackView(views: [headerStack, chatContainer, buttonStack])
        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 10
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(pageStack)
        NSLayoutConstraint.activate([
            pageStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 16),
            pageStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -16),
            pageStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 14),
            pageStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -14),
            headerStack.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            chatContainer.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            chatContainer.heightAnchor.constraint(equalToConstant: 380),
            buttonStack.heightAnchor.constraint(equalToConstant: 28),
        ])
        reset()
    }

    // 输入区域展示自己的光标，但按键仍转给当前输入法控制器处理。
    private func updatePromptInputAppearance() {
        let accentColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1)
        promptContainer.wantsLayer = true
        promptContainer.layer?.cornerRadius = 8
        promptContainer.layer?.masksToBounds = true
        promptContainer.layer?.borderWidth = isPromptInputEnabled ? 1.2 : 1
        promptContainer.layer?.borderColor = isPromptInputEnabled
            ? accentColor.withAlphaComponent(0.58).cgColor
            : NSColor(calibratedWhite: 0, alpha: 0.10).cgColor
        promptContainer.layer?.backgroundColor = isPromptInputEnabled
            ? accentColor.withAlphaComponent(0.055).cgColor
            : NSColor(calibratedWhite: 0, alpha: 0.025).cgColor
    }

    // 聊天外框承载消息滚动区和底部输入区；按钮保留现有的鼠标入口作为辅助操作。
    // 面板按钮保留原有点击入口，只把显示收敛为候选条同源的轻量扁平按钮。
    private func configureActionButton(
        _ button: NSButton,
        backgroundColor: NSColor,
        textColor: NSColor
    ) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isBordered = false
        button.contentTintColor = textColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = backgroundColor.cgColor
    }

    private func selectServiceProvider(_ serviceProvider: AIServiceProvider) {
        for menuItem in serviceProviderPopUpButton.itemArray {
            guard menuItem.representedObject as? String == serviceProvider.rawValue else {
                continue
            }
            serviceProviderPopUpButton.select(menuItem)
            return
        }
    }

    private func styleCard(_ cardView: NSView) {
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 9
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor(calibratedWhite: 0, alpha: 0.12).cgColor
        cardView.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.34).cgColor
    }
}
