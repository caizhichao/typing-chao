package com.caizhichao.typingdongnanya.settings

// Android 设置只暴露 APK 已打包且通过许可证门禁的输入方案。
enum class InputSchema(
    val schemaIdentifier: String,
    val displayName: String,
) {
    FULL_PINYIN("typing_pinyin", "全拼"),
    NATURAL_DOUBLE_PINYIN("typing_double_pinyin_natural", "自然码双拼"),
    FLYPY_DOUBLE_PINYIN("typing_double_pinyin_flypy", "小鹤双拼"),
    NINE_KEY_PINYIN("typing_pinyin_t9", "中文九键"),
    WUBI_86("typing_wubi86", "五笔 86");

    companion object {
        fun fromIdentifier(schemaIdentifier: String?): InputSchema {
            return entries.firstOrNull { it.schemaIdentifier == schemaIdentifier } ?: FULL_PINYIN
        }
    }
}
