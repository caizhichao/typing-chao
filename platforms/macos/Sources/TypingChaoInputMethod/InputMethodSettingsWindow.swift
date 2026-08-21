import AppKit

// Swift 原生设置窗口：彻底移除 WKWebView，复刻 SettingsApp.tsx 三标签与所有控件。
final class InputMethodSettingsWindowController: NSWindowController {
    static let shared = InputMethodSettingsWindowController()

    private let settingsViewController = InputMethodSettingsViewController()
    private weak var inputController: TypingChaoInputController?
    private var hasPositionedWindow = false

    private init() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Typing Chao 设置"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.tabbingMode = .disallowed
        settingsViewController.preferredContentSize = NSSize(width: 700, height: 700)
        settingsWindow.contentViewController = settingsViewController
        settingsWindow.setContentSize(NSSize(width: 700, height: 700))
        settingsWindow.contentMinSize = NSSize(width: 700, height: 700)
        settingsWindow.contentMaxSize = NSSize(width: 700, height: 700)
        super.init(window: settingsWindow)

        settingsViewController.translationEnabledHandler = { [weak self] enabled in
            if let ic = self?.inputController { ic.setTranslationEnabled(enabled); return }
            InputMethodSettings.shared.setTranslationEnabled(enabled)
        }
        settingsViewController.targetLanguageHandler = { [weak self] lang in
            if let ic = self?.inputController { ic.setTranslationTargetLanguage(lang); return }
            InputMethodSettings.shared.setTargetLanguage(lang)
        }
        settingsViewController.aiServiceProviderHandler = { provider in InputMethodSettings.shared.setAIServiceProvider(provider) }
        settingsViewController.apiKeyHandler = { key in InputMethodSettings.shared.setCurrentAPIKey(key) }
        settingsViewController.baseURLHandler = { url in InputMethodSettings.shared.setCurrentBaseURL(url) }
        settingsViewController.rimeOptionHandler = { [weak self] list in
            if let ic = self?.inputController { ic.applyRimeOptionStateList(list); return }
            InputMethodSettings.shared.persistRimeOptionStateList(list)
        }
        settingsViewController.schemaHandler = { [weak self] id in self?.inputController?.selectRimeSchema(id) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(inputController: TypingChaoInputController, snapshot: RimeSnapshot, schemaList: [RimeSchemaItem]) {
        self.inputController = inputController
        settingsViewController.configure(snapshot: snapshot, schemaList: schemaList)
        if !hasPositionedWindow { window?.center(); hasPositionedWindow = true }
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class InputMethodSettingsViewController: NSViewController {
    var translationEnabledHandler: ((Bool) -> Void)?
    var targetLanguageHandler: ((TranslationTargetLanguage) -> Void)?
    var aiServiceProviderHandler: ((AIServiceProvider) -> Void)?
    var apiKeyHandler: ((String) -> Bool)?
    var baseURLHandler: ((String) -> Bool)?
    var rimeOptionHandler: (([RimeOptionState]) -> Void)?
    var schemaHandler: ((String) -> Void)?

    private var modelFetchTask: Task<Void, Never>?
    private var currentSchemaList: [RimeSchemaItem] = []
    private var selectedSchemaIdentifier = ""
    private var inputModeIdentifier = "chinese"
    private var characterFormIdentifier = "simplified"
    private var punctuationModeIdentifier = "chinese"
    private var characterWidthIdentifier = "half"
    private var displayedModelNameList: [String] = []

    // UI
    private let sidebarView = NSView()
    private let contentScrollView = NSScrollView()
    private let contentStack = NSStackView()
    private var activeSection: Section = .translation
    private var toastLabel: NSTextField?
    private var toastTimer: Timer?
    private enum Section { case translation, aiInput, input }

    // translation
    private var translationSwitch: NSButton!
    private var targetLanguagePopup: NSPopUpButton!
    private var serviceProviderPopup: NSPopUpButton!
    private var apiKeyField: NSSecureTextField!
    private var baseURLField: NSTextField!
    private var modelPopup: NSPopUpButton!
    private var fetchModelButton: NSButton!
    // ai-input
    private var systemPromptTextView: NSTextView!
    // input
    private var schemaPopup: NSPopUpButton!
    private var inputModeSegment: NSSegmentedControl!
    private var charFormSegment: NSSegmentedControl!
    private var punctSegment: NSSegmentedControl!
    private var widthSegment: NSSegmentedControl!

    deinit { modelFetchTask?.cancel() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        view.wantsLayer = true
        buildLayout()
        refreshUIFromSettings()
    }

    func configure(snapshot: RimeSnapshot, schemaList: [RimeSchemaItem]) {
        _ = view
        currentSchemaList = schemaList
        selectedSchemaIdentifier = snapshot.schemaIdentifier
        inputModeIdentifier = snapshot.isAsciiMode ? "english" : "chinese"
        characterFormIdentifier = snapshot.isSimplifiedChinese ? "simplified" : "traditional"
        punctuationModeIdentifier = snapshot.isAsciiPunctuation ? "western" : "chinese"
        characterWidthIdentifier = snapshot.isFullShape ? "full" : "half"
        resetDisplayedModelNameList()
        refreshUIFromSettings()
        rebuildContent()
    }

    // MARK: Layout

    private func buildLayout() {
        // sidebar 168
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 0.9).cgColor
        view.addSubview(sidebarView)

        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.drawsBackground = false
        contentScrollView.borderType = .noBorder
        contentScrollView.autohidesScrollers = true
        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 30, bottom: 24, right: 30)
        docView.addSubview(contentStack)
        contentScrollView.documentView = docView
        view.addSubview(contentScrollView)

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 168),

            contentScrollView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: docView.topAnchor),
        ])
        buildSidebar()
        rebuildContent()
    }

    private var navButtons: [NSButton] = []
    private func buildSidebar() {
        let brand = NSTextField(labelWithString: "Typing Chao")
        brand.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        brand.textColor = NSColor(calibratedWhite: 0.08, alpha: 0.92)
        brand.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: "通用 AI 输入法")
        subtitle.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 0.3, alpha: 0.55)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let versionLabel = NSTextField(labelWithString: versionText())
        versionLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        versionLabel.textColor = NSColor(calibratedWhite: 0.3, alpha: 0.55)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.wantsLayer = true
        versionLabel.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.07).cgColor
        versionLabel.layer?.cornerRadius = 8
        versionLabel.alignment = .center

        let navStack = NSStackView()
        navStack.orientation = .vertical
        navStack.spacing = 4
        navStack.translatesAutoresizingMaskIntoConstraints = false

        func navButton(title: String, section: Section) -> NSButton {
            let b = NSButton(title: title, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.isBordered = false
            b.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            b.contentTintColor = section == activeSection ? NSColor(calibratedRed: 0.03, green: 0.60, blue: 0.53, alpha: 1) : NSColor(calibratedWhite: 0.25, alpha: 0.75)
            b.wantsLayer = true
            b.layer?.backgroundColor = (section == activeSection ? NSColor(calibratedRed: 0.03, green: 0.60, blue: 0.53, alpha: 0.12) : NSColor.clear).cgColor
            b.layer?.cornerRadius = 8
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
            b.target = self
            b.action = section == .translation ? #selector(selectTranslation) : section == .aiInput ? #selector(selectAIInput) : #selector(selectInputSection)
            return b
        }

        let b1 = navButton(title: "  译  翻译与 AI", section: .translation)
        let b2 = navButton(title: "  ✦  AI 问答", section: .aiInput)
        let b3 = navButton(title: "  ⌨  输入", section: .input)
        navButtons = [b1, b2, b3]
        for b in navButtons { navStack.addArrangedSubview(b) }

        let footer = NSTextField(wrappingLabelWithString: "设置只保存在本机\n不修改系统输入源")
        footer.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        footer.textColor = NSColor(calibratedWhite: 0.3, alpha: 0.45)
        footer.translatesAutoresizingMaskIntoConstraints = false

        sidebarView.addSubview(brand)
        sidebarView.addSubview(subtitle)
        sidebarView.addSubview(versionLabel)
        sidebarView.addSubview(navStack)
        sidebarView.addSubview(footer)

        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 14),
            brand.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 22),
            subtitle.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 14),
            subtitle.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 2),
            versionLabel.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            versionLabel.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -12),
            versionLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            versionLabel.heightAnchor.constraint(equalToConstant: 22),

            navStack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            navStack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -12),
            navStack.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 18),

            footer.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -18),
        ])
    }

    @objc private func selectTranslation() { activeSection = .translation; updateSidebarSelection(); rebuildContent() }
    @objc private func selectAIInput() { activeSection = .aiInput; updateSidebarSelection(); rebuildContent() }
    @objc private func selectInputSection() { activeSection = .input; updateSidebarSelection(); rebuildContent() }

    private func updateSidebarSelection() {
        for (idx, b) in navButtons.enumerated() {
            let sec: Section = idx == 0 ? .translation : idx == 1 ? .aiInput : .input
            let active = sec == activeSection
            b.contentTintColor = active ? NSColor(calibratedRed: 0.03, green: 0.60, blue: 0.53, alpha: 1) : NSColor(calibratedWhite: 0.25, alpha: 0.75)
            b.layer?.backgroundColor = (active ? NSColor(calibratedRed: 0.03, green: 0.60, blue: 0.53, alpha: 0.12) : NSColor.clear).cgColor
        }
    }

    private func versionText() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if v.isEmpty && b.isEmpty { return "正在读取版本…" }
        if b.isEmpty { return "版本 \(v)" }
        return "版本 \(v) (\(b))"
    }

    // MARK: Content

    private func rebuildContent() {
        for v in contentStack.arrangedSubviews { contentStack.removeArrangedSubview(v); v.removeFromSuperview() }
        switch activeSection {
        case .translation: buildTranslationSection()
        case .aiInput: buildAIInputSection()
        case .input: buildInputSection()
        }
        refreshUIFromSettings()
    }

    private func header(title: String, subtitle: String) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        let s = NSTextField(wrappingLabelWithString: subtitle)
        s.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        s.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [t, s])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        return stack
    }

    private func card(_ rows: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = NSColor.separatorColor
        box.borderWidth = 1
        box.cornerRadius = 12
        box.titlePosition = .noTitle
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        box.contentView?.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cv.topAnchor),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
        }
        // separators
        for idx in 1..<rows.count {
            let sep = NSBox()
            sep.boxType = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            // Add as subview of stack wrapper trick: insert separator view between rows by adding to row container
            // Simpler: add border to row itself via layer
            rows[idx].wantsLayer = true
            rows[idx].layer?.borderWidth = 0.5
            rows[idx].layer?.borderColor = NSColor.separatorColor.cgColor
        }
        return box
    }

    private func settingsRow(title: String, subtitle: String, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let subLabel = NSTextField(wrappingLabelWithString: subtitle)
        subLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        subLabel.preferredMaxLayoutWidth = 300
        let left = NSStackView(views: [titleLabel, subLabel])
        left.orientation = .vertical
        left.spacing = 2
        left.alignment = .leading

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [left, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        // Make left expand
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
        return row
    }

    private func buildTranslationSection() {
        contentStack.addArrangedSubview(header(title: "翻译与 AI", subtitle: "管理边写边译、AI 问答服务和本机凭据。"))

        translationSwitch = NSButton()
        translationSwitch.setButtonType(.switch)
        translationSwitch.title = ""
        translationSwitch.target = self
        translationSwitch.action = #selector(toggleTranslation(_:))

        targetLanguagePopup = NSPopUpButton()
        targetLanguagePopup.target = self
        targetLanguagePopup.action = #selector(changeTargetLanguage(_:))
        for lang in TranslationTargetLanguage.allCases {
            targetLanguagePopup.addItem(withTitle: lang.displayName)
            targetLanguagePopup.lastItem?.representedObject = lang.rawValue
        }

        serviceProviderPopup = NSPopUpButton()
        serviceProviderPopup.target = self
        serviceProviderPopup.action = #selector(changeServiceProvider(_:))
        for p in AIServiceProvider.allCases {
            serviceProviderPopup.addItem(withTitle: p.displayName)
            serviceProviderPopup.lastItem?.representedObject = p.rawValue
        }

        let card1 = card([
            settingsRow(title: "边写边译", subtitle: "拼音提交后稳定等待 1 秒；粘贴时只处理剪贴板文本", control: translationSwitch),
            settingsRow(title: "目标语言", subtitle: "译文会按这里选择的语言生成", control: targetLanguagePopup),
            settingsRow(title: "AI 服务", subtitle: "翻译和 AI 问答共用此请求协议", control: serviceProviderPopup),
        ])
        contentStack.addArrangedSubview(card1)

        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "输入 API Key"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let pasteBtn = NSButton(title: "粘贴", target: self, action: #selector(pasteAPIKey))
        pasteBtn.bezelStyle = .rounded
        let saveKeyBtn = NSButton(title: "保存", target: self, action: #selector(saveAPIKey))
        saveKeyBtn.bezelStyle = .rounded
        saveKeyBtn.keyEquivalent = ""
        let clearKeyBtn = NSButton(title: "清除", target: self, action: #selector(clearAPIKey))
        clearKeyBtn.bezelStyle = .rounded
        let keyRowControl = NSStackView(views: [apiKeyField, pasteBtn, saveKeyBtn, clearKeyBtn])
        keyRowControl.spacing = 6
        keyRowControl.orientation = .horizontal

        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.example.com"
        baseURLField.translatesAutoresizingMaskIntoConstraints = false
        baseURLField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let saveURLBtn = NSButton(title: "保存", target: self, action: #selector(saveBaseURL))
        saveURLBtn.bezelStyle = .rounded
        let clearURLBtn = NSButton(title: "清除", target: self, action: #selector(clearBaseURL))
        clearURLBtn.bezelStyle = .rounded
        let urlRowControl = NSStackView(views: [baseURLField, saveURLBtn, clearURLBtn])
        urlRowControl.spacing = 6

        modelPopup = NSPopUpButton()
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        modelPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        fetchModelButton = NSButton(title: "拉取", target: self, action: #selector(fetchModelList))
        fetchModelButton.bezelStyle = .rounded
        let modelRowControl = NSStackView(views: [modelPopup, fetchModelButton])
        modelRowControl.spacing = 6
        modelPopup.target = self
        modelPopup.action = #selector(changeModel(_:))

        let providerName = InputMethodSettings.shared.aiServiceProvider.displayName
        let card2 = card([
            settingsRow(title: "\(providerName) Key", subtitle: "只缓存在本机设置，不会进入 Web UI 状态或写入输入法包", control: keyRowControl),
            settingsRow(title: "Base URL", subtitle: "留空使用当前服务默认地址", control: urlRowControl),
            settingsRow(title: "模型", subtitle: "拉取当前服务模型列表后选择实际使用的模型", control: modelRowControl),
        ])
        contentStack.addArrangedSubview(card2)

        let hint = NSTextField(wrappingLabelWithString: "输入 = 后按 1 或回车，也可从输入法菜单打开 AI 输入。")
        hint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(hint)
    }

    private func buildAIInputSection() {
        contentStack.addArrangedSubview(header(title: "AI 问答", subtitle: "管理 AI 输入时携带的运行场景和最终上屏口径。"))

        let titleLabel = NSTextField(labelWithString: "AI 运行场景提示词")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let desc = NSTextField(wrappingLabelWithString: "每次 AI 输入都会附带这段上下文，默认说明结果会写入当前应用的输入框。可按自己的写作场景修改。")
        desc.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        desc.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        systemPromptTextView = NSTextView()
        systemPromptTextView.isEditable = true
        systemPromptTextView.isSelectable = true
        systemPromptTextView.font = NSFont.systemFont(ofSize: 12)
        systemPromptTextView.string = InputMethodSettings.shared.aiInputSystemPrompt
        systemPromptTextView.isVerticallyResizable = true
        systemPromptTextView.isHorizontallyResizable = false
        systemPromptTextView.textContainer?.widthTracksTextView = true
        scroll.documentView = systemPromptTextView

        let saveBtn = NSButton(title: "保存提示词", target: self, action: #selector(saveSystemPrompt))
        saveBtn.bezelStyle = .rounded
        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetSystemPrompt))
        resetBtn.bezelStyle = .rounded
        let btnRow = NSStackView(views: [saveBtn, resetBtn])
        btnRow.spacing = 6
        btnRow.orientation = .horizontal

        let box = NSBox()
        box.boxType = .custom
        box.borderColor = NSColor.separatorColor
        box.cornerRadius = 12
        box.titlePosition = .noTitle
        let inner = NSStackView(views: [titleLabel, desc, scroll, btnRow])
        inner.orientation = .vertical
        inner.spacing = 10
        inner.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        box.contentView?.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        if let cv = box.contentView {
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                inner.topAnchor.constraint(equalTo: cv.topAnchor),
                inner.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
        }
        contentStack.addArrangedSubview(box)
    }

    private func buildInputSection() {
        contentStack.addArrangedSubview(header(title: "输入", subtitle: "当前输入会话的方案、字形和标点设置。"))

        schemaPopup = NSPopUpButton()
        schemaPopup.target = self
        schemaPopup.action = #selector(changeSchema(_:))

        inputModeSegment = NSSegmentedControl(labels: ["中文", "英文"], trackingMode: .selectOne, target: self, action: #selector(changeInputMode(_:)))
        charFormSegment = NSSegmentedControl(labels: ["简体", "繁体"], trackingMode: .selectOne, target: self, action: #selector(changeCharForm(_:)))
        punctSegment = NSSegmentedControl(labels: ["中文", "西文"], trackingMode: .selectOne, target: self, action: #selector(changePunct(_:)))
        widthSegment = NSSegmentedControl(labels: ["半角", "全角"], trackingMode: .selectOne, target: self, action: #selector(changeWidth(_:)))

        let card1 = card([
            settingsRow(title: "拼音方案", subtitle: "可选择全拼、自然码双拼、小鹤双拼、九键或五笔", control: schemaPopup),
            settingsRow(title: "输入模式", subtitle: "在当前输入法内切换中文或英文", control: inputModeSegment),
            settingsRow(title: "汉字", subtitle: "默认使用简体中文", control: charFormSegment),
            settingsRow(title: "标点样式", subtitle: "中文或西文标点独立设置，不与字符宽度混为同一状态", control: punctSegment),
            settingsRow(title: "字符宽度", subtitle: "半角使用常规字符；全角转换拉丁字母、数字和空格宽度", control: widthSegment),
        ])
        contentStack.addArrangedSubview(card1)

        let hint = NSTextField(wrappingLabelWithString: "快捷切换：Shift + Space  切换半角与全角")
        hint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(hint)
    }

    // MARK: Refresh

    private func refreshUIFromSettings() {
        guard isViewLoaded else { return }
        let settings = InputMethodSettings.shared
        translationSwitch?.state = settings.isTranslationEnabled ? .on : .off
        if let popup = targetLanguagePopup {
            let idx = TranslationTargetLanguage.allCases.firstIndex { $0 == settings.targetLanguage } ?? 0
            popup.selectItem(at: idx)
        }
        if let popup = serviceProviderPopup {
            let idx = AIServiceProvider.allCases.firstIndex { $0 == settings.aiServiceProvider } ?? 0
            popup.selectItem(at: idx)
        }
        // apiKeyField placeholder: 已配置/未配置
        if let field = apiKeyField {
            let configured = settings.apiKey(for: settings.aiServiceProvider) != nil
            field.placeholderString = configured ? "已配置，输入新 Key 可覆盖" : "输入 \(settings.aiServiceProvider.apiKeyDisplayName)"
        }
        if let field = baseURLField {
            field.stringValue = settings.customBaseURL(for: settings.aiServiceProvider)?.absoluteString ?? ""
            field.placeholderString = settings.aiServiceProvider.defaultBaseURL.absoluteString
        }
        resetDisplayedModelNameList()
        if let popup = modelPopup {
            popup.removeAllItems()
            for name in displayedModelNameList { popup.addItem(withTitle: name) }
            popup.selectItem(withTitle: settings.modelName(for: settings.aiServiceProvider))
        }
        if let tv = systemPromptTextView { tv.string = settings.aiInputSystemPrompt }
        if let popup = schemaPopup {
            popup.removeAllItems()
            for item in currentSchemaList { popup.addItem(withTitle: item.displayName); popup.lastItem?.representedObject = item.identifier }
            popup.selectItem(withTitle: currentSchemaList.first(where: { $0.identifier == selectedSchemaIdentifier })?.displayName ?? "")
        }
        inputModeSegment?.selectedSegment = inputModeIdentifier == "english" ? 1 : 0
        charFormSegment?.selectedSegment = characterFormIdentifier == "traditional" ? 1 : 0
        punctSegment?.selectedSegment = punctuationModeIdentifier == "western" ? 1 : 0
        widthSegment?.selectedSegment = characterWidthIdentifier == "full" ? 1 : 0
    }

    // MARK: Actions

    @objc private func toggleTranslation(_ sender: NSButton) {
        let enabled = sender.state == .on
        translationEnabledHandler?(enabled)
        showToast(enabled ? "边写边译已开启" : "边写边译已关闭", isSuccess: true)
    }
    @objc private func changeTargetLanguage(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let lang = TranslationTargetLanguage(rawValue: raw) else { return }
        targetLanguageHandler?(lang)
        showToast("目标语言已切换为 \(lang.displayName)", isSuccess: true)
    }
    @objc private func changeServiceProvider(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let provider = AIServiceProvider(rawValue: raw) else { return }
        modelFetchTask?.cancel(); modelFetchTask = nil
        aiServiceProviderHandler?(provider)
        resetDisplayedModelNameList()
        refreshUIFromSettings()
        showToast("AI 服务已切换为 \(provider.displayName)", isSuccess: true)
    }
    @objc private func pasteAPIKey() {
        guard let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else {
            showToast("剪贴板中没有可粘贴的文本", isSuccess: false); return
        }
        apiKeyField?.stringValue = pasted
        showToast("已粘贴到输入框，请点击保存", isSuccess: true)
    }
    @objc private func saveAPIKey() {
        let key = apiKeyField?.stringValue ?? ""
        guard apiKeyHandler?(key) == true else { showToast("API Key 保存失败", isSuccess: false); return }
        apiKeyField?.stringValue = ""
        refreshUIFromSettings()
        showToast("API Key 已保存在本机", isSuccess: true)
    }
    @objc private func clearAPIKey() {
        guard apiKeyHandler?("") == true else { showToast("清除失败", isSuccess: false); return }
        apiKeyField?.stringValue = ""
        refreshUIFromSettings()
        showToast("API Key 已清除", isSuccess: true)
    }
    @objc private func saveBaseURL() {
        let url = baseURLField?.stringValue ?? ""
        guard baseURLHandler?(url) == true else { showToast("Base URL 必须以 http(s):// 开头且不带查询参数", isSuccess: false); return }
        refreshUIFromSettings()
        showToast(url.isEmpty ? "已恢复当前服务默认地址" : "Base URL 已保存", isSuccess: true)
    }
    @objc private func clearBaseURL() {
        guard baseURLHandler?("") == true else { showToast("清除失败", isSuccess: false); return }
        baseURLField?.stringValue = ""
        refreshUIFromSettings()
        showToast("已恢复当前服务默认地址", isSuccess: true)
    }
    @objc private func changeModel(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, !title.isEmpty else { return }
        guard InputMethodSettings.shared.setCurrentModelName(title) else { showToast("模型名称无效", isSuccess: false); return }
        resetDisplayedModelNameList(extraModelNameList: displayedModelNameList)
        showToast("模型已切换为 \(title)", isSuccess: true)
    }
    @objc private func fetchModelList() {
        guard let provider = AIServiceProvider.allCases.first(where: { $0.displayName == serviceProviderPopup?.titleOfSelectedItem }) ?? InputMethodSettings.shared.aiServiceProvider as AIServiceProvider? else { return }
        // Use current provider from settings (more reliable)
        let serviceProvider = InputMethodSettings.shared.aiServiceProvider
        modelFetchTask?.cancel()
        fetchModelButton?.isEnabled = false
        fetchModelButton?.title = "拉取中…"
        modelFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await TranslationService().fetchModelNameList(for: serviceProvider)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard InputMethodSettings.shared.aiServiceProvider == serviceProvider else { return }
                    self.modelFetchTask = nil
                    self.resetDisplayedModelNameList(extraModelNameList: list)
                    self.refreshUIFromSettings()
                    self.fetchModelButton?.isEnabled = true
                    self.fetchModelButton?.title = "拉取"
                    self.showToast("模型列表已更新 \(list.count) 项", isSuccess: true)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.modelFetchTask = nil
                    self.fetchModelButton?.isEnabled = true
                    self.fetchModelButton?.title = "拉取"
                    self.showToast("模型列表拉取失败：\(error.localizedDescription)", isSuccess: false)
                    NSLog("TypingChao model list request failed: %@", error.localizedDescription)
                }
            }
        }
    }
    @objc private func saveSystemPrompt() {
        let text = systemPromptTextView?.string ?? ""
        InputMethodSettings.shared.setAIInputSystemPrompt(text)
        showToast("AI 运行场景提示词已保存", isSuccess: true)
    }
    @objc private func resetSystemPrompt() {
        InputMethodSettings.shared.resetAIInputSystemPrompt()
        systemPromptTextView?.string = InputMethodSettings.shared.aiInputSystemPrompt
        showToast("已恢复默认 AI 运行场景提示词", isSuccess: true)
    }
    @objc private func changeSchema(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        selectedSchemaIdentifier = id
        schemaHandler?(id)
        showToast("拼音方案已切换", isSuccess: true)
    }
    @objc private func changeInputMode(_ sender: NSSegmentedControl) {
        let id = sender.selectedSegment == 1 ? "english" : "chinese"
        inputModeIdentifier = id
        rimeOptionHandler?([RimeOptionState(optionName: .asciiMode, isEnabled: id == "english")])
        showToast(id == "english" ? "已切换为英文模式" : "已切换为中文模式", isSuccess: true)
    }
    @objc private func changeCharForm(_ sender: NSSegmentedControl) {
        let id = sender.selectedSegment == 1 ? "traditional" : "simplified"
        characterFormIdentifier = id
        rimeOptionHandler?([
            RimeOptionState(optionName: .simplifiedChinese, isEnabled: id == "simplified"),
            RimeOptionState(optionName: .traditionalChinese, isEnabled: id == "traditional"),
            RimeOptionState(optionName: .hongKongTraditionalChinese, isEnabled: false),
            RimeOptionState(optionName: .taiwanTraditionalChinese, isEnabled: false),
        ])
        showToast(id == "traditional" ? "已切换为繁体" : "已切换为简体", isSuccess: true)
    }
    @objc private func changePunct(_ sender: NSSegmentedControl) {
        let id = sender.selectedSegment == 1 ? "western" : "chinese"
        punctuationModeIdentifier = id
        rimeOptionHandler?([RimeOptionState(optionName: .asciiPunctuation, isEnabled: id == "western")])
        showToast(id == "western" ? "已切换为西文标点" : "已切换为中文标点", isSuccess: true)
    }
    @objc private func changeWidth(_ sender: NSSegmentedControl) {
        let id = sender.selectedSegment == 1 ? "full" : "half"
        characterWidthIdentifier = id
        rimeOptionHandler?([RimeOptionState(optionName: .fullShape, isEnabled: id == "full")])
        showToast(id == "full" ? "已切换为全角" : "已切换为半角", isSuccess: true)
    }

    private func resetDisplayedModelNameList(extraModelNameList: [String] = []) {
        let provider = InputMethodSettings.shared.aiServiceProvider
        var seen = Set<String>()
        displayedModelNameList = ([InputMethodSettings.shared.modelName(for: provider)] + extraModelNameList).filter { seen.insert($0).inserted }
    }

    private func showToast(_ text: String, isSuccess: Bool) {
        toastTimer?.invalidate()
        toastLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = (isSuccess ? NSColor(calibratedRed: 0.03, green: 0.6, blue: 0.53, alpha: 0.92) : NSColor(calibratedRed: 0.77, green: 0.27, blue: 0.22, alpha: 0.92)).cgColor
        label.layer?.cornerRadius = 6
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            label.heightAnchor.constraint(equalToConstant: 28),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        toastLabel = label
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
            self?.toastLabel?.removeFromSuperview()
            self?.toastLabel = nil
        }
    }
}
