import Foundation

// 翻译草稿来源只区分输入法逐段确认文本和用户明确导入的剪贴板文本。
enum TranslationSourceKind {
    case inputMethodDraft
    case clipboardDraft
}

// 固定一次翻译请求的完整草稿、稳定输入会话和来源，异步回写必须精确匹配。
struct TranslationSourceSnapshot: Equatable {
    let sourceText: String
    let clientIdentifier: String
    let sourceKind: TranslationSourceKind
}

// 草稿由输入法持有并通过 marked text 展示，确认译文或原文后才一次性提交宿主。
struct TranslationDraftState {
    private(set) var textValue = ""
    private var clientIdentifier: String?
    private var sourceKind = TranslationSourceKind.inputMethodDraft

    var hasText: Bool {
        !textValue.isEmpty
    }

    var exceedsCharacterLimit: Bool {
        textValue.count > TranslationPolicy.maxSourceCharacters
    }

    // Rime 已确认文本和确定的直通字符都只追加到内部草稿，不提前写入宿主正文。
    mutating func appendConfirmedText(
        _ confirmedText: String,
        clientIdentifier currentClientIdentifier: String
    ) -> TranslationSourceSnapshot? {
        if sourceKind != .inputMethodDraft {
            reset()
        }
        if let clientIdentifier, clientIdentifier != currentClientIdentifier {
            reset()
        }
        clientIdentifier = currentClientIdentifier
        sourceKind = .inputMethodDraft
        textValue += confirmedText
        return normalizedSnapshot()
    }

    // 用户明确触发剪贴板翻译时，剪贴板正文直接成为新的输入法内部草稿。
    mutating func synchronizeClipboardText(
        _ clipboardText: String,
        clientIdentifier currentClientIdentifier: String
    ) -> TranslationSourceSnapshot? {
        textValue = clipboardText
        clientIdentifier = currentClientIdentifier
        sourceKind = .clipboardDraft
        return normalizedSnapshot()
    }

    // 空组合态退格只编辑输入法内部草稿，按扩展字素删除避免拆坏 Emoji 或组合字符。
    mutating func removeLastCharacter(
        clientIdentifier currentClientIdentifier: String
    ) -> TranslationSourceSnapshot? {
        guard clientIdentifier == currentClientIdentifier, !textValue.isEmpty else {
            return normalizedSnapshot()
        }
        textValue.removeLast()
        if textValue.isEmpty {
            reset()
            return nil
        }
        return normalizedSnapshot()
    }

    // 请求开始与返回都要求当前草稿和调度快照完全一致，拒绝旧译文覆盖后续输入。
    func resolvedSnapshot(
        clientIdentifier currentClientIdentifier: String,
        fallbackSnapshot: TranslationSourceSnapshot
    ) -> TranslationSourceSnapshot? {
        guard currentClientIdentifier == fallbackSnapshot.clientIdentifier,
              normalizedSnapshot() == fallbackSnapshot else {
            return nil
        }
        return fallbackSnapshot
    }

    func currentSnapshot() -> TranslationSourceSnapshot? {
        normalizedSnapshot()
    }

    mutating func reset() {
        textValue = ""
        clientIdentifier = nil
        sourceKind = .inputMethodDraft
    }

    // 整段至少包含文字或数字时才生成请求快照，纯符号仍保留在可编辑草稿中。
    private static func containsTranslatableContent(_ textValue: String) -> Bool {
        textValue.unicodeScalars.contains { scalarValue in
            CharacterSet.letters.contains(scalarValue) ||
                CharacterSet.decimalDigits.contains(scalarValue)
        }
    }

    private func normalizedSnapshot() -> TranslationSourceSnapshot? {
        guard let clientIdentifier, !exceedsCharacterLimit else { return nil }
        let normalizedText = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty,
              Self.containsTranslatableContent(normalizedText) else {
            return nil
        }
        return TranslationSourceSnapshot(
            sourceText: normalizedText,
            clientIdentifier: clientIdentifier,
            sourceKind: sourceKind
        )
    }
}

// 当前翻译触发策略只在输入控制器和草稿状态之间共享，不引入第二套运行时状态。
enum TranslationPolicy {
    static let stableInputDelayMilliseconds = 1_000
    static let userInitiatedDelayMilliseconds = 0
    static let maxSourceCharacters = 600
    private static let spaceKeyName = "space"
    private static let spaceText = " "
    private static let invalidatingCommandKeyNameList = ["x", "z", "k"]
    private static let hostEditingKeyNameList = ["BackSpace", "Delete", "Return"]

    // IMK 可能把回车和删除作为控制文本回调，必须先还原为 librime 命名键。
    static func rimeKeyName(for textValue: String) -> String? {
        if textValue == "\r" || textValue == "\n" {
            return "Return"
        }
        if textValue == "\u{8}" || textValue == "\u{7f}" {
            return "BackSpace"
        }
        if textValue == "\u{f728}" {
            return "Delete"
        }
        guard textValue.utf8.count == 1,
              let scalarValue = textValue.unicodeScalars.first?.value,
              scalarValue >= 0x20,
              scalarValue <= 0x7e else {
            return nil
        }
        return textValue
    }

    // 已知的单个 ASCII 文本可直接进入输入法草稿，导航键和未知动作不做猜测。
    static func passThroughText(for keyName: String) -> String? {
        if keyName == spaceKeyName {
            return spaceText
        }
        guard keyName.utf8.count == 1,
              let scalarValue = keyName.unicodeScalars.first?.value,
              scalarValue >= 0x20,
              scalarValue <= 0x7e else {
            return nil
        }
        return keyName
    }

    // 只有宿主实际转发给输入法的 Command-V 才读取剪贴板，不注册全局按键监听。
    static func commandRequestsClipboardTranslation(_ keyName: String) -> Bool {
        keyName.lowercased() == "v"
    }

    // 剪切、撤销和重做先结束当前 marked draft，再把命令交还宿主。
    static func commandInvalidatesTranslationDraft(_ keyName: String) -> Bool {
        invalidatingCommandKeyNameList.contains(keyName.lowercased())
    }

    // Control 快捷键默认交还宿主，只有项目明确绑定的 Control+Period 继续交给 librime。
    static func controlShortcutUsesRime(_ keyName: String) -> Bool {
        keyName == "." || keyName.lowercased() == "period"
    }

    // 没有内部草稿时，空组合态删除与回车仍属于宿主编辑动作。
    static func shouldPassThroughHostEditingKey(keyName: String, isComposing: Bool) -> Bool {
        !isComposing && hostEditingKeyNameList.contains(keyName)
    }

    static func allowsRemoteTranslation(isTranslationEnabled: Bool, isSecureInputActive: Bool) -> Bool {
        isTranslationEnabled && !isSecureInputActive
    }
}
