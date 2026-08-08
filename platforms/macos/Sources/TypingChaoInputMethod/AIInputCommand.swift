// 等号命令入口先作为 marked text 正常展示，候选确认前不直接打开 AI 面板。
enum AIInputCommandAction: Equatable {
    case passThrough
    case updateMarkedText(String)
    case commitMarkedText(String)
}

// 负责识别单个等号命令入口；后续数字候选可在输入控制器中按序扩展。
struct AIInputCommandState {
    static let triggerText = "="

    private(set) var pendingText = ""

    var isPending: Bool {
        !pendingText.isEmpty
    }

    var isTriggerReady: Bool {
        pendingText == Self.triggerText
    }

    mutating func consume(keyName: String, isPlainKey: Bool) -> AIInputCommandAction {
        if pendingText.isEmpty {
            guard isPlainKey, keyName == Self.triggerText else {
                return .passThrough
            }
            pendingText = Self.triggerText
            return .updateMarkedText(pendingText)
        }

        return .commitMarkedText(flushPendingText())
    }

    // 退格只移除当前可见的等号 marked text，不向 librime 回放虚构按键。
    mutating func deleteBackward() -> String {
        guard !pendingText.isEmpty else {
            return ""
        }
        pendingText.removeLast()
        return pendingText
    }

    mutating func flushPendingText() -> String {
        let textValue = pendingText
        pendingText = ""
        return textValue
    }

    mutating func reset() {
        pendingText = ""
    }
}
