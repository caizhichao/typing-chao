import AppKit

// 提供一次性 AI 输入面板：键盘仍留在原 IMK 会话，避免面板文本控件建立嵌套输入会话。
final class AIInputOverlay {
    private static let panelSize = NSSize(width: 440, height: 310)
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
    private let promptContainer = NSView(frame: .zero)
    private let promptLabel = NSTextField(labelWithString: "")
    private let resultTextView = NSTextView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "按 Enter 发送 · Esc 关闭")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let commitButton = NSButton(title: "上屏结果", target: nil, action: nil)
    private let resultScrollView = NSScrollView(frame: .zero)

    var acceptsPromptInput: Bool {
        isPromptInputEnabled
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
        updatePromptDisplay()
        sendButton.isEnabled = true
        resultTextView.string = "AI 输出会显示在这里"
        resultTextView.textColor = NSColor(calibratedWhite: 1, alpha: 0.38)
        statusLabel.stringValue = "按 Enter 发送 · Esc 关闭"
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
        resultTextView.string = ""
        resultTextView.textColor = NSColor(calibratedWhite: 1, alpha: 0.60)
        statusLabel.stringValue = "正在请求 AI…"
        commitButton.isHidden = true
    }

    func showResult(_ resultText: String) {
        isPromptInputEnabled = true
        sendButton.isEnabled = true
        updatePromptDisplay()
        resultTextView.string = resultText
        resultTextView.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        statusLabel.stringValue = "本次请求已完成，不保留对话历史"
        commitButton.isHidden = false
    }

    func showError(_ messageText: String) {
        isPromptInputEnabled = true
        sendButton.isEnabled = true
        updatePromptDisplay()
        resultTextView.string = messageText
        resultTextView.textColor = NSColor(calibratedRed: 1, green: 0.68, blue: 0.62, alpha: 0.92)
        statusLabel.stringValue = "请求未完成，请修改内容后重试"
        commitButton.isHidden = true
    }

    @objc private func requestAIInput() {
        submitPrompt()
    }

    @objc private func commitAIInput() {
        let resultText = resultTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resultText.isEmpty else { return }
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

        let titleLabel = NSTextField(labelWithString: "AI 输入")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.94)

        let subtitleLabel = NSTextField(labelWithString: "使用已设置快捷键打开 · 每次请求独立处理")
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3

        promptContainer.wantsLayer = true
        promptContainer.layer?.cornerRadius = 6
        promptContainer.layer?.borderWidth = 1
        promptContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        promptContainer.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.58).cgColor
        promptContainer.translatesAutoresizingMaskIntoConstraints = false

        promptLabel.font = NSFont.systemFont(ofSize: 14)
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 1
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptContainer.addSubview(promptLabel)
        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: promptContainer.leadingAnchor, constant: 9),
            promptLabel.trailingAnchor.constraint(equalTo: promptContainer.trailingAnchor, constant: -9),
            promptLabel.centerYAnchor.constraint(equalTo: promptContainer.centerYAnchor),
        ])

        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.font = NSFont.systemFont(ofSize: 13)
        resultTextView.textContainerInset = NSSize(width: 8, height: 8)
        resultTextView.translatesAutoresizingMaskIntoConstraints = false
        resultScrollView.documentView = resultTextView
        resultScrollView.hasVerticalScroller = true
        resultScrollView.borderType = .bezelBorder
        resultScrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.48)
        statusLabel.lineBreakMode = .byTruncatingTail

        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeAIInput)
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(requestAIInput)
        commitButton.bezelStyle = .rounded
        commitButton.target = self
        commitButton.action = #selector(commitAIInput)

        let buttonSpacer = NSView(frame: .zero)
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonStack = NSStackView(views: [buttonSpacer, closeButton, commitButton, sendButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill

        let pageStack = NSStackView(views: [titleStack, promptContainer, resultScrollView, statusLabel, buttonStack])
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
            promptContainer.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            resultScrollView.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: pageStack.widthAnchor),
            promptContainer.heightAnchor.constraint(equalToConstant: 30),
            resultScrollView.heightAnchor.constraint(equalToConstant: 112),
            buttonStack.heightAnchor.constraint(equalToConstant: 28),
        ])
        reset()
    }
}
