import Foundation

// 常用符号候选不应拉起候选窗；保留拼音分隔符、翻页和直接提交标点的既有语义。
enum RimeInputPolicy {
    private static let pinyinDelimiterKeyName = "'"

    // macOS ANSI 虚拟键码只用于补全 InputMethodKit 无文本回调中的候选翻页键。
    private enum CandidatePagingKeyCode {
        static let ansiEqual = 0x18 // 主键盘等号/加号键
        static let ansiMinus = 0x1B // 主键盘减号键
        static let keypadPlus = 0x45 // 数字键盘加号键
        static let keypadMinus = 0x4E // 数字键盘减号键
    }

    // 候选翻页键与浮层箭头共用同一页状态：减号回上一页，等号/加号进下一页。
    static func candidatePageBackward(
        keyName: String,
        snapshot: RimeSnapshot
    ) -> Bool? {
        guard snapshot.isComposing,
              !snapshot.candidateList.isEmpty else {
            return nil
        }
        let normalizedKeyName = keyName.lowercased()
        if (normalizedKeyName == "-" ||
            normalizedKeyName == "minus" ||
            normalizedKeyName == "kp_subtract"),
           snapshot.pageNumber > 0 {
            return true
        }
        if (normalizedKeyName == "=" ||
            normalizedKeyName == "+" ||
            normalizedKeyName == "equal" ||
            normalizedKeyName == "plus" ||
            normalizedKeyName == "kp_add"),
           !snapshot.isLastPage {
            return false
        }
        return nil
    }

    // 带键码入口没有 printable string 时仍把主键盘和数字键盘的加减号恢复成翻页键。
    static func candidatePagingKeyName(forPhysicalKeyCode keyCode: Int) -> String? {
        switch keyCode {
        case CandidatePagingKeyCode.ansiEqual:
            return "="
        case CandidatePagingKeyCode.ansiMinus:
            return "-"
        case CandidatePagingKeyCode.keypadPlus:
            return "+"
        case CandidatePagingKeyCode.keypadMinus:
            return "-"
        default:
            return nil
        }
    }

    static func directSymbolCandidateIndex(
        keyName: String,
        previousSnapshot: RimeSnapshot,
        currentSnapshot: RimeSnapshot
    ) -> Int? {
        guard isSingleSymbolKey(keyName),
              !(previousSnapshot.isComposing && keyName == pinyinDelimiterKeyName),
              currentSnapshot.isComposing,
              !currentSnapshot.commitPreviewText.isEmpty,
              currentSnapshot.commitPreviewText != previousSnapshot.commitPreviewText,
              !currentSnapshot.candidateList.isEmpty else {
            return nil
        }
        if !currentSnapshot.isFullShape,
           let exactCandidateIndex = currentSnapshot.candidateList.firstIndex(
               where: { $0.textValue == keyName }
           ) {
            return exactCandidateIndex
        }
        if currentSnapshot.highlightedIndex >= 0,
           currentSnapshot.highlightedIndex < currentSnapshot.candidateList.count {
            return currentSnapshot.highlightedIndex
        }
        return 0
    }

    private static func isSingleSymbolKey(_ keyName: String) -> Bool {
        guard keyName.unicodeScalars.count == 1,
              let scalarValue = keyName.unicodeScalars.first else {
            return false
        }
        return CharacterSet.punctuationCharacters.contains(scalarValue) ||
            CharacterSet.symbols.contains(scalarValue)
    }
}
