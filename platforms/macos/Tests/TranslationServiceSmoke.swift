import Foundation

@main
struct TranslationServiceSmoke {
    static func main() async {
        guard let localAPIKey = ProcessInfo.processInfo.environment["TYPINGCHAO_LOCAL_AI_KEY"],
              !localAPIKey.isEmpty else {
            fatalError("TYPINGCHAO_LOCAL_AI_KEY is required for the local Responses smoke test")
        }

        let suiteName = "com.caizhichao.typingchao.translation-service-smoke"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            fatalError("unable to create translation service smoke defaults")
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = InputMethodSettings(userDefaults: userDefaults)
        settings.setAIServiceProvider(.codexResponses)
        guard settings.setCurrentAPIKey(localAPIKey) else {
            fatalError("unable to configure the local Responses API key")
        }

        let service = TranslationService(inputMethodSettings: settings)
        do {
            let translationResult = try await service.translate("你好")
            guard translationResult.lowercased().contains("hello") else {
                fatalError("local Responses translation result mismatch: \(translationResult)")
            }
            print("Translation service smoke test passed: local 8317 Responses translation")
        } catch {
            fatalError("local Responses request failed: \(error.localizedDescription)")
        }
    }
}
