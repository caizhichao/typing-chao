import Foundation

// 记录用户主动选中的原文和替换范围，让 AI 操作只作用于本次明确选择的文本。
struct AIInputSelectionContext: Equatable {
    let selectedText: String
    let replacementRange: NSRange
}
