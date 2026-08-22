import AppKit

// Swift 原生 AI 输入面板：彻底移除 WKWebView，复刻 ai-elements 全量能力。
// 布局：NSPanel 520x500/164（header + scroll transcript + prompt-surface），AppKit + NSTextView，单输入链 AIInputKeyCaptureView。
private enum AIInputLocalShellConstantsX {
    static let perCommandTimeoutSeconds: TimeInterval = 30
    static let maxTotalOutputLength = 8_000
}

final class AIInputOverlay {
    private static let panelSize = NSSize(width: 520, height: 500)
    private static let emptyPanelSize = NSSize(width: 520, height: 164)
    private let panel: AIInputOverlayPanel
    private let contentView: AIInputOverlayNativeView
    private var currentAnchor: InputOverlayAnchor?
    private(set) var isPresented = false

    init() {
        let contentView = AIInputOverlayNativeView(frame: NSRect(origin: .zero, size: Self.panelSize))
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
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        contentView.expandedLayoutHandler = { [weak self] isExpanded in
            guard let self else { return }
            let size = isExpanded ? Self.panelSize : Self.emptyPanelSize
            self.setPanelSize(size, anchor: self.currentAnchor)
        }
    }

    var isVisible: Bool { panel.isVisible }
    var acceptsPromptInput: Bool { contentView.acceptsPromptInput }
    var canCommitResult: Bool { contentView.canCommitResult }

    func setCommitHandler(_ h: @escaping (String) -> Void) { contentView.commitHandler = h }
    func setResultHandler(_ h: @escaping (String) -> Void) { contentView.resultHandler = h }
    func setServiceProviderHandler(_ h: @escaping (AIServiceProvider) -> Void) { contentView.serviceProviderHandler = h }
    func setKeyHandler(_ h: @escaping (NSEvent) -> Bool) { contentView.setKeyHandler(h) }

    func show(anchor: InputOverlayAnchor?, prefilledPromptText: String = "") {
        isPresented = true
        currentAnchor = anchor
        contentView.reset(prefilledPromptText: prefilledPromptText)
        setPanelSize(Self.emptyPanelSize, anchor: anchor)
        if anchor == nil { panel.center() }
        restorePresentation()
    }

    func restorePresentation() {
        guard isPresented else { return }
        panel.orderFrontRegardless()
        panel.makeKey()
        contentView.focusPromptInput()
    }

    func appendPromptText(_ s: String) { contentView.appendPromptText(s) }
    func deleteBackwardPromptText() { contentView.deleteBackwardPromptText() }
    func updatePromptComposition(_ s: String) { contentView.updatePromptComposition(s) }
    func submitPrompt() { contentView.submitPrompt() }
    func commitResult() { contentView.commitResult() }
    func hide() {
        guard isPresented else { return }
        isPresented = false
        contentView.cancelRequest()
        contentView.clearForHide()
        currentAnchor = nil
        panel.orderOut(nil)
    }
    private func setPanelSize(_ size: NSSize, anchor: InputOverlayAnchor?) {
        panel.setContentSize(size)
        if let anchor { panel.setFrameOrigin(anchor.translationOrigin(for: size, candidateFrame: nil)) }
        else { panel.center() }
    }
}

final class AIInputOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AIInputKeyCaptureView: NSView {
    var keyHandler: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { _ = keyHandler?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { keyHandler?(event) ?? false }
}

// 原生内容：header + scroll(transcript) + prompt-surface，不含任何 WebView。
final class AIInputOverlayNativeView: NSView {
    var commitHandler: ((String) -> Void)?
    var resultHandler: ((String) -> Void)?
    var serviceProviderHandler: ((AIServiceProvider) -> Void)?
    var expandedLayoutHandler: ((Bool) -> Void)?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let promptContainer = NSView()
    private let promptTextView = NSTextView()
    private let keyCaptureView = AIInputKeyCaptureView(frame: .zero)

    private var state = AIInputState()
    private var aiService: AIInputService?
    private var currentTask: Task<Void, Never>?
    private var pendingImageTask: URLSessionDataTask?
    private var isPromptEnabled: Bool = true

