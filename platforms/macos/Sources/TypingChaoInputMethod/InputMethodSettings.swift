import Foundation

// 映射当前 schema 已声明的运行时选项，菜单只操作 librime 明确支持的 option 名称。
enum RimeRuntimeOption: String, CaseIterable {
    case asciiMode = "ascii_mode"
    case fullShape = "full_shape"
    case asciiPunctuation = "ascii_punct"
    case simplifiedChinese = "zh_hans"
    case traditionalChinese = "zh_hant"
    case hongKongTraditionalChinese = "zh_hant_hk"
    case taiwanTraditionalChinese = "zh_hant_tw"

    var shouldPersist: Bool {
        switch self {
        case .asciiMode:
            return false
        case .fullShape,
             .asciiPunctuation,
             .simplifiedChinese,
             .traditionalChinese,
             .hongKongTraditionalChinese,
             .taiwanTraditionalChinese:
            return true
        }
    }
}

// 一次菜单选择中需要同时收口的 Rime option，避免中文简繁状态留下互相冲突的开关。
struct RimeOptionState {
    let optionName: RimeRuntimeOption
    let isEnabled: Bool
}

// 限定首版边写边译可选目标语言，避免把未验证的自由文本配置直接送入翻译服务。
enum TranslationTargetLanguage: String, CaseIterable {
    case english = "English"
    case thai = "Thai"
    case vietnamese = "Vietnamese"
    case indonesian = "Indonesian"
    case malay = "Malay"

    var displayName: String {
        switch self {
        case .english:
            return "英语"
        case .thai:
            return "泰语"
        case .vietnamese:
            return "越南语"
        case .indonesian:
            return "印尼语"
        case .malay:
            return "马来语"
        }
    }

    var serviceLanguageName: String {
        rawValue
    }
}

// 统一选择翻译和 AI 输入共用的请求协议，避免两条功能链各自保存服务状态。
enum AIServiceProvider: String, CaseIterable {
    case deepSeek = "deepseek"
    case codexResponses = "codex-responses"

    var displayName: String {
        switch self {
        case .deepSeek:
            return "DeepSeek"
        case .codexResponses:
            return "Codex Responses"
        }
    }

    var apiKeyDisplayName: String {
        switch self {
        case .deepSeek:
            return "DeepSeek Key"
        case .codexResponses:
            return "Codex API Key"
        }
    }

    // 每种请求协议保留自己的默认地址和固定接口路径，设置页只覆盖 Base URL。
    var defaultBaseURL: URL {
        switch self {
        case .deepSeek:
            return URL(string: "https://api.deepseek.com")!
        case .codexResponses:
            return URL(string: "http://127.0.0.1:8317/v1")!
        }
    }

    var requestPathComponentList: [String] {
        switch self {
        case .deepSeek:
            return ["chat", "completions"]
        case .codexResponses:
            return ["responses"]
        }
    }

    var defaultModelName: String {
        switch self {
        case .deepSeek:
            return "deepseek-v4-flash"
        case .codexResponses:
            return "gpt-5.6-luna"
        }
    }

    var modelListPathComponentList: [String] {
        ["models"]
    }
}

// 集中保存本输入法的用户级偏好，不写入其它 Rime 前端或系统输入源配置。
final class InputMethodSettings {
    static let shared = InputMethodSettings()

    private enum SettingKey {
        static let translationEnabled = "TypingChaoTranslationEnabled"
        static let targetLanguage = "TypingChaoTargetLanguage"
        static let selectedSchema = "TypingChaoSelectedRimeSchema"
        static let deepSeekAPIKey = "TypingChaoDeepSeekAPIKey"
        static let codexAPIKey = "TypingChaoCodexAPIKey"
        static let deepSeekBaseURL = "TypingChaoDeepSeekBaseURL"
        static let codexBaseURL = "TypingChaoCodexBaseURL"
        static let deepSeekModelName = "TypingChaoDeepSeekModelName"
        static let codexModelName = "TypingChaoCodexModelName"
        static let aiServiceProvider = "TypingChaoAIServiceProvider"

        static let rimeOptionPrefix = "TypingChaoRimeOption."

        static func rimeOption(_ optionName: RimeRuntimeOption) -> String {
            "\(rimeOptionPrefix)\(optionName.rawValue)"
        }
    }

