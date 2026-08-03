import Foundation

@main
struct TranslationSentenceBoundarySmoke {
    static func main() {
        verifyRange("你好😀", expectedText: "你好😀")
        verifyRange("上一句。你好😀", expectedText: "你好😀")
        verifyRange("你好😀。  ", expectedText: "你好😀。")
        verifyRange("first\n你好😀", expectedText: "你好😀")
        verifyRange("你好😀; next", expectedText: "next")
        verifyRequestEligibility()
        print("Translation sentence boundary smoke test passed: Emoji, punctuation, whitespace, request eligibility, and debounce")
    }

    private static func verifyRequestEligibility() {
        guard TranslationPolicy.stableInputDelayMilliseconds == 1_000 else {
            fatalError("automatic translation must wait for one second of stable input")
        }
        guard TranslationPolicy.userInitiatedDelayMilliseconds < TranslationPolicy.stableInputDelayMilliseconds else {
            fatalError("the explicit translation shortcut should remain more responsive than automatic translation")
        }
        guard TranslationPolicy.shouldRestartStableDelay(
            scheduledSourceText: "旧文本",
            resolvedSourceText: "最终文本",
            userInitiated: false
        ) else {
            fatalError("automatic translation must restart the stable delay when the document changed silently")
        }
        guard !TranslationPolicy.shouldRestartStableDelay(
            scheduledSourceText: "最终文本",
            resolvedSourceText: "最终文本",
            userInitiated: false
        ) else {
            fatalError("stable automatic text must be allowed to send")
        }
        guard TranslationPolicy.allowsRemoteTranslation(
            isTranslationEnabled: true,
            isSecureInputActive: false
        ) else {
            fatalError("normal typing should allow translation")
        }
        guard !TranslationPolicy.allowsRemoteTranslation(
            isTranslationEnabled: false,
            isSecureInputActive: false
        ) else {
            fatalError("disabled translation must not send a request")
        }
        guard !TranslationPolicy.allowsRemoteTranslation(
            isTranslationEnabled: true,
            isSecureInputActive: true
        ) else {
            fatalError("secure input must not send a request")
        }
    }

    private static func verifyRange(_ documentText: String, expectedText: String) {
        guard let sentenceRange = TranslationSentenceBoundary.currentSentenceRange(in: documentText) else {
            fatalError("missing sentence range for: \(documentText)")
        }
        let actualText = (documentText as NSString).substring(with: sentenceRange)
        guard actualText == expectedText else {
            fatalError("expected \(expectedText), got \(actualText)")
        }
    }
}
