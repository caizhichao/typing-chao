import Foundation

// 常用符号候选不应拉起候选窗；保留拼音分隔符、翻页和直接提交标点的既有语义。
enum RimeInputPolicy {
    private static let pinyinDelimiterKeyName = "'"

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
