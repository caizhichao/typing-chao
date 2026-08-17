import AppKit

// 提供连续对话 AI 输入面板：React 与 Vercel AI SDK 直连服务，中文组字仍复用当前 IMK 会话。
final class AIInputOverlay {
    private static let panelSize = NSSize(width: 520, height: 500)
    private static let emptyPanelSize = NSSize(width: 520, height: 164)
    private let panel: AIInputOverlayPanel
    private let contentView: AIInputOverlayContentView
    private var commitHandler: ((String) -> Void)?
    private var resultHandler: ((String) -> Void)?
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
        contentView.commitHandler = { [weak self] resultText in
            self?.commitHandler?(resultText)
        }
        contentView.resultHandler = { [weak self] resultText in
            self?.resultHandler?(resultText)
        }
        contentView.serviceProviderHandler = { [weak self] serviceProvider in
            self?.serviceProviderHandler?(serviceProvider)
        }
        contentView.expandedLayoutHandler = { [weak self] isExpanded in
            guard let self else { return }
            let panelSize = isExpanded ? Self.panelSize : Self.emptyPanelSize
            self.setPanelSize(panelSize, anchor: self.currentAnchor)
        }
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var acceptsPromptInput: Bool {
        contentView.acceptsPromptInput
    }

    // React 完成真实响应后才允许 Command-Return 上屏，避免将流式中间文本写进宿主。
    var canCommitResult: Bool {
        contentView.canCommitResult
    }

    func setCommitHandler(_ handler: @escaping (String) -> Void) {
        commitHandler = handler
    }

    func setResultHandler(_ handler: @escaping (String) -> Void) {
        resultHandler = handler
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
        contentView.reset(prefilledPromptText: prefilledPromptText)
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

    // Command-Return 通过唯一提交入口上屏当前完整结果。
    func commitResult() {
        contentView.commitResult()
    }

    func hide() {
        contentView.cancelRequest()
        contentView.clearRuntimeConfiguration()
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

// 原生层只同步 IMK 文字事件、运行配置和最终上屏结果，React 在页面内直接执行 AI SDK 请求。
private final class AIInputOverlayContentView: NSView {
    var commitHandler: ((String) -> Void)?
    var resultHandler: ((String) -> Void)?
    var serviceProviderHandler: ((AIServiceProvider) -> Void)?
    var expandedLayoutHandler: ((Bool) -> Void)?

    private let webView = TypingChaoWebView(webViewName: .aiInput, acceptsKeyboardFocus: false)
    private let keyCaptureView = AIInputKeyCaptureView(frame: .zero)
    private var isPromptInputEnabled = true
    private var currentResultText = ""

    var acceptsPromptInput: Bool {
        isPromptInputEnabled
    }

    var canCommitResult: Bool {
        !currentResultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
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

    func reset(prefilledPromptText: String) {
        isPromptInputEnabled = true
        currentResultText = ""
        sendRuntimeConfiguration()
        sendCommand(actionName: "resetConversation", fieldValue: prefilledPromptText)
    }

    func appendPromptText(_ textValue: String) {
        guard isPromptInputEnabled, !textValue.isEmpty else { return }
        sendCommand(actionName: "appendPromptText", fieldValue: textValue)
    }

    func deleteBackwardPromptText() {
        guard isPromptInputEnabled else { return }
        sendCommand(actionName: "deleteBackwardPromptText")
    }

    func updatePromptComposition(_ textValue: String) {
        guard isPromptInputEnabled else { return }
        sendCommand(actionName: "updatePromptComposition", fieldValue: textValue)
    }

    func submitPrompt() {
        guard isPromptInputEnabled else { return }
        sendCommand(actionName: "submitPrompt")
    }

    func cancelRequest() {
        sendCommand(actionName: "cancelRequest")
    }

    func clearRuntimeConfiguration() {
        sendCommand(actionName: "clearRuntimeConfiguration")
    }

    // 只有 React 返回完整结果后才允许上屏，避免把错误或流式中间文本写入宿主。
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

    // Web UI 只能请求焦点、服务切换、运行状态和最终上屏结果，网络请求不再回到 Swift。
    private func handleWebMessage(_ messageBody: [String: Any]) {
        guard let messageType = messageBody["messageType"] as? String else {
            NSLog("TypingChao ignored AI Web UI message without type")
            return
        }
        if messageType == "webViewReady" {
            webView.markPageReady()
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
            sendRuntimeConfiguration()
        case "submitPrompt":
            submitPrompt()
        case "commitResult":
            commitResult()
        case "setPromptInputEnabled":
            guard let isEnabled = messageData["fieldValue"] as? Bool else { return }
            isPromptInputEnabled = isEnabled
            if isEnabled {
                focusPromptInput()
            }
        case "setExpandedLayout":
            guard let isExpanded = messageData["fieldValue"] as? Bool else { return }
            expandedLayoutHandler?(isExpanded)
        case "setResultText":
            guard let resultText = messageData["fieldValue"] as? String else { return }
            currentResultText = resultText
            resultHandler?(resultText)
        case "clearResultText":
            currentResultText = ""
        default:
            NSLog("TypingChao ignored unsupported AI Web UI action: %@", actionName)
        }
    }

    // React 直连时仅在已打开的页面内存传递当前服务配置，不把 Key 写入源码、构建产物或持久化页面存储。
    private func sendRuntimeConfiguration() {
        let serviceProvider = InputMethodSettings.shared.aiServiceProvider
        webView.sendMessage(
            messageType: "aiInputConfiguration",
            messageData: [
                "serviceProviderIdentifier": serviceProvider.rawValue,
                "serviceProviderList": AIServiceProvider.allCases.map { providerItem in
                    [
                        "optionIdentifier": providerItem.rawValue,
                        "displayName": providerItem.displayName,
                    ]
                },
                "baseURL": InputMethodSettings.shared.baseURL(for: serviceProvider).absoluteString,
                "modelName": InputMethodSettings.shared.modelName(for: serviceProvider),
                "apiKey": InputMethodSettings.shared.apiKey(for: serviceProvider) ?? "",
                "systemPromptText": InputMethodSettings.shared.aiInputSystemPrompt,
            ]
        )
    }

    private func sendCommand(actionName: String, fieldValue: Any? = nil) {
        var commandData: [String: Any] = ["actionName": actionName]
        if let fieldValue {
            commandData["fieldValue"] = fieldValue
        }
        webView.sendMessage(messageType: "aiInputCommand", messageData: commandData)
    }
}
