import Foundation
import InputMethodKit

// 固定一次翻译请求的原文、客户端和可验证替换范围，避免异步结果读取后续可变状态。
struct TranslationSourceSnapshot {
    let sourceText: String
    let replacementRange: NSRange?
    let clientIdentifier: ObjectIdentifier
    let replacementVerified: Bool

    var canReplaceSource: Bool {
        replacementRange != nil && replacementVerified
    }
}

// 维护当前输入会话的稳定文本，并优先从客户端光标前重建完整当前句。
struct TranslationDraftState {
    private var sourceText = ""
    private var replacementRange: NSRange?
    private var clientIdentifier: ObjectIdentifier?
    private var replacementVerified = false
    private var sourceExceededCharacterLimit = false

    // 新提交文本先进入会话缓冲，客户端可读时直接升级为光标前完整当前句。
    mutating func appendCommittedText(_ committedText: String, client: IMKTextInput) -> TranslationSourceSnapshot? {
        let currentClientIdentifier = ObjectIdentifier(client as AnyObject)
        if let clientIdentifier, clientIdentifier != currentClientIdentifier {
            reset()
        }
        clientIdentifier = currentClientIdentifier

        let previousText = sourceText
        let fullAppendedText = previousText + committedText
        let appendedText = Self.clippedSourceText(fullAppendedText)
        if fullAppendedText.count > TranslationPolicy.maxSourceCharacters {
            sourceExceededCharacterLimit = true
        }
        if let documentSnapshot = Self.currentSentenceSnapshot(
            client: client,
            clientIdentifier: currentClientIdentifier
        ), documentSnapshot.sourceText.hasSuffix(committedText) {
            sourceText = documentSnapshot.sourceText
            replacementRange = documentSnapshot.replacementRange
            replacementVerified = true
            sourceExceededCharacterLimit = false
            return normalizedSnapshot()
        }

        let selectedRange = client.selectedRange()
        let committedLength = committedText.utf16.count
        let insertedRange = Self.insertedRange(
            selectedRange: selectedRange,
            committedLength: committedLength
        )
        if previousText.isEmpty {
            replacementRange = insertedRange
        } else if let replacementRange,
                  let insertedRange,
                  insertedRange.location == NSMaxRange(replacementRange) {
            self.replacementRange = NSRange(
                location: replacementRange.location,
                length: replacementRange.length + insertedRange.length
            )
        } else {
            replacementRange = nil
        }
        replacementVerified = false
        sourceText = appendedText
        if sourceExceededCharacterLimit {
            replacementRange = nil
        }
        return normalizedSnapshot()
    }

    // 请求真正开始前重新读取光标前完整当前句，不能再退回最后一次提交片段。
    func resolvedSnapshot(client: IMKTextInput, fallbackSnapshot: TranslationSourceSnapshot) -> TranslationSourceSnapshot {
        let currentClientIdentifier = ObjectIdentifier(client as AnyObject)
        guard currentClientIdentifier == fallbackSnapshot.clientIdentifier else {
            return fallbackSnapshot
        }
        return Self.currentSentenceSnapshot(
            client: client,
            clientIdentifier: currentClientIdentifier
        ) ?? fallbackSnapshot
    }

    func currentSnapshot() -> TranslationSourceSnapshot? {
        normalizedSnapshot()
    }

    mutating func reset() {
        sourceText = ""
        replacementRange = nil
        clientIdentifier = nil
        replacementVerified = false
        sourceExceededCharacterLimit = false
    }

    // 句末请求已经保存独立快照后只清空下一句缓冲，不影响正在返回的译文。
    mutating func startNextSentence() {
        sourceText = ""
        replacementRange = nil
        replacementVerified = false
        sourceExceededCharacterLimit = false
    }

    private func normalizedSnapshot() -> TranslationSourceSnapshot? {
        guard let clientIdentifier, !sourceExceededCharacterLimit else { return nil }
        let normalizedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return nil }

        var normalizedRange = replacementRange
        if normalizedText != sourceText, let replacementRange {
            let localRange = (sourceText as NSString).range(of: normalizedText)
            if localRange.location != NSNotFound {
                normalizedRange = NSRange(
                    location: replacementRange.location + localRange.location,
                    length: localRange.length
                )
            } else {
                normalizedRange = nil
            }
        }
        return TranslationSourceSnapshot(
            sourceText: normalizedText,
            replacementRange: normalizedRange,
            clientIdentifier: clientIdentifier,
            replacementVerified: replacementVerified
        )
    }

    private static func clippedSourceText(_ textValue: String) -> String {
        guard textValue.count > TranslationPolicy.maxSourceCharacters else {
            return textValue
        }
        return String(textValue.suffix(TranslationPolicy.maxSourceCharacters))
    }

    private static func insertedRange(selectedRange: NSRange, committedLength: Int) -> NSRange? {
        guard selectedRange.location != NSNotFound,
              selectedRange.length == 0,
              selectedRange.location >= committedLength else {
            return nil
        }
        return NSRange(
            location: selectedRange.location - committedLength,
            length: committedLength
        )
    }

    // 从光标向前读取当前行，并以最近的句末标点或换行作为整句起点。
    private static func currentSentenceSnapshot(
        client: IMKTextInput,
        clientIdentifier: ObjectIdentifier
    ) -> TranslationSourceSnapshot? {
        let selectedRange = client.selectedRange()
        guard selectedRange.location != NSNotFound,
              selectedRange.length == 0,
              selectedRange.location > 0 else {
            return nil
        }

        let readLength = min(selectedRange.location, TranslationPolicy.maxSourceCharacters)
        let readRange = NSRange(
            location: selectedRange.location - readLength,
            length: readLength
        )
        guard let documentText = client.attributedSubstring(from: readRange)?.string else {
            return nil
        }

        let documentNSString = documentText as NSString
        guard let sentenceRange = TranslationSentenceBoundary.currentSentenceRange(in: documentText) else {
            return nil
        }
        if readRange.location > 0, sentenceRange.location == 0 {
            return nil
        }
        let sentenceText = documentNSString.substring(with: sentenceRange)
        let documentStartLocation = selectedRange.location - documentNSString.length
        return TranslationSourceSnapshot(
            sourceText: sentenceText,
            replacementRange: NSRange(
                location: documentStartLocation + sentenceRange.location,
                length: sentenceRange.length
            ),
            clientIdentifier: clientIdentifier,
            replacementVerified: true
        )
    }
}

// 当前翻译触发策略只在输入控制器和草稿状态之间共享，不引入运行时模式开关。
enum TranslationPolicy {
    static let stableInputDelayMilliseconds = 1_000
    static let userInitiatedDelayMilliseconds = 180
    static let maxSourceCharacters = 600
    static let sentenceBoundaryCharacters = CharacterSet(charactersIn: "。！？!?；;")

    // 自动请求发现稳定期内文档原文已变化时必须重新计满一秒，手动请求直接使用当前快照。
    static func shouldRestartStableDelay(
        scheduledSourceText: String,
        resolvedSourceText: String,
        userInitiated: Bool
    ) -> Bool {
        guard !userInitiated else { return false }
        return scheduledSourceText != resolvedSourceText
    }

    static func allowsRemoteTranslation(isTranslationEnabled: Bool, isSecureInputActive: Bool) -> Bool {
        guard isTranslationEnabled, !isSecureInputActive else {
            return false
        }
        return true
    }
}
