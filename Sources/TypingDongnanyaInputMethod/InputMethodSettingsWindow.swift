import AppKit

// 提供输入法进程内的轻量设置窗口，集中暴露边写边译和首版 Rime 基础选项。
final class InputMethodSettingsWindowController: NSWindowController {
    static let shared = InputMethodSettingsWindowController()

    private let settingsViewController = InputMethodSettingsViewController()
    private weak var inputController: TypingDongnanyaInputController?
    private var hasPositionedWindow = false

    private init() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Typing 东南亚设置"
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.tabbingMode = .disallowed
        settingsViewController.preferredContentSize = NSSize(width: 700, height: 500)
        settingsWindow.contentViewController = settingsViewController
        settingsWindow.setContentSize(NSSize(width: 700, height: 500))
        settingsWindow.contentMinSize = NSSize(width: 700, height: 500)
        settingsWindow.contentMaxSize = NSSize(width: 700, height: 500)
        super.init(window: settingsWindow)

        settingsViewController.translationEnabledHandler = { [weak self] enabled in
            if let inputController = self?.inputController {
                inputController.setTranslationEnabled(enabled)
                return
            }
            InputMethodSettings.shared.setTranslationEnabled(enabled)
        }
        settingsViewController.targetLanguageHandler = { [weak self] targetLanguage in
            if let inputController = self?.inputController {
                inputController.setTranslationTargetLanguage(targetLanguage)
                return
            }
            InputMethodSettings.shared.setTargetLanguage(targetLanguage)
        }
        settingsViewController.rimeOptionHandler = { [weak self] optionStateList in
            if let inputController = self?.inputController {
                inputController.applyRimeOptionStateList(optionStateList)
                return
            }
            InputMethodSettings.shared.persistRimeOptionStateList(optionStateList)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 每次打开都刷新当前 Rime 状态和翻译偏好，避免窗口长期保留旧选项。
    func show(inputController: TypingDongnanyaInputController, snapshot: RimeSnapshot) {
        self.inputController = inputController
        settingsViewController.configure(snapshot: snapshot)
        if !hasPositionedWindow {
            window?.center()
            hasPositionedWindow = true
        }
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum InputMethodSettingsSection: Int {
    case translation
    case input
}

private enum InputMethodSettingsStyle {
    static let sidebarWidth: CGFloat = 168
    static let accentColor = NSColor(calibratedRed: 0.03, green: 0.68, blue: 0.59, alpha: 1)
    static let cardBackgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72)
    static let cardBorderColor = NSColor.separatorColor.withAlphaComponent(0.45)
}

// 负责绘制翻译和输入设置，并把业务变更通过明确回调交给当前输入控制器。
private final class InputMethodSettingsViewController: NSViewController {
    var translationEnabledHandler: ((Bool) -> Void)?
    var targetLanguageHandler: ((TranslationTargetLanguage) -> Void)?
    var rimeOptionHandler: (([RimeOptionState]) -> Void)?

    private let translationSidebarButton = SettingsSidebarButton(title: "翻译", symbolName: "character.bubble")
    private let inputSidebarButton = SettingsSidebarButton(title: "输入", symbolName: "keyboard")
    private let translationPage = NSView()
    private let inputPage = NSView()
    private let translationSwitch = NSSwitch()
    private let targetLanguagePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputModeControl = NSSegmentedControl(labels: ["中文", "英文"], trackingMode: .selectOne, target: nil, action: nil)
    private let characterFormControl = NSSegmentedControl(labels: ["简体", "繁体"], trackingMode: .selectOne, target: nil, action: nil)
    private let punctuationControl = NSSegmentedControl(labels: ["中文", "西文"], trackingMode: .selectOne, target: nil, action: nil)
    private let characterWidthControl = NSSegmentedControl(labels: ["半角", "全角"], trackingMode: .selectOne, target: nil, action: nil)

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = rootView
        buildSidebar()
        buildPages()
        selectSection(.translation)
    }

    // 设置窗口出现时同步持久化翻译选项和当前 librime 快照。
    func configure(snapshot: RimeSnapshot) {
        _ = view
        translationSwitch.state = .off
        if InputMethodSettings.shared.isTranslationEnabled {
            translationSwitch.state = .on
        }
        selectTargetLanguage(InputMethodSettings.shared.targetLanguage)
        inputModeControl.selectedSegment = 0
        if snapshot.isAsciiMode {
            inputModeControl.selectedSegment = 1
        }
        characterFormControl.selectedSegment = 1
        if snapshot.isSimplifiedChinese {
            characterFormControl.selectedSegment = 0
        }
        punctuationControl.selectedSegment = 0
        if snapshot.isAsciiPunctuation {
            punctuationControl.selectedSegment = 1
        }
        characterWidthControl.selectedSegment = 0
        if snapshot.isFullShape {
            characterWidthControl.selectedSegment = 1
        }
    }


    private func buildSidebar() {
        let sidebarView = NSVisualEffectView()
        sidebarView.material = .sidebar
        sidebarView.blendingMode = .behindWindow
        sidebarView.state = .active
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarView)

        let titleLabel = makeLabel(text: "Typing 东南亚", fontSize: 15, weight: .semibold)
        let subtitleLabel = makeLabel(text: "边写边译输入法", fontSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        translationSidebarButton.tag = InputMethodSettingsSection.translation.rawValue
        translationSidebarButton.target = self
        translationSidebarButton.action = #selector(selectSidebarSection(_:))
        inputSidebarButton.tag = InputMethodSettingsSection.input.rawValue
        inputSidebarButton.target = self
        inputSidebarButton.action = #selector(selectSidebarSection(_:))

        let sidebarStack = NSStackView(
            views: [
                titleLabel,
                subtitleLabel,
                translationSidebarButton,
                inputSidebarButton,
            ]
        )
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 6
        sidebarStack.setCustomSpacing(20, after: subtitleLabel)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarStack)

        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarView.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: InputMethodSettingsStyle.sidebarWidth),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 18),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -14),
            sidebarStack.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 22),
            translationSidebarButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            inputSidebarButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
        ])
    }

    private func buildPages() {
        buildTranslationPage()
        buildInputPage()
        for page in [translationPage, inputPage] {
            page.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: InputMethodSettingsStyle.sidebarWidth),
                page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                page.topAnchor.constraint(equalTo: view.topAnchor),
                page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    private func buildTranslationPage() {
        let titleLabel = makePageTitle("翻译")
        translationSwitch.target = self
        translationSwitch.action = #selector(toggleTranslation(_:))

        for targetLanguage in TranslationTargetLanguage.allCases {
            let menuItem = NSMenuItem(title: targetLanguage.displayName, action: nil, keyEquivalent: "")
            menuItem.representedObject = targetLanguage.rawValue
            targetLanguagePopUpButton.menu?.addItem(menuItem)
        }
        targetLanguagePopUpButton.target = self
        targetLanguagePopUpButton.action = #selector(changeTargetLanguage(_:))
        targetLanguagePopUpButton.widthAnchor.constraint(equalToConstant: 128).isActive = true

        let translationCard = makeCard(rows: [
            makeRow(
                title: "边写边译",
                subtitle: "拼音提交后等待 1 秒；粘贴时只翻译剪贴板文本",
                trailingControl: translationSwitch
            ),
            makeRow(
                title: "目标语言",
                subtitle: "译文会按这里选择的语言生成",
                trailingControl: targetLanguagePopUpButton
            ),
        ])
        let privacyCard = makeCard(rows: [
            makeRow(
                title: "安全输入保护",
                subtitle: "密码框或系统安全输入开启时，不会发送任何文本",
                trailingControl: makeStatusLabel("自动启用")
            ),
            makeRow(
                title: "手动翻译",
                subtitle: "立即翻译当前剪贴板可按 Control + Shift + T",
                trailingControl: makeStatusLabel("快捷键")
            ),
        ])
        let pageStack = makePageStack(views: [titleLabel, translationCard, privacyCard])
        installPageStack(pageStack, in: translationPage)
    }

    private func buildInputPage() {
        let titleLabel = makePageTitle("输入")
        for control in [inputModeControl, characterFormControl, punctuationControl, characterWidthControl] {
            control.segmentStyle = .rounded
            control.widthAnchor.constraint(equalToConstant: 132).isActive = true
        }
        inputModeControl.target = self
        inputModeControl.action = #selector(changeInputMode(_:))
        characterFormControl.target = self
        characterFormControl.action = #selector(changeCharacterForm(_:))
        punctuationControl.target = self
        punctuationControl.action = #selector(changePunctuation(_:))
        characterWidthControl.target = self
        characterWidthControl.action = #selector(changeCharacterWidth(_:))

        let inputModeCard = makeCard(rows: [
            makeRow(title: "输入模式", subtitle: "在当前输入法内切换中文或英文", trailingControl: inputModeControl),
            makeRow(title: "汉字", subtitle: "默认使用简体中文", trailingControl: characterFormControl),
        ])
        let characterCard = makeCard(rows: [
            makeRow(
                title: "字符宽度",
                subtitle: "半角使用常规字符；全角转换拉丁字母、数字和空格宽度",
                trailingControl: characterWidthControl
            ),
            makeRow(
                title: "标点样式",
                subtitle: "中文或西文标点独立设置，不与字符宽度混为同一状态",
                trailingControl: punctuationControl
            ),
            makeRow(
                title: "快捷切换",
                subtitle: "输入时切换半角与全角，切换后显示当前状态",
                trailingControl: makeStatusLabel("Shift + Space")
            ),
        ])
        let noteLabel = makeLabel(
            text: "这些设置只影响 Typing 东南亚，不会切换、删除或修改其它 macOS 输入法。",
            fontSize: 11,
            weight: .regular
        )
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 2
        let pageStack = makePageStack(views: [titleLabel, inputModeCard, characterCard, noteLabel])
        installPageStack(pageStack, in: inputPage)
    }


    private func makePageStack(views: [NSView]) -> NSStackView {
        let stackView = NSStackView(views: views)
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }

    private func installPageStack(_ stackView: NSStackView, in page: NSView) {
        page.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 28),
            stackView.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -28),
            stackView.topAnchor.constraint(equalTo: page.topAnchor, constant: 24),
        ])
    }

    private func makePageTitle(_ title: String) -> NSTextField {
        makeLabel(text: title, fontSize: 22, weight: .semibold)
    }

    private func makeCard(rows: [NSView]) -> SettingsCardView {
        let cardView = SettingsCardView()
        let cardStack = NSStackView()
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardStack)

        for (rowIndex, rowView) in rows.enumerated() {
            cardStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
            if rowIndex < rows.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                cardStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
            }
        }
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: cardView.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            cardView.widthAnchor.constraint(equalToConstant: 462),
        ])
        return cardView
    }

    private func makeRow(title: String, subtitle: String, trailingControl: NSView) -> NSView {
        let rowView = NSView()
        rowView.translatesAutoresizingMaskIntoConstraints = false
        rowView.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let titleLabel = makeLabel(text: title, fontSize: 13.5, weight: .medium)
        let subtitleLabel = makeLabel(text: subtitle, fontSize: 10.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        let labelStack = NSStackView(views: [titleLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        trailingControl.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(labelStack)
        rowView.addSubview(trailingControl)

        NSLayoutConstraint.activate([
            labelStack.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 16),
            labelStack.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingControl.leadingAnchor, constant: -14),
            trailingControl.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -16),
            trailingControl.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
        ])
        return rowView
    }

    private func makeStatusLabel(_ text: String) -> NSTextField {
        let statusLabel = makeLabel(text: text, fontSize: 11, weight: .medium)
        statusLabel.textColor = InputMethodSettingsStyle.accentColor
        return statusLabel
    }

    private func makeLabel(text: String, fontSize: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func selectTargetLanguage(_ targetLanguage: TranslationTargetLanguage) {
        for menuItem in targetLanguagePopUpButton.itemArray {
            guard menuItem.representedObject as? String == targetLanguage.rawValue else {
                continue
            }
            targetLanguagePopUpButton.select(menuItem)
            return
        }
    }

    @objc private func selectSidebarSection(_ sender: SettingsSidebarButton) {
        guard let section = InputMethodSettingsSection(rawValue: sender.tag) else { return }
        selectSection(section)
    }

    private func selectSection(_ section: InputMethodSettingsSection) {
        translationPage.isHidden = section != .translation
        inputPage.isHidden = section != .input
        translationSidebarButton.isSelected = section == .translation
        inputSidebarButton.isSelected = section == .input
    }

    @objc private func toggleTranslation(_ sender: NSSwitch) {
        translationEnabledHandler?(sender.state == .on)
    }

    @objc private func changeTargetLanguage(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let targetLanguage = TranslationTargetLanguage(rawValue: rawValue) else {
            return
        }
        targetLanguageHandler?(targetLanguage)
    }

    @objc private func changeInputMode(_ sender: NSSegmentedControl) {
        rimeOptionHandler?([
            RimeOptionState(optionName: .asciiMode, isEnabled: sender.selectedSegment == 1),
        ])
    }

    @objc private func changeCharacterForm(_ sender: NSSegmentedControl) {
        let usesTraditionalChinese = sender.selectedSegment == 1
        rimeOptionHandler?([
            RimeOptionState(optionName: .simplifiedChinese, isEnabled: !usesTraditionalChinese),
            RimeOptionState(optionName: .traditionalChinese, isEnabled: usesTraditionalChinese),
            RimeOptionState(optionName: .hongKongTraditionalChinese, isEnabled: false),
            RimeOptionState(optionName: .taiwanTraditionalChinese, isEnabled: false),
        ])
    }

    @objc private func changePunctuation(_ sender: NSSegmentedControl) {
        rimeOptionHandler?([
            RimeOptionState(optionName: .asciiPunctuation, isEnabled: sender.selectedSegment == 1),
        ])
    }

    @objc private func changeCharacterWidth(_ sender: NSSegmentedControl) {
        rimeOptionHandler?([
            RimeOptionState(optionName: .fullShape, isEnabled: sender.selectedSegment == 1),
        ])
    }
}

private final class SettingsCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = InputMethodSettingsStyle.cardBackgroundColor.cgColor
        layer?.borderColor = InputMethodSettingsStyle.cardBorderColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// 侧栏按钮用轻量选中底色表达当前页，不引入独立图片资源。
private final class SettingsSidebarButton: NSButton {
    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        imagePosition = .imageLeading
        alignment = .left
        font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = .labelColor
        if isSelected {
            layer?.backgroundColor = InputMethodSettingsStyle.accentColor.withAlphaComponent(0.18).cgColor
            contentTintColor = InputMethodSettingsStyle.accentColor
        }
    }
}
