import AppKit

// 提供连续对话 AI 输入面板：React/Tailwind 负责绘制，中文组字仍复用当前 IMK 会话。
final class AIInputOverlay {
    private static let panelSize = NSSize(width: 520, height: 500)
    private static let emptyPanelSize = NSSize(width: 520, height: 164)
    private let panel: AIInputOverlayPanel
    private let contentView: AIInputOverlayContentView
    private var requestHandler: ((String, [AIConversationMessage]) -> Void)?
    private var commitHandler: ((String) -> Void)?
    private var serviceProviderHandler: ((AIServiceProvider) -> Void)?
    private var currentAnchor: InputOverlayAnchor?

    init() {
        let contentView = AIInputOverlayContentView(frame: NSRect(origin: .zero, size: Self.panelSize))
        let panel = AIInputOverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            // AI 面板沿用输入法浮层的非激活窗口，不抢宿主应用的主窗口焦点。
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
        // 输入区需要允许非激活面板接收第一响应者，避免只能点击后才获得焦点。
        panel.becomesKeyOnlyIfNeeded = false
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

    // 上次请求已返回结果时允许用 Command-Return 上屏，并由 Web UI 提示当前快捷键。
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

    // 用户主动触发 AI 输入时让隐藏的原生键盘入口获得焦点，并预填用户明确选中的原文。
    func show(anchor: InputOverlayAnchor?, prefilledPromptText: String = "") {
        currentAnchor = anchor
        contentView.reset()
        if !prefilledPromptText.isEmpty {
            contentView.appendPromptText(prefilledPromptText)
        }
        setPanelSize(Self.emptyPanelSize, anchor: anchor)
        if anchor == nil {
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

    // Command-Return 通过唯一提交入口上屏当前结果。
    func commitResult() {
        contentView.commitResult()
    }

    func showLoading() {
        contentView.setExpandedLayout(true)
        setPanelSize(Self.panelSize, anchor: currentAnchor)
        contentView.showLoading()
    }

    func showResult(_ resultText: String) {
        contentView.setExpandedLayout(true)
        setPanelSize(Self.panelSize, anchor: currentAnchor)
        contentView.showResult(resultText)
    }

    func showError(_ messageText: String) {
        contentView.setExpandedLayout(true)
        setPanelSize(Self.panelSize, anchor: currentAnchor)
        contentView.showError(messageText)
    }

    func hide() {
        currentAnchor = nil
        panel.orderOut(nil)
    }

    // AI 对话有内容时展开面板，并继续使用打开时的光标锚点保持位置稳定。
    private func setPanelSize(_ panelSize: NSSize, anchor: InputOverlayAnchor?) {
        panel.setContentSize(panelSize)
        if let anchor {
            panel.setFrameOrigin(anchor.translationOrigin(for: panelSize, candidateFrame: nil))
            return
        }
        panel.center()
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

// AI 页面输入文本由当前 Rime 会话维护，因此用不可见原生视图截获按键而不让 WebView 创建第二条输入链。
final class AIInputKeyCaptureView: NSView {
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        _ = keyHandler?(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyHandler?(event) ?? false
    }
}

// AI 面板展示当前会话消息记录，服务端不保存输入，客户端每次请求显式携带本地历史。
private final class AIInputOverlayContentView: NSView {
    var requestHandler: ((String, [AIConversationMessage]) -> Void)?
    var commitHandler: ((String) -> Void)?
    var serviceProviderHandler: ((AIServiceProvider) -> Void)?

    private let webView = TypingChaoWebView(webViewName: .aiInput, acceptsKeyboardFocus: false)
    private let keyCaptureView = AIInputKeyCaptureView(frame: .zero)
    private var promptText = ""
    private var promptComposition = ""
    private var pendingPromptText = ""
    private var conversationMessageList: [AIConversationMessage] = []
    private var pendingAssistantText = ""
    private var pendingState = "none"
    private var isExpandedLayout = false
    private var isPromptInputEnabled = true
    private var hasResult = false
    private var currentResultText = ""

    var acceptsPromptInput: Bool {
        isPromptInputEnabled
    }

    var canCommitResult: Bool {
        hasResult && !currentResultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
        reset()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setKeyHandler(_ handler: @escaping (NSEvent) -> Bool) {
        keyCaptureView.keyHandler = handler
    }

    // WebView 不能成为 AI 面板的输入焦点，避免绕开 InputMethodKit 当前会话的 Rime 组字。
    func focusPromptInput() {
        guard isPromptInputEnabled, let window else { return }
        _ = window.makeFirstResponder(keyCaptureView)
    }

    func reset() {
        promptText = ""
        promptComposition = ""
        pendingPromptText = ""
        conversationMessageList = []
        pendingAssistantText = ""
        pendingState = "none"
        isExpandedLayout = false
        isPromptInputEnabled = true
        hasResult = false
        currentResultText = ""
        sendState()
    }

    func appendPromptText(_ textValue: String) {
        guard isPromptInputEnabled, !textValue.isEmpty else { return }
        promptText += textValue
        sendState()
    }

    func deleteBackwardPromptText() {
        guard isPromptInputEnabled, !promptText.isEmpty else { return }
        let lastRange = promptText.rangeOfComposedCharacterSequence(at: promptText.index(before: promptText.endIndex))
        promptText.removeSubrange(lastRange)
        sendState()
    }

    func updatePromptComposition(_ textValue: String) {
        guard isPromptInputEnabled else { return }
        promptComposition = textValue
        sendState()
    }

    func submitPrompt() {
        guard isPromptInputEnabled else { return }
        let textValue = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textValue.isEmpty else {
            pendingAssistantText = "请输入内容后再发送"
            pendingState = "error"
            isExpandedLayout = true
            sendState()
            return
        }
        pendingPromptText = textValue
        promptText = ""
        promptComposition = ""
        requestHandler?(textValue, conversationMessageList)
        sendState()
    }

    func showLoading() {
        isPromptInputEnabled = false
        hasResult = false
        currentResultText = ""
        pendingAssistantText = ""
        pendingState = "loading"
        sendState()
    }

    func showResult(_ resultText: String) {
        isPromptInputEnabled = true
        hasResult = true
        currentResultText = resultText
        if !pendingPromptText.isEmpty {
            conversationMessageList.append(
                AIConversationMessage(roleName: "user", contentText: pendingPromptText)
            )
        }
        conversationMessageList.append(
            AIConversationMessage(roleName: "assistant", contentText: resultText)
        )
        pendingPromptText = ""
        pendingAssistantText = ""
        pendingState = "none"
        sendState()
    }

    func showError(_ messageText: String) {
        isPromptInputEnabled = true
        hasResult = false
        currentResultText = ""
        pendingAssistantText = messageText
        pendingState = "error"
        sendState()
    }

    // 请求开始或结果返回时切换到完整聊天面板，空态仍保持紧凑输入框。
    func setExpandedLayout(_ isExpanded: Bool) {
        isExpandedLayout = isExpanded
        sendState()
    }

    // 只有真实返回结果才允许上屏，避免把占位文案或错误文案写入宿主。
    func commitResult() {
        guard canCommitResult else { return }
        commitHandler?(currentResultText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func buildView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        keyCaptureView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        addSubview(keyCaptureView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            keyCaptureView.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyCaptureView.topAnchor.constraint(equalTo: topAnchor),
            keyCaptureView.widthAnchor.constraint(equalToConstant: 1),
            keyCaptureView.heightAnchor.constraint(equalToConstant: 1),
        ])
        webView.setMessageHandler { [weak self] messageBody in
            self?.handleWebMessage(messageBody)
        }
        webView.loadBundledPage()
    }

    // AI Web UI 只能请求焦点、服务切换和已有原生操作入口，文本状态始终由 Swift 管理。
    private func handleWebMessage(_ messageBody: [String: Any]) {
        guard let messageType = messageBody["messageType"] as? String else {
            NSLog("TypingChao ignored AI Web UI message without type")
            return
        }
        if messageType == "webViewReady" {
            webView.markPageReady()
            sendState()
            return
        }
        guard messageType == "aiInputAction",
              let messageData = messageBody["messageData"] as? [String: Any],
              let actionName = messageData["actionName"] as? String else {
            NSLog("TypingChao ignored unknown AI Web UI message: %@", messageType)
            return
        }
        switch actionName {
        case "focusPromptInput":
            focusPromptInput()
        case "setServiceProvider":
            guard let rawValue = messageData["fieldValue"] as? String,
                  let serviceProvider = AIServiceProvider(rawValue: rawValue) else { return }
            serviceProviderHandler?(serviceProvider)
            sendState()
        case "submitPrompt":
            submitPrompt()
        case "commitResult":
            commitResult()
        default:
            NSLog("TypingChao ignored unsupported AI Web UI action: %@", actionName)
        }
    }

    // 页面状态只包含用户正在编辑的提示词和本地会话内容，不暴露 API Key 或原生请求细节。
    private func sendState() {
        webView.sendMessage(
            messageType: "aiInputState",
            messageData: [
                "promptText": promptText,
                "promptComposition": promptComposition,
                "pendingPromptText": pendingPromptText,
                "conversationMessageList": conversationMessageList.map { messageItem in
                    [
                        "roleName": messageItem.roleName,
                        "contentText": messageItem.contentText,
                    ]
                },
                "pendingAssistantText": pendingAssistantText,
                "pendingState": pendingState,
                "serviceProviderIdentifier": InputMethodSettings.shared.aiServiceProvider.rawValue,
                "serviceProviderList": AIServiceProvider.allCases.map { providerItem in
                    [
                        "optionIdentifier": providerItem.rawValue,
                        "displayName": providerItem.displayName,
                    ]
                },
                "isPromptInputEnabled": isPromptInputEnabled,
                "isExpandedLayout": isExpandedLayout,
                "canCommitResult": canCommitResult,
            ]
        )
    }
}
