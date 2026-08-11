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
            let aiInputResult = try await service.requestAIInput(
                promptText: "只输出 LOCAL_RESPONSE_OK，不要输出其它文字。"
            )
            guard aiInputResult == "LOCAL_RESPONSE_OK" else {
                fatalError("local Responses AI input result mismatch: \(aiInputResult)")
            }

            let conversationResult = try await service.requestAIInput(
                promptText: "上一条回复中的暗号是什么？只输出暗号。",
                conversationMessageList: [
                    AIConversationMessage(roleName: "user", contentText: "请记住暗号是 CONVERSATION_RESPONSE_OK。"),
                    AIConversationMessage(roleName: "assistant", contentText: "已记住，暗号是 CONVERSATION_RESPONSE_OK。"),
                ]
            )
            guard conversationResult.contains("CONVERSATION_RESPONSE_OK") else {
                fatalError("local Responses conversation result mismatch: \(conversationResult)")
            }

            let translationResult = try await service.translate("你好")
            guard translationResult.lowercased().contains("hello") else {
                fatalError("local Responses translation result mismatch: \(translationResult)")
            }
            print("Translation service smoke test passed: local 8317 Responses, gpt-5.6-luna, AI input, conversation, and translation")
        } catch {
            fatalError("local Responses request failed: \(error.localizedDescription)")
        }
    }
}
