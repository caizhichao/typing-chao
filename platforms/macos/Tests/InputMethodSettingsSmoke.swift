import Foundation

@main
struct InputMethodSettingsSmoke {
    static func main() {
        let suiteName = "com.caizhichao.typingchao.settings-smoke"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            fatalError("unable to create settings smoke defaults")
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = InputMethodSettings(userDefaults: userDefaults)
        guard !settings.isTranslationEnabled else {
            fatalError("translation should default to disabled")
        }
        guard settings.targetLanguage == .english else {
            fatalError("target language should default to English")
        }
        guard settings.aiServiceProvider == .deepSeek else {
            fatalError("AI service should default to DeepSeek")
        }
        guard settings.selectedSchemaIdentifier == nil else {
            fatalError("schema should default to the Rime default")
        }
        guard settings.persistedRimeOptionStateList().isEmpty else {
            fatalError("Rime options should use the schema defaults before selection")
        }

        settings.setTranslationEnabled(false)
        settings.setTargetLanguage(.thai)
        settings.setSelectedSchemaIdentifier("typing_double_pinyin_natural")
        guard settings.setDeepSeekAPIKey("  test-deepseek-key  ") else {
            fatalError("DeepSeek API key cache should accept settings input")
        }
        guard settings.deepSeekAPIKey == "test-deepseek-key" else {
            fatalError("DeepSeek API key should be cached in user settings")
        }
        settings.setAIServiceProvider(.codexResponses)
        guard settings.setCurrentAPIKey("  test-codex-key  "),
              settings.codexAPIKey == "test-codex-key",
              settings.currentAPIKey == "test-codex-key" else {
            fatalError("Codex Responses API key should be cached for the selected service")
        }
        settings.persistRimeOptionStateList([
            RimeOptionState(optionName: .asciiMode, isEnabled: true),
            RimeOptionState(optionName: .fullShape, isEnabled: true),
            RimeOptionState(optionName: .simplifiedChinese, isEnabled: true),
        ])
        guard !settings.isTranslationEnabled else {
            fatalError("translation setting was not persisted")
        }
        guard settings.targetLanguage == .thai else {
            fatalError("target language setting was not persisted")
        }
        guard settings.selectedSchemaIdentifier == "typing_double_pinyin_natural" else {
            fatalError("schema setting was not persisted")
        }
        guard settings.aiServiceProvider == .codexResponses else {
            fatalError("AI service selection was not persisted")
        }
        let storedOptionStateList = settings.persistedRimeOptionStateList()
        guard !storedOptionStateList.contains(where: { $0.optionName == .asciiMode }) else {
            fatalError("ascii mode must stay session scoped")
        }
        guard storedOptionStateList.contains(where: {
            $0.optionName == .fullShape && $0.isEnabled
        }) else {
            fatalError("full shape setting was not persisted")
        }
        guard settings.setDeepSeekAPIKey(""), settings.deepSeekAPIKey == nil else {
            fatalError("DeepSeek API key should be removable from user settings")
        }
        guard settings.setAPIKey("", for: .codexResponses), settings.codexAPIKey == nil else {
            fatalError("Codex Responses API key should be removable from user settings")
        }
        print("Input method settings smoke test passed: translation, target language, schema, and Rime option scope")
    }
}
