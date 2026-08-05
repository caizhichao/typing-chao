package com.caizhichao.typingdongnanya.rime

// 单次 librime 动作的完整可见快照是候选 UI 与草稿提交的唯一状态来源。
class RimeSnapshot {
    @JvmField var preeditText: String = ""
    @JvmField var commitText: String = ""
    @JvmField var schemaIdentifier: String = ""
    @JvmField var schemaName: String = ""
    @JvmField var wasHandled: Boolean = false
    @JvmField var candidateList: Array<RimeCandidate> = emptyArray()
    @JvmField var highlightedIndex: Int = -1
    @JvmField var pageNumber: Int = 0
    @JvmField var isLastPage: Boolean = true
    @JvmField var isComposing: Boolean = false
    @JvmField var isAsciiMode: Boolean = false
    @JvmField var isFullShape: Boolean = false
    @JvmField var isAsciiPunctuation: Boolean = false
    @JvmField var isSimplifiedChinese: Boolean = true

    companion object {
        fun emptySnapshot(): RimeSnapshot = RimeSnapshot()
    }
}
