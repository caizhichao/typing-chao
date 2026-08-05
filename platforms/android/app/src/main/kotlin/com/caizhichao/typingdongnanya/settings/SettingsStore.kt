package com.caizhichao.typingdongnanya.settings

import android.content.Context

// 输入法设置只写应用私有 SharedPreferences，不修改系统输入源或其它输入法配置。
class SettingsStore(context: Context) {
    private val preferences = context.getSharedPreferences(preferenceFileName, Context.MODE_PRIVATE)

    var translationEnabled: Boolean
        get() = preferences.getBoolean(translationEnabledKey, true)
        set(enabledValue) {
            preferences.edit().putBoolean(translationEnabledKey, enabledValue).apply()
        }

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

    private companion object {
        const val preferenceFileName = "typing_dongnanya_settings"
        const val translationEnabledKey = "translation_enabled"
        const val targetLanguageKey = "target_language_code"
        const val inputSchemaIdentifierKey = "input_schema_identifier"
        const val keyboardInputModeKey = "keyboard_input_mode"
    }
}
