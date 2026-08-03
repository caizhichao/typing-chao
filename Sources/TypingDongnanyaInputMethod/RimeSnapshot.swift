import Foundation

// 表达单个候选的显示文本、Rime 选择标签和词典注释，避免 UI 继续读取松散字典。
struct RimeCandidateItem {
    let textValue: String
    let labelText: String
    let commentText: String
}

// 表达 librime default.yaml 声明的一个输入方案，供输入法菜单动态构建方案选择项。
struct RimeSchemaItem {
    let identifier: String
    let displayName: String

    init(dictionary: [String: String]) {
        identifier = dictionary["identifier"] ?? ""
        displayName = dictionary["name"] ?? identifier
    }
}

// 把 librime 上下文收口为输入控制器和候选壳共用的唯一状态快照。
struct RimeSnapshot {
    let handled: Bool
    let preeditText: String
    let commitText: String
    let commitPreviewText: String
    let candidateList: [RimeCandidateItem]
    let highlightedIndex: Int
    let selectionRange: NSRange
    let caretOffset: Int
    let pageSize: Int
    let pageNumber: Int
    let isLastPage: Bool
    let schemaIdentifier: String
    let schemaName: String
    let isDisabled: Bool
    let isAsciiMode: Bool
    let isFullShape: Bool
    let isSimplified: Bool
    let isAsciiPunctuation: Bool
    let isSimplifiedChinese: Bool

    var isComposing: Bool {
        !preeditText.isEmpty
    }

    init(dictionary: [String: Any]) {
        handled = dictionary["handled"] as? Bool ?? false
        preeditText = dictionary["preedit"] as? String ?? ""
        commitText = dictionary["commitText"] as? String ?? ""
        commitPreviewText = dictionary["commitPreview"] as? String ?? ""
        highlightedIndex = dictionary["highlightedIndex"] as? Int ?? -1
        pageSize = dictionary["pageSize"] as? Int ?? 0
        pageNumber = dictionary["pageNumber"] as? Int ?? 0
        isLastPage = dictionary["isLastPage"] as? Bool ?? true
        schemaIdentifier = dictionary["schemaIdentifier"] as? String ?? ""
        schemaName = dictionary["schemaName"] as? String ?? ""
        isDisabled = dictionary["isDisabled"] as? Bool ?? false
        isAsciiMode = dictionary["isAsciiMode"] as? Bool ?? false
        isFullShape = dictionary["isFullShape"] as? Bool ?? false
        isSimplified = dictionary["isSimplified"] as? Bool ?? true
        isAsciiPunctuation = dictionary["isAsciiPunctuation"] as? Bool ?? false
        isSimplifiedChinese = dictionary["isSimplifiedChinese"] as? Bool ?? true

        let rawCandidateList = dictionary["candidates"] as? [[String: String]] ?? []
        candidateList = rawCandidateList.enumerated().map { index, candidate in
            var labelText = candidate["label"] ?? ""
            if labelText.isEmpty {
                labelText = String(index + 1)
            }
            return RimeCandidateItem(
                textValue: candidate["text"] ?? "",
                labelText: labelText,
                commentText: candidate["comment"] ?? ""
            )
        }

        let selectionStart = dictionary["selectionStart"] as? Int ?? 0
        let selectionEnd = dictionary["selectionEnd"] as? Int ?? selectionStart
        let caretPosition = dictionary["caretPosition"] as? Int ?? selectionEnd
        let selectionStartOffset = Self.utf16Offset(in: preeditText, utf8Offset: selectionStart)
        let selectionEndOffset = Self.utf16Offset(in: preeditText, utf8Offset: selectionEnd)
        selectionRange = NSRange(
            location: min(selectionStartOffset, selectionEndOffset),
            length: abs(selectionEndOffset - selectionStartOffset)
        )
        caretOffset = Self.utf16Offset(in: preeditText, utf8Offset: caretPosition)
    }

    private static func utf16Offset(in textValue: String, utf8Offset: Int) -> Int {
        let utf8View = textValue.utf8
        let boundedOffset = min(max(utf8Offset, 0), utf8View.count)
        let utf8Index = utf8View.index(utf8View.startIndex, offsetBy: boundedOffset)
        guard let stringIndex = String.Index(utf8Index, within: textValue) else {
            return 0
        }
        return textValue[..<stringIndex].utf16.count
    }
}
