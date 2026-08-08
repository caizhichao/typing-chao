package com.caizhichao.typingchao.settings

import android.content.Context

// 输入法设置只写应用私有 SharedPreferences，不修改系统输入源或其它输入法配置。
class SettingsStore(context: Context) {
    private val preferences = context.getSharedPreferences(preferenceFileName, Context.MODE_PRIVATE)

    // 用户未明确开启前不发起远程翻译，已保存的开关偏好保持原值。
    var translationEnabled: Boolean
        get() = preferences.getBoolean(translationEnabledKey, false)
        set(enabledValue) {
            preferences.edit().putBoolean(translationEnabledKey, enabledValue).apply()
        }

    val deepSeekAPIKey: String?
        get() = preferences.getString(deepSeekAPIKeyKey, null)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

    var targetLanguage: TargetLanguage
        get() = TargetLanguage.fromCode(preferences.getString(targetLanguageKey, null))
        set(languageValue) {
            preferences.edit().putString(targetLanguageKey, languageValue.languageCode).apply()
        }

    var inputSchema: InputSchema
        get() = InputSchema.fromIdentifier(preferences.getString(inputSchemaIdentifierKey, null))
        set(schemaValue) {
            preferences.edit().putString(inputSchemaIdentifierKey, schemaValue.schemaIdentifier).apply()
        }

    var keyboardInputMode: KeyboardInputMode
        get() = KeyboardInputMode.fromPreferenceValue(preferences.getString(keyboardInputModeKey, null))
        set(inputModeValue) {
            preferences.edit().putString(keyboardInputModeKey, inputModeValue.preferenceValue).apply()
        }

    // 设置页手动输入的 DeepSeek Key 只缓存到应用私有偏好，不写入构建产物或服务端配置。
    fun setDeepSeekAPIKey(apiKey: String) {
        val normalizedAPIKey = apiKey.trim()
        val editor = preferences.edit()
        if (normalizedAPIKey.isEmpty()) {
            editor.remove(deepSeekAPIKeyKey)
        } else {
            editor.putString(deepSeekAPIKeyKey, normalizedAPIKey)
        }
        editor.apply()
    }

    private companion object {
        const val preferenceFileName = "typing_chao_settings"
        const val translationEnabledKey = "translation_enabled"
        const val deepSeekAPIKeyKey = "deepseek_api_key"
        const val targetLanguageKey = "target_language_code"
        const val inputSchemaIdentifierKey = "input_schema_identifier"
        const val keyboardInputModeKey = "keyboard_input_mode"
    }
}
