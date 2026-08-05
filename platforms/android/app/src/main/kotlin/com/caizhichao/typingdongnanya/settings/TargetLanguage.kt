package com.caizhichao.typingdongnanya.settings

// 首版目标语言只保留已确认的东南亚常用语种与英语，不引入自由文本配置。
enum class TargetLanguage(
    val languageCode: String,
    val displayName: String,
    val serviceLanguageName: String,
) {
    ENGLISH("en", "英语", "English"),
    THAI("th", "泰语", "Thai"),
    VIETNAMESE("vi", "越南语", "Vietnamese"),
    INDONESIAN("id", "印尼语", "Indonesian"),
    MALAY("ms", "马来语", "Malay");

    companion object {
        fun fromCode(languageCode: String?): TargetLanguage {
            return entries.firstOrNull { it.languageCode == languageCode } ?: ENGLISH
        }
    }
}