    private enum SupportedURLScheme: String {
        case http
        case https
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // 用户未明确开启前不发起远程翻译，已保存的开关偏好保持原值。
    var isTranslationEnabled: Bool {
        guard userDefaults.object(forKey: SettingKey.translationEnabled) != nil else {
            return false
        }
        return userDefaults.bool(forKey: SettingKey.translationEnabled)
    }

    var targetLanguage: TranslationTargetLanguage {
        guard let storedLanguage = userDefaults.string(forKey: SettingKey.targetLanguage),
              let targetLanguage = TranslationTargetLanguage(rawValue: storedLanguage) else {
            return .english
        }
        return targetLanguage
    }

    var aiServiceProvider: AIServiceProvider {
        guard let storedProvider = userDefaults.string(forKey: SettingKey.aiServiceProvider),
              let serviceProvider = AIServiceProvider(rawValue: storedProvider) else {
            return .deepSeek
        }
        return serviceProvider
    }


    var selectedSchemaIdentifier: String? {
        let schemaIdentifier = userDefaults.string(forKey: SettingKey.selectedSchema)
        guard let schemaIdentifier, !schemaIdentifier.isEmpty else {
            return nil
        }
        return schemaIdentifier
    }

    var deepSeekAPIKey: String? {
        apiKey(for: .deepSeek)
    }

    var codexAPIKey: String? {
        apiKey(for: .codexResponses)
    }

    var currentAPIKey: String? {
        apiKey(for: aiServiceProvider)
    }

    func apiKey(for serviceProvider: AIServiceProvider) -> String? {
        let apiKeySettingKey: String
        switch serviceProvider {
        case .deepSeek:
            apiKeySettingKey = SettingKey.deepSeekAPIKey
        case .codexResponses:
            apiKeySettingKey = SettingKey.codexAPIKey
        }
        let apiKey = userDefaults.string(forKey: apiKeySettingKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return apiKey
    }

    // 自定义地址只读取用户明确保存的值，设置页据此决定展示默认占位还是已配置内容。
    func customBaseURL(for serviceProvider: AIServiceProvider) -> URL? {
        let baseURLSettingKey: String
        switch serviceProvider {
        case .deepSeek:
            baseURLSettingKey = SettingKey.deepSeekBaseURL
        case .codexResponses:
            baseURLSettingKey = SettingKey.codexBaseURL
        }
        guard let baseURLText = userDefaults.string(forKey: baseURLSettingKey),
              let baseURL = URL(string: baseURLText) else {
            return nil
        }
        return baseURL
    }

    func baseURL(for serviceProvider: AIServiceProvider) -> URL {
        customBaseURL(for: serviceProvider) ?? serviceProvider.defaultBaseURL
    }

    // 请求地址始终由当前服务的 Base URL 和固定协议路径组成，避免设置页直接改变请求协议。
    func requestURL(for serviceProvider: AIServiceProvider) -> URL {
        var requestURL = baseURL(for: serviceProvider)
        for pathComponent in serviceProvider.requestPathComponentList {
            requestURL.appendPathComponent(pathComponent)
        }
        return requestURL
    }

    func modelListURL(for serviceProvider: AIServiceProvider) -> URL {
        var modelListURL = baseURL(for: serviceProvider)
        for pathComponent in serviceProvider.modelListPathComponentList {
            modelListURL.appendPathComponent(pathComponent)
        }
        return modelListURL
    }

    func customModelName(for serviceProvider: AIServiceProvider) -> String? {
        let modelNameSettingKey: String
        switch serviceProvider {
        case .deepSeek:
            modelNameSettingKey = SettingKey.deepSeekModelName
        case .codexResponses:
            modelNameSettingKey = SettingKey.codexModelName
        }
        let modelName = userDefaults.string(forKey: modelNameSettingKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let modelName, !modelName.isEmpty else { return nil }
        return modelName
    }

    func modelName(for serviceProvider: AIServiceProvider) -> String {
        customModelName(for: serviceProvider) ?? serviceProvider.defaultModelName
    }


    func persistedRimeOptionStateList() -> [RimeOptionState] {
        var optionStateList: [RimeOptionState] = []
        for optionName in RimeRuntimeOption.allCases where optionName.shouldPersist {
            let keyName = SettingKey.rimeOption(optionName)
            guard userDefaults.object(forKey: keyName) != nil else {
                continue
            }
            optionStateList.append(
                RimeOptionState(
                    optionName: optionName,
                    isEnabled: userDefaults.bool(forKey: keyName)
                )
            )
        }
        return optionStateList
    }

    func setTranslationEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: SettingKey.translationEnabled)
    }

