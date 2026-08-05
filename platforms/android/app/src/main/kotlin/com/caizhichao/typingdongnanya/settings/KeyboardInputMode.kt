package com.caizhichao.typingdongnanya.settings

// 键盘输入形态独立于 Rime 输入方案，手写不能伪装成 librime schema。
enum class KeyboardInputMode(
    val preferenceValue: String,
) {
    KEYBOARD("keyboard"),
    HANDWRITING("handwriting");

    companion object {
        fun fromPreferenceValue(preferenceValue: String?): KeyboardInputMode {
            return entries.firstOrNull { it.preferenceValue == preferenceValue } ?: KEYBOARD
        }
    }
}
