import AppKit

private enum InputMode: String {
    case chinese
    case western
}

private enum CharacterForm: String {
    case simplifiedChinese
    case traditionalChinese
}

private enum PunctuationMode: String {
    case chinese
    case western
}

private enum CharacterWidth: String {
    case halfWidth
    case fullWidth
}

// 组装 InputMethodKit 的动态菜单，并把菜单动作收口回当前输入会话。
final class InputMethodMenu: NSObject {
    private weak var inputController: TypingChaoInputController?
    private let inputMethodSettings: InputMethodSettings

    init(inputController: TypingChaoInputController, inputMethodSettings: InputMethodSettings = .shared) {
        self.inputController = inputController
        self.inputMethodSettings = inputMethodSettings
    }

    func makeMenu(snapshot: RimeSnapshot, schemaList: [RimeSchemaItem]) -> NSMenu {
        let menu = NSMenu(title: "Typing Chao")
        menu.autoenablesItems = false

        let schemaName = resolvedSchemaName(snapshot: snapshot)
        addDisabledItem(to: menu, title: "Typing Chao · \(schemaName)")
        addDisabledItem(to: menu, title: "当前模式：\(inputModeName(snapshot: snapshot))")
        menu.addItem(.separator())

        menu.addItem(makeInputModeItem(snapshot: snapshot))
        menu.addItem(makeCharacterFormItem(snapshot: snapshot))
        menu.addItem(makePunctuationItem(snapshot: snapshot))
        menu.addItem(makeCharacterWidthItem(snapshot: snapshot))
        menu.addItem(makeSchemaItem(snapshot: snapshot, schemaList: schemaList))
        menu.addItem(.separator())

        menu.addItem(makeAIInputItem())
        menu.addItem(.separator())
        menu.addItem(makeTranslationEnabledItem())
        menu.addItem(makeTargetLanguageItem())
        menu.addItem(.separator())
        menu.addItem(makeSettingsItem())
        return menu
    }

