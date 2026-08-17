import AppKit

// 提供输入法进程内的设置窗口，React/Tailwind 只负责显示，设置写入仍由原生主链处理。
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
        settingsViewController.aiServiceProviderHandler = { serviceProvider in
            InputMethodSettings.shared.setAIServiceProvider(serviceProvider)
        }
        settingsViewController.apiKeyHandler = { apiKey in
            InputMethodSettings.shared.setCurrentAPIKey(apiKey)
        }
        settingsViewController.baseURLHandler = { baseURL in
            InputMethodSettings.shared.setCurrentBaseURL(baseURL)
        }
        settingsViewController.rimeOptionHandler = { [weak self] optionStateList in
            if let inputController = self?.inputController {
                inputController.applyRimeOptionStateList(optionStateList)
                return
            }
            InputMethodSettings.shared.persistRimeOptionStateList(optionStateList)
        }
        settingsViewController.schemaHandler = { [weak self] schemaIdentifier in
            self?.inputController?.selectRimeSchema(schemaIdentifier)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 每次打开都刷新当前 Rime 状态和翻译偏好，避免长期保留的 Web 页面展示旧选项。
    func show(
        inputController: TypingChaoInputController,
        snapshot: RimeSnapshot,
        schemaList: [RimeSchemaItem]
    ) {
        self.inputController = inputController
        settingsViewController.configure(snapshot: snapshot, schemaList: schemaList)
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

// 设置页 Web UI 只发送声明式动作；密钥、Rime 会话和网络请求继续留在 Swift 侧。
private final class InputMethodSettingsViewController: NSViewController {
    var translationEnabledHandler: ((Bool) -> Void)?
    var targetLanguageHandler: ((TranslationTargetLanguage) -> Void)?
    var aiServiceProviderHandler: ((AIServiceProvider) -> Void)?
    var apiKeyHandler: ((String) -> Bool)?
    var baseURLHandler: ((String) -> Bool)?
    var rimeOptionHandler: (([RimeOptionState]) -> Void)?
    // 设置页的方案选择必须回到当前 librime 会话，不能只改变 Web 页面选中项。
    var schemaHandler: ((String) -> Void)?

    private let webView = TypingChaoWebView(webViewName: .settings, acceptsKeyboardFocus: true)
    private var modelFetchTask: Task<Void, Never>?
    private var currentSchemaList: [RimeSchemaItem] = []
    private var selectedSchemaIdentifier = ""
    private var inputModeIdentifier = "chinese"
    private var characterFormIdentifier = "simplified"
    private var punctuationModeIdentifier = "chinese"
    private var characterWidthIdentifier = "half"
    private var displayedModelNameList: [String] = []

    deinit {
        modelFetchTask?.cancel()
    }

    // 设置页使用包内静态资源，窗口本身仍是输入法进程内唯一原生宿主。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.setMessageHandler { [weak self] messageBody in
            self?.handleWebMessage(messageBody)
        }
        webView.loadBundledPage()
    }

    // 设置窗口出现时同步持久化翻译选项和当前 librime 快照。
    func configure(snapshot: RimeSnapshot, schemaList: [RimeSchemaItem]) {
        _ = view
        currentSchemaList = schemaList
        selectedSchemaIdentifier = snapshot.schemaIdentifier
        inputModeIdentifier = snapshot.isAsciiMode ? "english" : "chinese"
        characterFormIdentifier = snapshot.isSimplifiedChinese ? "simplified" : "traditional"
        punctuationModeIdentifier = snapshot.isAsciiPunctuation ? "western" : "chinese"
        characterWidthIdentifier = snapshot.isFullShape ? "full" : "half"
        resetDisplayedModelNameList()
        sendSettingsState()
    }

    // Web 页面只允许调用白名单动作，未知消息保留日志并拒绝执行。
    private func handleWebMessage(_ messageBody: [String: Any]) {
        guard let messageType = messageBody["messageType"] as? String else {
            NSLog("TypingChao ignored settings Web UI message without type")
            return
        }
        if messageType == "webViewReady" {
            webView.markPageReady()
            sendSettingsState()
            return
        }
        guard messageType == "settingsAction",
              let messageData = messageBody["messageData"] as? [String: Any],
              let actionName = messageData["actionName"] as? String else {
            NSLog("TypingChao ignored unknown settings Web UI message: %@", messageType)
            return
        }
        let fieldValue = messageData["fieldValue"]
        handleSettingsAction(actionName: actionName, fieldValue: fieldValue)
    }

    // 每个设置动作继续复用原有业务入口，Web UI 不建立第二套持久化或请求状态。
    private func handleSettingsAction(actionName: String, fieldValue: Any?) {
        switch actionName {
        case "setTranslationEnabled":
            guard let isEnabled = fieldValue as? Bool else { return }
            translationEnabledHandler?(isEnabled)
            sendSettingsState()
        case "setTargetLanguage":
            guard let rawValue = fieldValue as? String,
                  let targetLanguage = TranslationTargetLanguage(rawValue: rawValue) else { return }
            targetLanguageHandler?(targetLanguage)
            sendSettingsState()
        case "setServiceProvider":
            guard let rawValue = fieldValue as? String,
                  let serviceProvider = AIServiceProvider(rawValue: rawValue) else { return }
            modelFetchTask?.cancel()
            modelFetchTask = nil
            aiServiceProviderHandler?(serviceProvider)
            resetDisplayedModelNameList()
            sendSettingsState()
        case "pasteAPIKey":
            guard let pastedText = NSPasteboard.general.string(forType: .string) else {
                sendActionResult(actionName: actionName, isSuccess: false, messageText: "剪贴板中没有可粘贴的文本")
                return
            }
            let normalizedText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                sendActionResult(actionName: actionName, isSuccess: false, messageText: "剪贴板文本为空，未写入 API Key")
                return
            }
            webView.sendMessage(messageType: "settingsPastedAPIKey", messageData: normalizedText)
        case "saveAPIKey":
            guard let apiKey = fieldValue as? String,
                  apiKeyHandler?(apiKey) == true else {
                sendActionResult(actionName: actionName, isSuccess: false, messageText: "API Key 保存失败，请确认输入内容后重试")
                return
            }
            sendSettingsState()
            sendActionResult(actionName: actionName, isSuccess: true, messageText: "API Key 已保存在本机")
        case "clearAPIKey":
            guard apiKeyHandler?("") == true else {
                sendActionResult(actionName: actionName, isSuccess: false, messageText: "API Key 清除失败，请查看输入法日志")
                return
            }
            sendSettingsState()
            sendActionResult(actionName: actionName, isSuccess: true, messageText: "API Key 已清除")
        case "saveBaseURL":
            guard let baseURL = fieldValue as? String,
                  baseURLHandler?(baseURL) == true else {
                sendActionResult(
                    actionName: actionName,
                    isSuccess: false,
                    messageText: "Base URL 必须以 http:// 或 https:// 开头、包含主机名且不带查询参数"
                )
                return
            }
            sendSettingsState()
            sendActionResult(actionName: actionName, isSuccess: true, messageText: "Base URL 已保存")
        case "clearBaseURL":
            guard baseURLHandler?("") == true else {
                sendActionResult(actionName: actionName, isSuccess: false, messageText: "Base URL 清除失败，请查看输入法日志")
                return
            }
            sendSettingsState()
            sendActionResult(actionName: actionName, isSuccess: true, messageText: "已恢复当前服务默认地址")
        case "setModelName":
            guard let modelName = fieldValue as? String,
                  InputMethodSettings.shared.setCurrentModelName(modelName) else {
                sendActionResult(actionName: actionName, isSuccess: false, messageText: "模型名称无效，请重新选择")
                return
            }
            resetDisplayedModelNameList(extraModelNameList: displayedModelNameList)
            sendSettingsState()
        case "fetchModelList":
            fetchAIModelList()
        case "saveAIInputSystemPrompt":
            guard let systemPrompt = fieldValue as? String else { return }
            InputMethodSettings.shared.setAIInputSystemPrompt(systemPrompt)
            sendSettingsState()
            sendActionResult(actionName: actionName, isSuccess: true, messageText: "AI 运行场景提示词已保存")
        case "resetAIInputSystemPrompt":
            InputMethodSettings.shared.resetAIInputSystemPrompt()
            sendSettingsState()
            sendActionResult(actionName: actionName, isSuccess: true, messageText: "已恢复默认 AI 运行场景提示词")
        case "setSchema":
            guard let schemaIdentifier = fieldValue as? String else { return }
            selectedSchemaIdentifier = schemaIdentifier
            schemaHandler?(schemaIdentifier)
            sendSettingsState()
        case "setInputMode":
            guard let modeIdentifier = fieldValue as? String else { return }
            inputModeIdentifier = modeIdentifier
            rimeOptionHandler?([
                RimeOptionState(optionName: .asciiMode, isEnabled: modeIdentifier == "english"),
            ])
            sendSettingsState()
        case "setCharacterForm":
            guard let formIdentifier = fieldValue as? String else { return }
            characterFormIdentifier = formIdentifier
            rimeOptionHandler?([
                RimeOptionState(optionName: .simplifiedChinese, isEnabled: formIdentifier == "simplified"),
                RimeOptionState(optionName: .traditionalChinese, isEnabled: formIdentifier == "traditional"),
                RimeOptionState(optionName: .hongKongTraditionalChinese, isEnabled: false),
                RimeOptionState(optionName: .taiwanTraditionalChinese, isEnabled: false),
            ])
            sendSettingsState()
        case "setPunctuationMode":
            guard let modeIdentifier = fieldValue as? String else { return }
            punctuationModeIdentifier = modeIdentifier
            rimeOptionHandler?([
                RimeOptionState(optionName: .asciiPunctuation, isEnabled: modeIdentifier == "western"),
            ])
            sendSettingsState()
        case "setCharacterWidth":
            guard let widthIdentifier = fieldValue as? String else { return }
            characterWidthIdentifier = widthIdentifier
            rimeOptionHandler?([
                RimeOptionState(optionName: .fullShape, isEnabled: widthIdentifier == "full"),
            ])
            sendSettingsState()
        default:
            NSLog("TypingChao ignored unsupported settings action: %@", actionName)
        }
    }

    // 模型列表请求仍由 Swift 网络层执行，服务切换或任务取消后拒绝迟到结果写回。
    private func fetchAIModelList() {
        let serviceProvider = InputMethodSettings.shared.aiServiceProvider
        modelFetchTask?.cancel()
        webView.sendMessage(messageType: "settingsModelLoading", messageData: true)
        modelFetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let modelNameList = try await TranslationService().fetchModelNameList(for: serviceProvider)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard InputMethodSettings.shared.aiServiceProvider == serviceProvider else { return }
                    self.modelFetchTask = nil
                    self.resetDisplayedModelNameList(extraModelNameList: modelNameList)
                    self.webView.sendMessage(
                        messageType: "settingsModelList",
                        messageData: [
                            "modelName": InputMethodSettings.shared.modelName(for: serviceProvider),
                            "modelNameList": self.displayedModelNameList,
                        ]
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.modelFetchTask = nil
                    self.webView.sendMessage(messageType: "settingsModelLoading", messageData: false)
                    self.sendActionResult(
                        actionName: "fetchModelList",
                        isSuccess: false,
                        messageText: "模型列表拉取失败：\(error.localizedDescription)"
                    )
                    NSLog("TypingChao model list request failed: %@", error.localizedDescription)
                }
            }
        }
    }

    private func resetDisplayedModelNameList(extraModelNameList: [String] = []) {
        let serviceProvider = InputMethodSettings.shared.aiServiceProvider
        var modelNameSet = Set<String>()
        displayedModelNameList = ([InputMethodSettings.shared.modelName(for: serviceProvider)] + extraModelNameList)
            .filter { modelNameSet.insert($0).inserted }
    }

    // 设置状态不包含 API Key 正文，React 页面只获知当前服务是否已有本机凭据。
    private func sendSettingsState() {
        let settings = InputMethodSettings.shared
        let serviceProvider = settings.aiServiceProvider
        let versionName = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        var versionText = "版本 \(versionName)"
        if !buildNumber.isEmpty {
            versionText += " (\(buildNumber))"
        }
        webView.sendMessage(
            messageType: "settingsState",
            messageData: [
                "versionText": versionText,
                "translationEnabled": settings.isTranslationEnabled,
                "targetLanguageIdentifier": settings.targetLanguage.rawValue,
                "targetLanguageList": TranslationTargetLanguage.allCases.map { targetLanguage in
                    [
                        "optionIdentifier": targetLanguage.rawValue,
                        "displayName": targetLanguage.displayName,
                    ]
                },
                "serviceProviderIdentifier": serviceProvider.rawValue,
                "serviceProviderList": AIServiceProvider.allCases.map { providerItem in
                    [
                        "optionIdentifier": providerItem.rawValue,
                        "displayName": providerItem.displayName,
                        "apiKeyDisplayName": providerItem.apiKeyDisplayName,
                        "defaultBaseURL": providerItem.defaultBaseURL.absoluteString,
                    ]
                },
                "apiKeyConfigured": settings.apiKey(for: serviceProvider) != nil,
                "customBaseURL": settings.customBaseURL(for: serviceProvider)?.absoluteString ?? "",
                "modelName": settings.modelName(for: serviceProvider),
                "modelNameList": displayedModelNameList,
                "aiInputSystemPrompt": settings.aiInputSystemPrompt,
                "schemaIdentifier": selectedSchemaIdentifier,
                "schemaList": currentSchemaList.map { schemaItem in
                    [
                        "optionIdentifier": schemaItem.identifier,
                        "displayName": schemaItem.displayName,
                    ]
                },
                "inputModeIdentifier": inputModeIdentifier,
                "characterFormIdentifier": characterFormIdentifier,
                "punctuationModeIdentifier": punctuationModeIdentifier,
                "characterWidthIdentifier": characterWidthIdentifier,
            ]
        )
    }

    private func sendActionResult(actionName: String, isSuccess: Bool, messageText: String) {
        webView.sendMessage(
            messageType: "settingsActionResult",
            messageData: [
                "actionName": actionName,
                "isSuccess": isSuccess,
                "messageText": messageText,
            ]
        )
    }
}