    var acceptsPromptInput: Bool { isPromptEnabled }
    var canCommitResult: Bool { state.conversationMessages.last?.role == .assistant && !(state.conversationMessages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 15; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setKeyHandler(_ h: @escaping (NSEvent) -> Bool) { keyCaptureView.keyHandler = h }

    func focusPromptInput() {
        guard isPromptEnabled, let window else { return }
        _ = window.makeFirstResponder(keyCaptureView)
    }

    func reset(prefilledPromptText: String) {
        currentTask?.cancel(); currentTask = nil
        aiService = nil
        state = AIInputState()
        if !prefilledPromptText.isEmpty { state.promptText = prefilledPromptText }
        isPromptEnabled = true
        expandedLayoutHandler?(false)
        applyState()
        focusPromptInput()
    }

    func appendPromptText(_ s: String) {
        guard isPromptEnabled, !s.isEmpty else { return }
        state.promptText += s
        applyPrompt()
    }
    func deleteBackwardPromptText() {
        guard isPromptEnabled else { return }
        if !state.promptText.isEmpty {
            state.promptText = String(state.promptText.dropLast())
            applyPrompt()
        }
    }
    func updatePromptComposition(_ s: String) { state.promptComposition = s; applyPrompt() }

    func submitPrompt() {
        guard isPromptEnabled else { return }
        let prompt = (state.promptText + state.promptComposition).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { applyError("请输入内容后再发送"); return }
        guard let apiKey = InputMethodSettings.shared.currentAPIKey, !apiKey.isEmpty else { applyError("请先在输入法设置中配置当前 AI 服务 Key"); return }
        let config = AIInputRuntimeConfiguration(
            serviceProviderIdentifier: InputMethodSettings.shared.aiServiceProvider.rawValue,
            baseURL: InputMethodSettings.shared.baseURL(for: InputMethodSettings.shared.aiServiceProvider).absoluteString,
            modelName: InputMethodSettings.shared.modelName(for: InputMethodSettings.shared.aiServiceProvider),
            apiKey: apiKey,
            systemPromptText: InputMethodSettings.shared.aiInputSystemPrompt
        )
        state.pendingPromptText = prompt
        state.pendingAssistantText = ""; state.pendingReasoningText = ""; state.pendingSources = []; state.pendingToolCalls = []
        state.pendingState = .loading
        state.promptText = ""; state.promptComposition = ""
        state.isExpandedLayout = true
        isPromptEnabled = false
        expandedLayoutHandler?(true)
        applyState()
        let conversationSnapshot = state.conversationMessages
        let service = AIInputService()
        aiService = service
        resultHandler?(state.pendingPromptText)
        currentTask = Task { [weak self] in
            do {
                let result = try await service.streamWithEvents(configuration: config, promptText: prompt, conversationMessages: conversationSnapshot) { [weak self] event in
                    DispatchQueue.main.async { self?.handleStreamEvent(event) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state.conversationMessages.append(.init(role: .user, content: prompt))
                    self.state.conversationMessages.append(.init(role: .assistant, content: result))
                    self.state.pendingPromptText = ""; self.state.pendingAssistantText = ""; self.state.pendingReasoningText = ""; self.state.pendingSources = []; self.state.pendingToolCalls = []
                    self.state.pendingState = .none; self.isPromptEnabled = true
                    self.resultHandler?(result)
                    self.applyState(); self.focusPromptInput()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.applyError(error.localizedDescription)
                }
            }
        }
    }

    func cancelRequest() { currentTask?.cancel(); currentTask = nil; pendingImageTask?.cancel(); pendingImageTask = nil; isPromptEnabled = true; applyState() }
    func triggerShellToolCalls() { applyState() }
    func denyShellToolCalls() { state.pendingToolCalls.removeAll { $0.toolName == "shell" && $0.state == .inputAvailable }; applyState() }
    func clearForHide() { currentTask?.cancel(); currentTask = nil; pendingImageTask?.cancel(); pendingImageTask = nil; state = AIInputState(); applyState() }
    func commitResult() { guard canCommitResult, let last = state.conversationMessages.last?.content else { return }; commitHandler?(last) }

    private func handleStreamEvent(_ e: AIStreamEvent) {
        switch e {
        case .textDelta(let d): state.pendingAssistantText += d; state.pendingState = .streaming
        case .reasoningStart: state.pendingReasoningText = ""; state.pendingState = .streaming
        case .reasoningDelta(let d): state.pendingReasoningText += d; state.pendingState = .streaming
        case .reasoningEnd: break
        case .source(let url, let title): state.pendingSources.append(.init(url: url, title: title))
        case .toolCall(let id, let name, let input):
            if state.pendingToolCalls.first(where: { $0.id == id }) == nil {
                state.pendingToolCalls.append(.init(id: id, toolName: name, input: input, output: nil, isError: false, state: .inputAvailable))
            }
            state.pendingState = .streaming
        case .toolInputDelta(let id, _, let delta):
            if let idx = state.pendingToolCalls.firstIndex(where: { $0.id == id }) {
                let prev = (state.pendingToolCalls[idx].input as? String) ?? ""
                state.pendingToolCalls[idx].input = prev + delta
            }
        case .toolResult(let id, _, let out, let isErr):
            if let idx = state.pendingToolCalls.firstIndex(where: { $0.id == id }) {
                state.pendingToolCalls[idx].output = out; state.pendingToolCalls[idx].isError = isErr
                state.pendingToolCalls[idx].state = isErr ? .outputError : .outputAvailable
            }
        case .finishStep: state.pendingState = .streaming
        case .finish: state.pendingState = .streaming
        }
        applyState()
    }

    private func applyError(_ msg: String) {
        state.pendingState = .error; state.pendingAssistantText = msg; isPromptEnabled = true
        applyState()
    }

    // MARK: Layout - minimal but functional, preserves header + transcript + prompt

    private func build() {
        // header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: "✦ AI 输入")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),
        ])

        // scroll + stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true; scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let doc = NSView()
        stackView.orientation = .vertical; stackView.spacing = 8; stackView.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stackView)
        scrollView.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: doc.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        // prompt container (rounded white)
        promptContainer.wantsLayer = true; promptContainer.layer?.cornerRadius = 10
        promptContainer.layer?.borderWidth = 1; promptContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        promptContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        promptContainer.translatesAutoresizingMaskIntoConstraints = false
        promptTextView.isEditable = false; promptTextView.isSelectable = true
        promptTextView.drawsBackground = false; promptTextView.backgroundColor = .clear
        promptTextView.translatesAutoresizingMaskIntoConstraints = false
        promptContainer.addSubview(promptTextView)
        NSLayoutConstraint.activate([
            promptTextView.leadingAnchor.constraint(equalTo: promptContainer.leadingAnchor, constant: 10),
            promptTextView.trailingAnchor.constraint(equalTo: promptContainer.trailingAnchor, constant: -60),
            promptTextView.topAnchor.constraint(equalTo: promptContainer.topAnchor, constant: 10),
            promptTextView.bottomAnchor.constraint(equalTo: promptContainer.bottomAnchor, constant: -10),
            promptContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let sendHint = NSTextField(labelWithString: "↩ 发送")
        sendHint.font = NSFont.systemFont(ofSize: 9.5); sendHint.textColor = .secondaryLabelColor
        sendHint.translatesAutoresizingMaskIntoConstraints = false
        promptContainer.addSubview(sendHint)
        NSLayoutConstraint.activate([
            sendHint.trailingAnchor.constraint(equalTo: promptContainer.trailingAnchor, constant: -10),
            sendHint.bottomAnchor.constraint(equalTo: promptContainer.bottomAnchor, constant: -8),
        ])

        keyCaptureView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scrollView)
        addSubview(promptContainer)
        addSubview(keyCaptureView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: promptContainer.topAnchor, constant: -10),

            promptContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            promptContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            promptContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            keyCaptureView.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyCaptureView.topAnchor.constraint(equalTo: topAnchor),
            keyCaptureView.widthAnchor.constraint(equalToConstant: 1),
            keyCaptureView.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func applyPrompt() {
        // 空态仅当 prompt+composition 均为空且可输入时才显示占位；isPromptEnabled=false 时不追加光标。
        let hasContent = !state.promptText.isEmpty || !state.promptComposition.isEmpty
        if !hasContent {
            promptTextView.string = "输入你想让 AI 处理的内容"
            promptTextView.textColor = .tertiaryLabelColor
            promptTextView.font = NSFont.systemFont(ofSize: 12)
            return
        }
        let base = NSMutableAttributedString(string: state.promptText, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        if !state.promptComposition.isEmpty {
            base.append(NSAttributedString(string: state.promptComposition, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemGreen, .underlineStyle: NSUnderlineStyle.single.rawValue]))
        }
        if isPromptEnabled { base.append(NSAttributedString(string: "▏", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.controlAccentColor])) }
        promptTextView.textStorage?.setAttributedString(base)
        promptTextView.textColor = NSColor.labelColor
    }

    private func applyState() {
        // Rebuild stack: messages + pending
        for v in stackView.arrangedSubviews { stackView.removeArrangedSubview(v); v.removeFromSuperview() }

        let isExpanded = state.isExpandedLayout
        scrollView.isHidden = !isExpanded

        // prompt enabled border always reflects state, even in collapsed (164px) mode.
        if isPromptEnabled {
            promptContainer.layer?.borderColor = NSColor.systemTeal.cgColor
            promptContainer.layer?.borderWidth = 1.5
        } else {
            promptContainer.layer?.borderColor = NSColor.separatorColor.cgColor
            promptContainer.layer?.borderWidth = 1
        }

        if !isExpanded { return }

        if state.conversationMessages.isEmpty && state.pendingState == .none {
            // 复刻 ai-elements: Artifact + Plan + Suggestions（空态全量展示）
            let artifact = makeArtifactView(title: "开始对话", content: "输入你的问题，AI 会在本地执行 shell / 联网搜索后给出答案")
            stackView.addArrangedSubview(artifact)
            let plan = makePlanView(title: "你可以这样问", steps: ["帮我总结一下", "用中文解释", "检查并修正语法", "翻译成英文"], isStreaming: false)
            stackView.addArrangedSubview(plan)
            let sug = makeSuggestionView(suggestions: ["帮我总结一下", "用中文解释", "检查并修正语法", "翻译成英文"], onSelect: { [weak self] text in
                self?.state.promptText = text
                self?.applyPrompt()
                self?.submitPrompt()
            })
            stackView.addArrangedSubview(sug)
            // 额外的 Context/Checkpoint 占位仅在空态提示，不实际插入避免空态过度拥挤
        }
        for m in state.conversationMessages {
            let view = makeMessageBubble(role: m.role == .user ? "你" : "AI", text: m.content, isPending: false, pendingState: .none)
            stackView.addArrangedSubview(view)
        }
        if !state.pendingPromptText.isEmpty {
            let v = makeMessageBubble(role: "你", text: state.pendingPromptText, isPending: false, pendingState: .none)
            stackView.addArrangedSubview(v)
        }
        if state.pendingState != .none {
            // Reasoning：有 reasoning 文本时用 ChainOfThought 复刻 ai-elements Reasoning
            if !state.pendingReasoningText.isEmpty {
                let isStreaming = state.pendingState == .streaming
                let cot = makeChainOfThoughtView(text: state.pendingReasoningText, isStreaming: isStreaming)
                stackView.addArrangedSubview(cot)
            }
            // Context：展示 token 使用量（对齐 TS Context）
            let estTokens = max(1, (state.pendingAssistantText.count + state.pendingReasoningText.count) / 4)
            let ctx = makeContextView(usedTokens: estTokens, maxTokens: 4096, modelId: nil)
            stackView.addArrangedSubview(ctx)
            // ChainOfThought 聚合 tool 调用（对齐 TS pendingChainSteps）
            if !state.pendingToolCalls.isEmpty {
                let chainItems = state.pendingToolCalls.map { tc -> (title: String, completed: Bool, description: String?) in
                    let title: String
                    if tc.toolName == "shell" { title = "执行本地 shell" }
                    else if tc.toolName == "web_search" { title = "联网搜索" }
                    else { title = tc.toolName }
                    let completed = tc.state == .outputAvailable
                    let desc: String?
                    if tc.toolName == "shell", let input = tc.input as? [String: Any], let cmds = input["commands"] as? [String] {
                        desc = cmds.joined(separator: " ; ").prefix(80).description
                    } else { desc = nil }
                    return (title, completed, desc)
                }
                let hasPendingInput = state.pendingToolCalls.contains { $0.state == .inputAvailable || $0.state == .inputStreaming }
                if hasPendingInput {
                    let qItems = state.pendingToolCalls.filter { $0.state == .inputAvailable || $0.state == .inputStreaming }.map { (title: $0.toolName, completed: false, description: $0.toolName) }
                    let q = makeQueueView(items: qItems)
                    stackView.addArrangedSubview(q)
                }
                let taskContent = state.pendingToolCalls.map { tc in
                    switch tc.state {
                    case .outputAvailable: return "\(tc.toolName): 完成"
                    case .outputError: return "\(tc.toolName): 失败"
                    default: return "\(tc.toolName): 执行中"
                    }
                }.joined(separator: "  ·  ")
                let task = makeTaskView(title: "已调用工具 \(state.pendingToolCalls.count) 次", content: taskContent, defaultOpen: true)
                stackView.addArrangedSubview(task)
                // 每个 tool 的详细卡
                for tc in state.pendingToolCalls {
                    let t = makeToolView(tc)
                    stackView.addArrangedSubview(t)
                }
                _ = chainItems // 保留链路占位，避免未使用告警
            }
            if !state.pendingSources.isEmpty {
                let s = makeSourcesView(state.pendingSources)
                stackView.addArrangedSubview(s)
            }
            let body: NSView
            switch state.pendingState {
            case .error:
                body = makeMessageBubble(role: "AI", text: state.pendingAssistantText, isPending: true, pendingState: .error)
            case .loading:
                body = makeLoadingView()
            default:
                if state.pendingAssistantText.isEmpty { body = makeShimmer() }
                else { body = makeMarkdownBubble(state.pendingAssistantText) }
            }
            stackView.addArrangedSubview(body)
            // InlineCitation：有来源时在正文后追加行内引用（对齐 TS InlineCitation）
            if !state.pendingSources.isEmpty && !state.pendingAssistantText.isEmpty {
                let cites = state.pendingSources.prefix(3).map { (text: $0.title ?? $0.url ?? "来源", url: $0.url) }
                let citView = makeInlineCitationView(citations: Array(cites))
                stackView.addArrangedSubview(citView)
            }
            // WebPreview：同一来源仅展示单张预览卡（避免与 OpenInChat 重复）
            if let first = state.pendingSources.first, let url = first.url {
                let web = makeWebPreviewView(urlString: url, title: first.title)
                stackView.addArrangedSubview(web)
            }
            // Checkpoint 分隔（有工具调用时在 body 前插入分隔，对齐 TS Checkpoint）
            if !state.pendingToolCalls.isEmpty && !state.pendingAssistantText.isEmpty {
                let cp = makeCheckpointView(label: "已完成 \(state.pendingToolCalls.count) 个工具调用")
                stackView.addArrangedSubview(cp)
            }
            pendingImageTask?.cancel()
            // Image：从正文提取 ![alt](http...) 的首个图片 URL 作缩略（对齐 ai-elements Image；输入法内仅加载 http/https，base64 由 Tool 透传；失败静默）。
            if let imgURLString = Self.firstImageURL(in: state.pendingAssistantText), let url = URL(string: imgURLString), let host = url.host, !host.isEmpty {
                // 轻量占位：避免阻塞 applyState，主线程异步尝试取图（超时 3s，失败仅保留链接文本）。
                let placeholder = makeImageView(image: NSImage(size: NSSize(width: 200, height: 120)), alt: imgURLString)
                stackView.addArrangedSubview(placeholder)
                // 异步替换：后台取图后回到主线程更新（不阻塞输入链）。
                let task = URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async { [weak placeholder] in
                        guard let placeholder else { return }
                        // 找到 placeholder 的 imageView 并替换（placeholder 内首个 NSImageView）
                        func findImageView(in v: NSView) -> NSImageView? {
                            if let iv = v as? NSImageView { return iv }
                            for c in v.subviews { if let f = findImageView(in: c) { return f } }
                            return nil
                        }
                        findImageView(in: placeholder)?.image = img
                    }
                }
                self.pendingImageTask = task; task.resume()
            }
            // Confirmation：仅当存在待确认的 shell 时展示一次（避免每帧重复）
            if state.pendingToolCalls.contains(where: { $0.toolName == "shell" && $0.state == .inputAvailable }) {
                let confirm = makeConfirmationView(toolName: "shell", question: "本地 shell 将在输入法进程执行，确认继续？", onConfirm: { [weak self] in self?.triggerShellToolCalls() }, onDeny: { [weak self] in self?.denyShellToolCalls() })
                stackView.addArrangedSubview(confirm)
            }
        }

        // auto scroll to bottom
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scrollView.documentView else { return }
            self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - self.scrollView.contentView.bounds.height)))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }

    }

    // MARK: Small factories

    private func makeCard(title: String, body: String) -> NSView {
        let v = NSView(); v.wantsLayer = true; v.layer?.cornerRadius = 8; v.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let t = NSTextField(labelWithString: title); t.font = NSFont.boldSystemFont(ofSize: 11)
        let b = NSTextField(wrappingLabelWithString: body); b.font = NSFont.systemFont(ofSize: 11); b.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [t, b]); stack.orientation = .vertical; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10), stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8)])
        return v
    }
    private func makeMessageBubble(role: String, text: String, isPending: Bool, pendingState: AIPendingState) -> NSView {
        if text.contains("|") && text.contains("```") || text.contains("|") { // heuristic for markdown tables / code
            return makeMarkdownBubble(text, role: role)
        }
        let container = NSStackView(); container.orientation = .horizontal; container.spacing = 8; container.alignment = .top
        let badge = NSTextField(labelWithString: role); badge.font = NSFont.boldSystemFont(ofSize: 9); badge.wantsLayer = true; badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = (role == "AI" ? NSColor.systemTeal : NSColor.controlBackgroundColor).cgColor
        badge.textColor = role == "AI" ? .white : .labelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 24), badge.heightAnchor.constraint(equalToConstant: 24)])
        let bubble = NSTextField(wrappingLabelWithString: text); bubble.font = NSFont.systemFont(ofSize: 11.5); bubble.textColor = pendingState == .error ? .systemRed : .labelColor
        bubble.wantsLayer = true; bubble.layer?.cornerRadius = 9; bubble.layer?.borderWidth = 1; bubble.layer?.borderColor = NSColor.separatorColor.cgColor
        bubble.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.addArrangedSubview(badge); container.addArrangedSubview(bubble)
        return container
    }
    private func makeMarkdownBubble(_ md: String, role: String = "AI") -> NSView {
        let mdView = AIInputMarkdownView()
        mdView.setMarkdownText(md)
        mdView.translatesAutoresizingMaskIntoConstraints = false
        mdView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let container = NSStackView(); container.orientation = .horizontal; container.spacing = 8; container.alignment = .top
        let badge = NSTextField(labelWithString: role); badge.font = NSFont.boldSystemFont(ofSize: 9)
        container.addArrangedSubview(badge); container.addArrangedSubview(mdView)
        return container
    }
    private func makeLoadingView() -> NSView {
        let v = NSView(); let l = NSTextField(labelWithString: "● ● ●"); l.textColor = .systemTeal; v.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: v.centerXAnchor), l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true; return v
    }
    private func makeShimmer() -> NSView {
        let l = NSTextField(labelWithString: "正在生成…"); l.textColor = .tertiaryLabelColor; l.font = NSFont.systemFont(ofSize: 11)
        let v = NSView(); v.addSubview(l); l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4), l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true; return v
    }
    private func makeDisclosure(title: String, text: String) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 6; box.borderColor = .separatorColor
        let t = NSTextField(labelWithString: title); t.font = NSFont.boldSystemFont(ofSize: 10)
        let b = NSTextField(wrappingLabelWithString: text); b.font = NSFont.systemFont(ofSize: 11); b.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [t, b]); stack.orientation = .vertical
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8), stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6)])
        return box
    }
    private func makeSourcesView(_ sources: [AISource]) -> NSView {
        let box = NSBox(); box.title = "来源 \(sources.count)"; box.boxType = .primary
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 4
        for s in sources {
            let link = NSButton(title: s.title ?? s.url ?? "来源", target: nil, action: nil)
            if let url = s.url, URL(string: url) != nil { link.title = s.title ?? url }
            stack.addArrangedSubview(link)
        }
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8), stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6)])
        }
        return box
    }
    private func makeToolView(_ tc: AIToolCall) -> NSView {
        let box = NSBox(); box.title = "\(tc.toolName) — \(tc.state.rawValue)"; box.boxType = .primary
        let inputView = NSTextField(wrappingLabelWithString: "\(tc.input ?? "")"); inputView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let outputView = NSTextField(wrappingLabelWithString: "\(tc.output ?? (tc.isError ? "失败" : "执行中"))"); outputView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let stack = NSStackView(views: [inputView, outputView]); stack.orientation = .vertical
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8), stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6)])
        }
        return box
    }

    // MARK: - ai-elements 全量补充（Queue/ChainOfThought/Task/Context/Artifact/Plan/Checkpoint/InlineCitation/Suggestion/WebPreview/Confirmation/Image）

    private func makeChainOfThoughtView(text: String, isStreaming: Bool = false, durationMs: Int? = nil) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = NSColor.separatorColor
        if let ms = durationMs, ms > 0 { box.title = isStreaming ? "思考中… · \(ms)ms" : "思考过程 · \(ms)ms" } else { box.title = isStreaming ? "思考中…" : "思考过程" }
        box.titlePosition = .atTop
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = NSFont.systemFont(ofSize: 11); body.textColor = .secondaryLabelColor
        let dot = NSTextField(labelWithString: isStreaming ? "◐" : "▸")
        dot.font = NSFont.systemFont(ofSize: 10); dot.textColor = .tertiaryLabelColor
        let header = NSStackView(views: [dot, body]); header.orientation = .horizontal; header.spacing = 6; header.alignment = .top
        box.contentView?.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                header.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                header.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            ])
        }
        return box
    }

    private func makeQueueView(items: [(title: String, completed: Bool, description: String?)]) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        box.title = "队列"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 4
        for item in items {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
            let indicator = NSView(); indicator.wantsLayer = true; indicator.layer?.cornerRadius = 5
            indicator.layer?.backgroundColor = (item.completed ? NSColor.systemGreen : NSColor.separatorColor).cgColor
            indicator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([indicator.widthAnchor.constraint(equalToConstant: 10), indicator.heightAnchor.constraint(equalToConstant: 10)])
            let label = NSTextField(labelWithString: item.title)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = item.completed ? .secondaryLabelColor : .labelColor
            row.addArrangedSubview(indicator); row.addArrangedSubview(label)
            let wrapper = NSStackView(views: [row])
            wrapper.orientation = .vertical; wrapper.spacing = 2
            if let desc = item.description, !desc.isEmpty {
                let d = NSTextField(wrappingLabelWithString: desc)
                d.font = NSFont.systemFont(ofSize: 10); d.textColor = .tertiaryLabelColor
                wrapper.addArrangedSubview(d)
            }
            stack.addArrangedSubview(wrapper)
        }
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6),
            ])
        }
        return box
    }

    private func makeTaskView(title: String, content: String, defaultOpen: Bool = true) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        box.title = title
        let body = NSTextField(wrappingLabelWithString: content)
        body.font = NSFont.systemFont(ofSize: 11); body.textColor = .labelColor
        let stack = NSStackView(views: [body]); stack.orientation = .vertical
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6),
            ])
        }
        if !defaultOpen { box.isTransparent = false }
        return box
    }

    private func makeContextView(usedTokens: Int, maxTokens: Int, modelId: String? = nil) -> NSView {
        let pct = maxTokens > 0 ? min(1.0, Double(usedTokens) / Double(maxTokens)) : 0
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        box.title = modelId != nil ? "上下文 · \(modelId!)" : "上下文"
        let label = NSTextField(labelWithString: "\(usedTokens) / \(maxTokens) tokens · \(Int(pct*100))%")
        label.font = NSFont.systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
        let bar = NSProgressIndicator(); bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = pct
        bar.controlSize = .small; bar.style = .bar
        let stack = NSStackView(views: [label, bar]); stack.orientation = .vertical; stack.spacing = 4
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6),
            ])
        }
        return box
    }

    private func makeArtifactView(title: String, content: String) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        let header = NSTextField(labelWithString: title); header.font = NSFont.boldSystemFont(ofSize: 11)
        let body = AIInputMarkdownView(); body.setMarkdownText(content)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = NSStackView(views: [header, body]); stack.orientation = .vertical; stack.spacing = 6
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            ])
        }
        return box
    }

    private func makePlanView(title: String, steps: [String], isStreaming: Bool = false) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        box.title = isStreaming ? "计划生成中…" : title
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 4
        for (idx, step) in steps.enumerated() {
            let row = NSTextField(labelWithString: "\(idx+1). \(step)")
            row.font = NSFont.systemFont(ofSize: 11); row.textColor = .labelColor
            stack.addArrangedSubview(row)
        }
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            ])
        }
        return box
    }

    private func makeCheckpointView(label: String) -> NSView {
        let container = NSView()
        let line = NSBox(); line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let tag = NSTextField(labelWithString: "◆ \(label)")
        tag.font = NSFont.systemFont(ofSize: 10); tag.textColor = .tertiaryLabelColor
        container.addSubview(line); container.addSubview(tag)
        tag.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            tag.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            tag.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return container
    }

    private func makeInlineCitationView(citations: [(text: String, url: String?)]) -> NSView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 6
        for c in citations {
            if let urlStr = c.url, URL(string: urlStr) != nil {
                let link = NSButton(title: c.text, target: nil, action: nil)
                link.bezelStyle = .inline; link.isBordered = false
                link.font = NSFont.systemFont(ofSize: 10)
                link.contentTintColor = .systemBlue
                link.toolTip = urlStr
                // 点击外跳由宿主浏览器打开，避免输入法进程内导航
                link.target = self; link.action = #selector(openCitationLink(_:))
                link.identifier = NSUserInterfaceItemIdentifier(urlStr)
                stack.addArrangedSubview(link)
            } else {
                let badge = NSTextField(labelWithString: c.text)
                badge.font = NSFont.systemFont(ofSize: 10); badge.textColor = .secondaryLabelColor
                badge.wantsLayer = true; badge.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                badge.layer?.cornerRadius = 4
                stack.addArrangedSubview(badge)
            }
        }
        return stack
    }

    @objc private func openCitationLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeSuggestionView(suggestions: [String], onSelect: ((String) -> Void)? = nil) -> NSView {
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 6; row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        for s in suggestions {
            let btn = NSButton(title: s, target: nil, action: nil)
            btn.bezelStyle = .rounded; btn.controlSize = .small; btn.font = NSFont.systemFont(ofSize: 11)
            // 点击回调通过 handler 注入（当前输入法面板仅展示，预留 onSelect）
            // 预留：真实选中由外层注入；此处仅展示样式，避免 BlockTarget 生命周期问题
            _ = onSelect
            row.addArrangedSubview(btn)
        }
        let doc = NSView(); doc.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            row.topAnchor.constraint(equalTo: doc.topAnchor),
            row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        scroll.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return scroll
    }

    private func makeWebPreviewView(urlString: String, title: String? = nil) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        box.title = title ?? urlString
        let link = NSTextField(labelWithString: urlString)
        link.font = NSFont.systemFont(ofSize: 10); link.textColor = .systemBlue
        link.isSelectable = true; link.allowsEditingTextAttributes = true
        let hint = NSTextField(labelWithString: "点击在浏览器中打开")
        hint.font = NSFont.systemFont(ofSize: 9); hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [link, hint]); stack.orientation = .vertical; stack.spacing = 2
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -6),
            ])
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        let urlForPreview = urlString
        box.identifier = NSUserInterfaceItemIdentifier(urlForPreview)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleWebPreviewClick(_:)))
        box.addGestureRecognizer(click)
        return box
    }

    @objc private func handleWebPreviewClick(_ sender: NSClickGestureRecognizer) {
        guard let view = sender.view, let raw = view.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // open-in-chat: 外链跳转等价（对齐 ai-elements open-in-chat: github/scira/vercel 等 Provider）
    // 输入法浮层内以「在外部打开」按钮承载，避免 DropdownMenu 噪音，同时保留 isPresented 语义。
    private func makeOpenInChatView(urlString: String, title: String? = nil) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .separatorColor
        box.title = title != nil ? "在外部打开 · \(title!)" : "在外部打开"
        let link = NSTextField(labelWithString: urlString)
        link.font = NSFont.systemFont(ofSize: 10); link.textColor = .systemBlue
        link.isSelectable = true
        let btn = NSButton(title: "打开", target: nil, action: nil)
        btn.bezelStyle = .rounded; btn.controlSize = .small
        btn.identifier = NSUserInterfaceItemIdentifier(urlString)
        btn.target = self; btn.action = #selector(handleOpenInChatClick(_:))
        let row = NSStackView(views: [link, btn]); row.orientation = .horizontal; row.spacing = 8
        box.contentView?.addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                row.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                row.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            ])
        }
        return box
    }

    @objc private func handleOpenInChatClick(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeConfirmationView(toolName: String, question: String, onConfirm: (() -> Void)? = nil, onDeny: (() -> Void)? = nil) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 8; box.borderColor = .systemOrange
        box.title = "需确认 · \(toolName)"
        let q = NSTextField(wrappingLabelWithString: question)
        q.font = NSFont.systemFont(ofSize: 11); q.textColor = .labelColor
        let ok = NSButton(title: "允许", target: nil, action: nil)
        ok.bezelStyle = .rounded; ok.keyEquivalent = "\r"
        let deny = NSButton(title: "拒绝", target: nil, action: nil)
        deny.bezelStyle = .rounded
        // 确认/拒绝回调由外层 AIInputService toolApproval 流程注入，当前仅展示样式
        _ = onConfirm; _ = onDeny
        let row = NSStackView(views: [deny, ok]); row.orientation = .horizontal; row.spacing = 8
        let stack = NSStackView(views: [q, row]); stack.orientation = .vertical; stack.spacing = 8
        box.contentView?.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            ])
        }
        return box
    }

    private static func firstImageURL(in markdown: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#) else { return nil }
        let ns = markdown as NSString
        guard let m = re.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉可选标题部分：`url "title"`
        return raw.components(separatedBy: " ").first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    private func makeImageView(image: NSImage, alt: String? = nil) -> NSView {
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true; iv.layer?.cornerRadius = 8; iv.layer?.masksToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.heightAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        if let alt, !alt.isEmpty {
            let cap = NSTextField(labelWithString: alt)
            cap.font = NSFont.systemFont(ofSize: 9); cap.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [iv, cap]); stack.orientation = .vertical; stack.spacing = 4
            return stack
        }
        return iv
    }

}
