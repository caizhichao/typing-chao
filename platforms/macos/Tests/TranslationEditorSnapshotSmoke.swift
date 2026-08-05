import Foundation

@main
struct TranslationEditorSnapshotSmoke {
    static func main() {
        verifyRequestEligibility()
        verifyInternalDraftAccumulation()
        verifyPureSymbolBuffering()
        verifyBackspaceEditing()
        verifyClientChangeStartsNewDraft()
        verifyClipboardDraftIsolation()
        verifyStaleSnapshotRejection()
        verifySourceLengthLimit()
        verifyInputKeyPolicy()
        print("Translation draft smoke test passed: internal marked draft, symbol buffering, Backspace editing, clipboard import, stale generation rejection, and limits")
    }

    private static func verifyRequestEligibility() {
        guard TranslationPolicy.allowsRemoteTranslation(
            isTranslationEnabled: true,
            isSecureInputActive: false
        ),
              !TranslationPolicy.allowsRemoteTranslation(
                  isTranslationEnabled: false,
                  isSecureInputActive: false
              ),
              !TranslationPolicy.allowsRemoteTranslation(
                  isTranslationEnabled: true,
                  isSecureInputActive: true
              ) else {
            fatalError("remote translation must reject disabled or secure input")
        }
    }

    // 连续候选确认只进入输入法内部草稿，快照始终包含完整最终原文。
    private static func verifyInternalDraftAccumulation() {
        var draftState = TranslationDraftState()
        guard draftState.appendConfirmedText("你好", clientIdentifier: "client-a")?.sourceText == "你好",
              let sourceSnapshot = draftState.appendConfirmedText("世界。", clientIdentifier: "client-a"),
              sourceSnapshot.sourceText == "你好世界。",
              sourceSnapshot.sourceKind == .inputMethodDraft,
              draftState.textValue == "你好世界。",
              draftState.hasText else {
            fatalError("confirmed Rime text must remain in one internal draft")
        }
    }

    // 纯符号不请求远程翻译，但后续正文必须连同前导符号进入完整快照。
    private static func verifyPureSymbolBuffering() {
        var draftState = TranslationDraftState()
        guard draftState.appendConfirmedText("（/", clientIdentifier: "client-a") == nil,
              draftState.textValue == "（/",
              let sourceSnapshot = draftState.appendConfirmedText("你好/）", clientIdentifier: "client-a"),
              sourceSnapshot.sourceText == "（/你好/）" else {
            fatalError("leading symbols must remain buffered until translatable text arrives")
        }
    }

    // 空组合态退格按扩展字素编辑内部草稿，不能依赖宿主删除正文。
    private static func verifyBackspaceEditing() {
        var draftState = TranslationDraftState()
        _ = draftState.appendConfirmedText("你好👨‍👩‍👧‍👦", clientIdentifier: "client-a")
        guard draftState.removeLastCharacter(clientIdentifier: "client-a")?.sourceText == "你好",
              draftState.textValue == "你好",
              draftState.removeLastCharacter(clientIdentifier: "client-a")?.sourceText == "你",
              draftState.removeLastCharacter(clientIdentifier: "client-a") == nil,
              !draftState.hasText else {
            fatalError("Backspace must remove one composed character from the internal draft")
        }
    }

    private static func verifyClientChangeStartsNewDraft() {
        var draftState = TranslationDraftState()
        _ = draftState.appendConfirmedText("旧会话", clientIdentifier: "client-a")
        guard let sourceSnapshot = draftState.appendConfirmedText("新会话", clientIdentifier: "client-b"),
              sourceSnapshot.sourceText == "新会话" else {
            fatalError("a different controller session must not inherit the old draft")
        }
    }

    // 剪贴板文本成为独立 marked draft，后续普通输入重新开始输入法草稿。
    private static func verifyClipboardDraftIsolation() {
        var draftState = TranslationDraftState()
        _ = draftState.appendConfirmedText("旧草稿", clientIdentifier: "client-a")
        guard let clipboardSnapshot = draftState.synchronizeClipboardText(
            "复制的完整文本",
            clientIdentifier: "client-a"
        ),
              clipboardSnapshot.sourceKind == .clipboardDraft,
              clipboardSnapshot.sourceText == "复制的完整文本",
              draftState.appendConfirmedText("新输入", clientIdentifier: "client-a")?.sourceText == "新输入" else {
            fatalError("clipboard and keyboard drafts must not concatenate")
        }
    }

    // 任何追加或删除都会使旧请求快照失效，避免迟到结果覆盖最终文本。
    private static func verifyStaleSnapshotRejection() {
        var draftState = TranslationDraftState()
        guard let firstSnapshot = draftState.appendConfirmedText("你好", clientIdentifier: "client-a") else {
            fatalError("expected first request snapshot")
        }
        _ = draftState.appendConfirmedText("世界", clientIdentifier: "client-a")
        guard draftState.resolvedSnapshot(
            clientIdentifier: "client-a",
            fallbackSnapshot: firstSnapshot
        ) == nil,
              let currentSnapshot = draftState.currentSnapshot(),
              draftState.resolvedSnapshot(
                  clientIdentifier: "client-a",
                  fallbackSnapshot: currentSnapshot
              ) == currentSnapshot else {
            fatalError("only the exact current draft snapshot may accept an async result")
        }
    }

    private static func verifySourceLengthLimit() {
        var draftState = TranslationDraftState()
        let oversizedText = String(repeating: "你", count: TranslationPolicy.maxSourceCharacters + 1)
        guard draftState.appendConfirmedText(oversizedText, clientIdentifier: "client-a") == nil,
              draftState.hasText,
              draftState.exceedsCharacterLimit else {
            fatalError("oversized draft must remain editable but must not produce a request")
        }
    }

    private static func verifyInputKeyPolicy() {
        guard TranslationPolicy.rimeKeyName(for: "\r") == "Return",
              TranslationPolicy.rimeKeyName(for: "\u{8}") == "BackSpace",
              TranslationPolicy.rimeKeyName(for: "\u{7f}") == "BackSpace",
              TranslationPolicy.rimeKeyName(for: "\u{f728}") == "Delete",
              TranslationPolicy.passThroughText(for: "space") == " ",
              TranslationPolicy.passThroughText(for: "/") == "/",
              TranslationPolicy.commandRequestsClipboardTranslation("v"),
              TranslationPolicy.commandInvalidatesTranslationDraft("z"),
              TranslationPolicy.shouldPassThroughHostEditingKey(
                  keyName: "BackSpace",
                  isComposing: false
              ),
              !TranslationPolicy.shouldPassThroughHostEditingKey(
                  keyName: "BackSpace",
                  isComposing: true
              ) else {
            fatalError("IMK control text and host shortcut policy changed unexpectedly")
        }
    }
}