    private func makeInputModeItem(snapshot: RimeSnapshot) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "输入模式", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "输入模式")
        submenu.addItem(makeStateItem(
            title: "中文",
            selected: !snapshot.isAsciiMode,
            action: #selector(selectInputMode(_:)),
            representedObject: InputMode.chinese.rawValue
        ))
        submenu.addItem(makeStateItem(
            title: "英文",
            selected: snapshot.isAsciiMode,
            action: #selector(selectInputMode(_:)),
            representedObject: InputMode.western.rawValue
        ))
        menuItem.submenu = submenu
        return menuItem
    }

    private func makeCharacterFormItem(snapshot: RimeSnapshot) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "汉字", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "汉字")
        let usesSimplifiedChinese = snapshot.isSimplifiedChinese
        submenu.addItem(makeStateItem(
            title: "简体中文",
            selected: usesSimplifiedChinese,
            action: #selector(selectCharacterForm(_:)),
            representedObject: CharacterForm.simplifiedChinese.rawValue
        ))
        submenu.addItem(makeStateItem(
            title: "繁体中文",
            selected: !usesSimplifiedChinese,
            action: #selector(selectCharacterForm(_:)),
            representedObject: CharacterForm.traditionalChinese.rawValue
        ))
        menuItem.submenu = submenu
        return menuItem
    }

    private func makePunctuationItem(snapshot: RimeSnapshot) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "标点", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "标点")
        submenu.addItem(makeStateItem(
            title: "中文标点",
            selected: !snapshot.isAsciiPunctuation,
            action: #selector(selectPunctuationMode(_:)),
            representedObject: PunctuationMode.chinese.rawValue
        ))
        submenu.addItem(makeStateItem(
            title: "西文标点",
            selected: snapshot.isAsciiPunctuation,
            action: #selector(selectPunctuationMode(_:)),
            representedObject: PunctuationMode.western.rawValue
        ))
        menuItem.submenu = submenu
        return menuItem
    }

    private func makeCharacterWidthItem(snapshot: RimeSnapshot) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "字符宽度", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "字符宽度")
        submenu.addItem(makeStateItem(
            title: "半角",
            selected: !snapshot.isFullShape,
            action: #selector(selectCharacterWidth(_:)),
            representedObject: CharacterWidth.halfWidth.rawValue
        ))
        submenu.addItem(makeStateItem(
            title: "全角",
            selected: snapshot.isFullShape,
            action: #selector(selectCharacterWidth(_:)),
            representedObject: CharacterWidth.fullWidth.rawValue
        ))
        menuItem.submenu = submenu
        return menuItem
    }

    private func makeSchemaItem(snapshot: RimeSnapshot, schemaList: [RimeSchemaItem]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: "输入方案", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "输入方案")
        if schemaList.isEmpty {
            addDisabledItem(to: submenu, title: resolvedSchemaName(snapshot: snapshot))
        } else {
            for schema in schemaList {
                submenu.addItem(makeStateItem(
                    title: schema.displayName,
                    selected: schema.identifier == snapshot.schemaIdentifier,
                    action: #selector(selectSchema(_:)),
                    representedObject: schema.identifier
                ))
            }
        }
        menuItem.submenu = submenu
        return menuItem
    }

    private func makeTranslationEnabledItem() -> NSMenuItem {
        makeStateItem(
            title: "边写边译",
            selected: inputMethodSettings.isTranslationEnabled,
            action: #selector(toggleTranslation(_:)),
            representedObject: nil
        )
    }

    // 菜单提供无候选时的同一 AI 入口，不再绑定会被宿主提前消费的组合键。
    private func makeAIInputItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "AI 输入…", action: #selector(openAIInput(_:)), keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func makeTargetLanguageItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "翻译目标语言", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "翻译目标语言")
        let selectedLanguage = inputMethodSettings.targetLanguage
        for targetLanguage in TranslationTargetLanguage.allCases {
            submenu.addItem(makeStateItem(
                title: targetLanguage.displayName,
                selected: targetLanguage == selectedLanguage,
                action: #selector(selectTargetLanguage(_:)),
                representedObject: targetLanguage.rawValue
            ))
        }
        menuItem.submenu = submenu
        return menuItem
    }

    private func makeSettingsItem() -> NSMenuItem {
        let menuItem = NSMenuItem(title: "设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        menuItem.keyEquivalentModifierMask = [.command]
        menuItem.target = self
        return menuItem
    }

    private func addDisabledItem(to menu: NSMenu, title: String) {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menu.addItem(menuItem)
    }

    private func makeStateItem(
        title: String,
        selected: Bool,
        action: Selector,
        representedObject: Any?
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = representedObject
        if selected {
            menuItem.state = .on
        }
        return menuItem
    }

    private func inputModeName(snapshot: RimeSnapshot) -> String {
        if snapshot.isAsciiMode {
            return "英文"
        }
        return "中文"
    }

    private func resolvedSchemaName(snapshot: RimeSnapshot) -> String {
        if !snapshot.schemaName.isEmpty {
            return snapshot.schemaName
        }
        return "朙月拼音"
    }

    // 输入模式只改当前 Rime 会话，不选择或切换 macOS 系统输入源。
    @objc private func selectInputMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let inputMode = InputMode(rawValue: rawValue) else {
            return
        }
        switch inputMode {
        case .chinese:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .asciiMode, isEnabled: false),
            ])
        case .western:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .asciiMode, isEnabled: true),
            ])
        }
    }

    // 简繁切换同时关闭其它字形选项，确保 Rime schema 只保留一个明确的字形状态。
    @objc private func selectCharacterForm(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let characterForm = CharacterForm(rawValue: rawValue) else {
            return
        }
        switch characterForm {
        case .simplifiedChinese:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .simplifiedChinese, isEnabled: true),
                RimeOptionState(optionName: .traditionalChinese, isEnabled: false),
                RimeOptionState(optionName: .hongKongTraditionalChinese, isEnabled: false),
                RimeOptionState(optionName: .taiwanTraditionalChinese, isEnabled: false),
            ])
        case .traditionalChinese:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .simplifiedChinese, isEnabled: false),
                RimeOptionState(optionName: .traditionalChinese, isEnabled: true),
                RimeOptionState(optionName: .hongKongTraditionalChinese, isEnabled: false),
                RimeOptionState(optionName: .taiwanTraditionalChinese, isEnabled: false),
            ])
        }
    }

    @objc private func selectPunctuationMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let punctuationMode = PunctuationMode(rawValue: rawValue) else {
            return
        }
        switch punctuationMode {
        case .chinese:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .asciiPunctuation, isEnabled: false),
            ])
        case .western:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .asciiPunctuation, isEnabled: true),
            ])
        }
    }

    @objc private func selectCharacterWidth(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let characterWidth = CharacterWidth(rawValue: rawValue) else {
            return
        }
        switch characterWidth {
        case .halfWidth:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .fullShape, isEnabled: false),
            ])
        case .fullWidth:
            inputController?.applyRimeOptionStateList([
                RimeOptionState(optionName: .fullShape, isEnabled: true),
            ])
        }
    }

    @objc private func selectSchema(_ sender: NSMenuItem) {
        guard let schemaIdentifier = sender.representedObject as? String else {
            return
        }
        inputController?.selectRimeSchema(schemaIdentifier)
    }

    @objc private func toggleTranslation(_ sender: NSMenuItem) {
        inputController?.setTranslationEnabled(!inputMethodSettings.isTranslationEnabled)
    }

    @objc private func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let targetLanguage = TranslationTargetLanguage(rawValue: rawValue) else {
            return
        }
        inputController?.setTranslationTargetLanguage(targetLanguage)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        inputController?.showSettings()
    }

    @objc private func openAIInput(_ sender: NSMenuItem) {
        inputController?.showAIInput()
    }
}
