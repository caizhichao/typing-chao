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

// 集中保存本输入法的用户级偏好，不写入其它 Rime 前端或系统输入源配置。
final class InputMethodSettings {
    static let shared = InputMethodSettings()

    private enum SettingKey {
        static let translationEnabled = "TypingDongnanyaTranslationEnabled"
        static let targetLanguage = "TypingDongnanyaTargetLanguage"
        static let selectedSchema = "TypingDongnanyaSelectedRimeSchema"
        static let rimeOptionPrefix = "TypingDongnanyaRimeOption."

        static func rimeOption(_ optionName: RimeRuntimeOption) -> String {
            "\(rimeOptionPrefix)\(optionName.rawValue)"
        }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isTranslationEnabled: Bool {
        guard userDefaults.object(forKey: SettingKey.translationEnabled) != nil else {
            return true
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

    var selectedSchemaIdentifier: String? {
        let schemaIdentifier = userDefaults.string(forKey: SettingKey.selectedSchema)
        guard let schemaIdentifier, !schemaIdentifier.isEmpty else {
            return nil
        }
        return schemaIdentifier
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

    func setSelectedSchemaIdentifier(_ schemaIdentifier: String) {
        userDefaults.set(schemaIdentifier, forKey: SettingKey.selectedSchema)
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
