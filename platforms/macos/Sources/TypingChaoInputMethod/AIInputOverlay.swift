import AppKit

// 提供一次性 AI 输入面板：键盘仍留在原 IMK 会话，避免面板文本控件建立嵌套输入会话。
final class AIInputOverlay {
    private static let panelSize = NSSize(width: 420, height: 286)
    private let panel: AIInputOverlayPanel
    private let contentView: AIInputOverlayContentView
    private var requestHandler: ((String) -> Void)?
    private var commitHandler: ((String) -> Void)?
    private var closeHandler: (() -> Void)?

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
        contentView.requestHandler = { [weak self] promptText in
            self?.requestHandler?(promptText)
        }
        contentView.commitHandler = { [weak self] resultText in
            self?.commitHandler?(resultText)
        }
        contentView.closeHandler = { [weak self] in
            self?.closeHandler?()
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

    func setRequestHandler(_ handler: @escaping (String) -> Void) {
        requestHandler = handler
    }

    func setCommitHandler(_ handler: @escaping (String) -> Void) {
        commitHandler = handler
    }

    func setCloseHandler(_ handler: @escaping () -> Void) {
        closeHandler = handler
    }

    // 用户主动触发 AI 输入时保持宿主编辑器焦点，原 IMK controller 继续接收所有键盘事件。
    func show(anchor: InputOverlayAnchor?) {
        contentView.reset()
        panel.setContentSize(Self.panelSize)
        if let anchor {
            panel.setFrameOrigin(anchor.translationOrigin(for: Self.panelSize, candidateFrame: nil))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
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

    // 键盘快捷键与面板按钮共用同一结果提交入口。
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

// 面板只负责显示和鼠标按钮，不能成为 key window 或创建新的 InputMethodKit 会话。
final class AIInputOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

// AI 输入框只保留一条提示词和一条回复，避免把首版实现扩展成聊天窗口。
private final class AIInputOverlayContentView: NSView {
    var requestHandler: ((String) -> Void)?
    var commitHandler: ((String) -> Void)?
    var closeHandler: (() -> Void)?

    private var promptText = ""
    private var promptComposition = ""
    private var isPromptInputEnabled = true
    private var hasResult = false
    private let promptContainer = NSView(frame: .zero)
    private let promptLabel = NSTextField(labelWithString: "")
    private let promptCaptionLabel = NSTextField(labelWithString: "输入")
    private let resultContainer = NSView(frame: .zero)
    private let resultCaptionLabel = NSTextField(labelWithString: "AI 结果")
    private let resultTextView = NSTextView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "按 Enter 发送 · Esc 关闭")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let commitButton = NSButton(title: "上屏结果", target: nil, action: nil)
    private let resultScrollView = NSScrollView(frame: .zero)

    var acceptsPromptInput: Bool {
        isPromptInputEnabled
    }

    var canCommitResult: Bool {
        hasResult && !resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        isPromptInputEnabled = true
        hasResult = false
        updatePromptDisplay()
        sendButton.isEnabled = true
        resultTextView.string = "发送后显示结果"
        resultTextView.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)
        statusLabel.stringValue = "Enter 发送 · Esc 关闭"
        commitButton.isHidden = true
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
            statusLabel.stringValue = "请输入内容后再发送"
            return
        }
        requestHandler?(textValue)
    }

    func showLoading() {
        isPromptInputEnabled = false
        sendButton.isEnabled = false
        updatePromptDisplay()
        hasResult = false
        resultTextView.string = ""
        resultTextView.textColor = NSColor(calibratedWhite: 1, alpha: 0.60)
        statusLabel.stringValue = "正在生成… · Esc 关闭"
        commitButton.isHidden = true
    }

    func showResult(_ resultText: String) {
        isPromptInputEnabled = true
        sendButton.isEnabled = true
        updatePromptDisplay()
        hasResult = true
        resultTextView.string = resultText
        resultTextView.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        statusLabel.stringValue = "⌘Enter 上屏 · Enter 重试 · Esc 关闭"
        commitButton.isHidden = false
    }

    func showError(_ messageText: String) {
        isPromptInputEnabled = true
        sendButton.isEnabled = true
        updatePromptDisplay()
        hasResult = false
        resultTextView.string = messageText
        resultTextView.textColor = NSColor(calibratedRed: 1, green: 0.68, blue: 0.62, alpha: 0.92)
        statusLabel.stringValue = "Enter 重试 · Esc 关闭"
        commitButton.isHidden = true
    }

    @objc private func requestAIInput() {
        submitPrompt()
    }

    @objc private func commitAIInput() {
        commitResult()
    }

    // 只有真实返回结果才允许上屏，避免把占位文案或错误文案写入宿主。
    func commitResult() {
        guard canCommitResult else { return }
        let resultText = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        commitHandler?(resultText)
    }

    @objc private func closeAIInput() {
        closeHandler?()
    }

    private func updatePromptDisplay() {
        let textValue = promptText + promptComposition
        guard !textValue.isEmpty else {
            promptLabel.stringValue = "输入你想让 AI 处理的内容"
            promptLabel.textColor = NSColor.secondaryLabelColor
            return
        }
        let attributedText = NSMutableAttributedString(
            string: textValue,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if !promptComposition.isEmpty {
            let compositionRange = NSRange(
                location: promptText.utf16.count,
                length: promptComposition.utf16.count
            )
            attributedText.addAttributes([
                .foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: compositionRange)
        }
        promptLabel.attributedStringValue = attributedText
    }

    private func buildView() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let visualEffectView = NSVisualEffectView(frame: bounds)
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let titleIconLabel = NSTextField(labelWithString: "✦")
        titleIconLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleIconLabel.textColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 0.92)
        let titleLabel = NSTextField(labelWithString: "AI 输入")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.94)
        let subtitleLabel = NSTextField(labelWithString: "单轮处理 · 每次请求独立处理")
        subtitleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)

