import Foundation

@main
struct InputMethodSettingsSmoke {
    static func main() {
        let suiteName = "com.caizhichao.typing-dongnanya.settings-smoke"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            fatalError("unable to create settings smoke defaults")
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = InputMethodSettings(userDefaults: userDefaults)
        guard settings.isTranslationEnabled else {
            fatalError("translation should default to enabled")
        }
        guard settings.targetLanguage == .english else {
            fatalError("target language should default to English")
        }
        guard settings.selectedSchemaIdentifier == nil else {
            fatalError("schema should default to the Rime default")
        }
        guard settings.persistedRimeOptionStateList().isEmpty else {
            fatalError("Rime options should use the schema defaults before selection")
        }

        settings.setTranslationEnabled(false)
        settings.setTargetLanguage(.thai)
        settings.setSelectedSchemaIdentifier("luna_pinyin")
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
        guard settings.selectedSchemaIdentifier == "luna_pinyin" else {
            fatalError("schema setting was not persisted")
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
        print("Input method settings smoke test passed: translation, target language, schema, and Rime option scope")
    }
}
