// 单个等号只负责显示 AI 候选，不再把后续字符拼成命令前缀。
struct AIInputCommandState {
    static let triggerText = "="

    private(set) var isPending = false

    var isTriggerReady: Bool {
        isPending
    }

    // 只有独立的普通等号才能进入 AI 候选状态，重复触发或其它字符都直接交回原输入链路。
    mutating func activateTrigger(keyName: String, isPlainKey: Bool) -> Bool {
        guard !isPending,
              isPlainKey,
              keyName == Self.triggerText else {
            return false
        }
        isPending = true
        return true
    }

    mutating func reset() {
        isPending = false
    }
}