        let titleStack = NSStackView(views: [titleIconLabel, titleLabel, subtitleLabel])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 6

        let shortcutLabel = NSTextField(labelWithString: "Enter 发送 · ⌘Enter 上屏 · Esc 关闭")
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        shortcutLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)
        shortcutLabel.alignment = .right
        let titleSpacer = NSView(frame: .zero)
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerStack = NSStackView(views: [titleStack, titleSpacer, shortcutLabel])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8

        styleCard(promptContainer)
        styleCard(resultContainer)
        promptContainer.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.translatesAutoresizingMaskIntoConstraints = false

        for captionLabel in [promptCaptionLabel, resultCaptionLabel] {
            captionLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            captionLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)
            captionLabel.translatesAutoresizingMaskIntoConstraints = false
        }
        promptContainer.addSubview(promptCaptionLabel)
        resultContainer.addSubview(resultCaptionLabel)

        promptLabel.font = NSFont.systemFont(ofSize: 14)
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 1
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptContainer.addSubview(promptLabel)
        NSLayoutConstraint.activate([
            promptCaptionLabel.leadingAnchor.constraint(equalTo: promptContainer.leadingAnchor, constant: 12),
            promptCaptionLabel.topAnchor.constraint(equalTo: promptContainer.topAnchor, constant: 7),
            promptLabel.leadingAnchor.constraint(equalTo: promptContainer.leadingAnchor, constant: 12),
            promptLabel.trailingAnchor.constraint(equalTo: promptContainer.trailingAnchor, constant: -12),
            promptLabel.topAnchor.constraint(equalTo: promptCaptionLabel.bottomAnchor, constant: 1),
            promptLabel.bottomAnchor.constraint(equalTo: promptContainer.bottomAnchor, constant: -7),
        ])

        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.font = NSFont.systemFont(ofSize: 13)
        resultTextView.textContainerInset = .zero
        resultTextView.textContainer?.lineFragmentPadding = 0
        resultTextView.translatesAutoresizingMaskIntoConstraints = false
        resultScrollView.documentView = resultTextView
        resultScrollView.hasVerticalScroller = true
        resultScrollView.scrollerStyle = .overlay
        resultScrollView.borderType = .noBorder
        resultScrollView.drawsBackground = false
        resultScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.addSubview(resultScrollView)
        NSLayoutConstraint.activate([
            resultCaptionLabel.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 12),
            resultCaptionLabel.topAnchor.constraint(equalTo: resultContainer.topAnchor, constant: 7),
            resultScrollView.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 12),
            resultScrollView.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor, constant: -10),
            resultScrollView.topAnchor.constraint(equalTo: resultCaptionLabel.bottomAnchor, constant: 2),
            resultScrollView.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor, constant: -8),
        ])

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)
        statusLabel.lineBreakMode = .byTruncatingTail

        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeAIInput)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(requestAIInput)
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.contentTintColor = .white
        commitButton.target = self
        commitButton.action = #selector(commitAIInput)

        let buttonSpacer = NSView(frame: .zero)
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonStack = NSStackView(views: [buttonSpacer, closeButton, sendButton, commitButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill

        let pageStack = NSStackView(views: [headerStack, promptContainer, resultContainer, statusLabel, buttonStack])
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
            promptContainer.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            resultContainer.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            promptContainer.heightAnchor.constraint(equalToConstant: 48),
            resultContainer.heightAnchor.constraint(equalToConstant: 108),
            buttonStack.heightAnchor.constraint(equalToConstant: 28),
        ])
        reset()
    }

    // 让输入卡和结果卡沿用候选条的描边、圆角和轻玻璃层次。
    private func styleCard(_ cardView: NSView) {
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 9
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        cardView.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.055).cgColor
    }
}
