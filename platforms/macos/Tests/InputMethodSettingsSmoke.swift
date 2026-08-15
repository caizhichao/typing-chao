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
        guard settings.customBaseURL(for: .deepSeek) == nil,
              settings.baseURL(for: .deepSeek).absoluteString == "https://api.deepseek.com",
              settings.requestURL(for: .deepSeek).absoluteString == "https://api.deepseek.com/chat/completions",
              settings.modelName(for: .deepSeek) == "deepseek-v4-flash",
              settings.modelListURL(for: .deepSeek).absoluteString == "https://api.deepseek.com/models" else {
            fatalError("DeepSeek should use the official default Base URL and chat completion path")
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
        guard !settings.setBaseURL("not-a-url", for: .deepSeek) else {
            fatalError("invalid Base URL should be rejected")
        }
        guard settings.setBaseURL("  https://gateway.example.com/deepseek  ", for: .deepSeek),
              settings.customBaseURL(for: .deepSeek)?.absoluteString == "https://gateway.example.com/deepseek",
              settings.requestURL(for: .deepSeek).absoluteString == "https://gateway.example.com/deepseek/chat/completions" else {
            fatalError("DeepSeek custom Base URL should be cached and combined with the protocol path")
        }
        settings.setAIServiceProvider(.codexResponses)
        guard settings.setCurrentAPIKey("  test-codex-key  "),
              settings.codexAPIKey == "test-codex-key",
              settings.currentAPIKey == "test-codex-key" else {
            fatalError("Codex Responses API key should be cached for the selected service")
        }
        guard settings.baseURL(for: .codexResponses).absoluteString == "http://127.0.0.1:8317/v1",
              settings.requestURL(for: .codexResponses).absoluteString == "http://127.0.0.1:8317/v1/responses",
              settings.modelName(for: .codexResponses) == "gpt-5.6-luna",
              settings.modelListURL(for: .codexResponses).absoluteString == "http://127.0.0.1:8317/v1/models" else {
            fatalError("Codex Responses should use the local default Base URL and Responses path")
        }
        guard settings.setCurrentBaseURL("  http://127.0.0.1:9000/custom/v1  "),
              settings.customBaseURL(for: .codexResponses)?.absoluteString == "http://127.0.0.1:9000/custom/v1",
              settings.requestURL(for: .codexResponses).absoluteString == "http://127.0.0.1:9000/custom/v1/responses" else {
            fatalError("Codex Responses custom Base URL should stay scoped to the selected service")
        }
        guard settings.setCurrentModelName("  custom-codex-model  "),
              settings.modelName(for: .codexResponses) == "custom-codex-model" else {
            fatalError("selected model should be cached for the selected service")
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
        guard settings.setBaseURL("", for: .deepSeek),
              settings.setBaseURL("", for: .codexResponses),
              settings.setModelName("", for: .codexResponses),
              settings.customBaseURL(for: .deepSeek) == nil,
              settings.customBaseURL(for: .codexResponses) == nil,
              settings.modelName(for: .codexResponses) == "gpt-5.6-luna" else {
            fatalError("custom Base URLs and selected models should be removable per service")
        }
        print("Input method settings smoke test passed: translation, AI Key/Base URL/model, target language, schema, and Rime option scope")
    }
}