    func setTargetLanguage(_ targetLanguage: TranslationTargetLanguage) {
        userDefaults.set(targetLanguage.rawValue, forKey: SettingKey.targetLanguage)
    }

    func setAIServiceProvider(_ serviceProvider: AIServiceProvider) {
        userDefaults.set(serviceProvider.rawValue, forKey: SettingKey.aiServiceProvider)
    }


    func setSelectedSchemaIdentifier(_ schemaIdentifier: String) {
        userDefaults.set(schemaIdentifier, forKey: SettingKey.selectedSchema)
    }

    // DeepSeek 凭据由设置页写入当前用户偏好缓存，构建包和测试产物不包含用户输入。
    @discardableResult
    func setDeepSeekAPIKey(_ apiKey: String) -> Bool {
        setAPIKey(apiKey, for: .deepSeek)
    }

    // 当前选择的服务 Key 由设置页写入本机用户偏好，不进入 Keychain、输入法包或构建产物。
    @discardableResult
    func setCurrentAPIKey(_ apiKey: String) -> Bool {
        setAPIKey(apiKey, for: aiServiceProvider)
    }

    // 当前服务的 Base URL 独立保存，切换服务不会覆盖另一套地址。
    @discardableResult
    func setCurrentBaseURL(_ baseURL: String) -> Bool {
        setBaseURL(baseURL, for: aiServiceProvider)
    }

    @discardableResult
    func setCurrentModelName(_ modelName: String) -> Bool {
        setModelName(modelName, for: aiServiceProvider)
    }

    @discardableResult
    func setAPIKey(_ apiKey: String, for serviceProvider: AIServiceProvider) -> Bool {
        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeySettingKey: String
        switch serviceProvider {
        case .deepSeek:
            apiKeySettingKey = SettingKey.deepSeekAPIKey
        case .codexResponses:
            apiKeySettingKey = SettingKey.codexAPIKey
        }
        if normalizedAPIKey.isEmpty {
            userDefaults.removeObject(forKey: apiKeySettingKey)
        } else {
            userDefaults.set(normalizedAPIKey, forKey: apiKeySettingKey)
        }
        return true
    }

    @discardableResult
    func setBaseURL(_ baseURL: String, for serviceProvider: AIServiceProvider) -> Bool {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURLSettingKey: String
        switch serviceProvider {
        case .deepSeek:
            baseURLSettingKey = SettingKey.deepSeekBaseURL
        case .codexResponses:
            baseURLSettingKey = SettingKey.codexBaseURL
        }
        if normalizedBaseURL.isEmpty {
            userDefaults.removeObject(forKey: baseURLSettingKey)
            return true
        }
        guard let parsedBaseURL = URL(string: normalizedBaseURL),
              let schemeName = parsedBaseURL.scheme?.lowercased(),
              SupportedURLScheme(rawValue: schemeName) != nil,
              parsedBaseURL.host != nil,
              parsedBaseURL.query == nil,
              parsedBaseURL.fragment == nil else {
            return false
        }
        userDefaults.set(parsedBaseURL.absoluteString, forKey: baseURLSettingKey)
        return true
    }

    @discardableResult
    func setModelName(_ modelName: String, for serviceProvider: AIServiceProvider) -> Bool {
        let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelNameSettingKey: String
        switch serviceProvider {
        case .deepSeek:
            modelNameSettingKey = SettingKey.deepSeekModelName
        case .codexResponses:
            modelNameSettingKey = SettingKey.codexModelName
        }
        if normalizedModelName.isEmpty {
            userDefaults.removeObject(forKey: modelNameSettingKey)
        } else {
            userDefaults.set(normalizedModelName, forKey: modelNameSettingKey)
        }
        return true
    }


    func persistRimeOptionStateList(_ optionStateList: [RimeOptionState]) {
        for optionState in optionStateList where optionState.optionName.shouldPersist {
            userDefaults.set(
                optionState.isEnabled,
                forKey: SettingKey.rimeOption(optionState.optionName)
            )
        }
    }

}
