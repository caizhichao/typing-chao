package com.caizhichao.typingdongnanya.settings

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import com.caizhichao.typingdongnanya.R

// 设置页负责启用引导、目标语言和翻译开关，不在输入法浮层里挤入完整配置表单。
class SettingsActivity : Activity() {
    private lateinit var settingsStore: SettingsStore
    private lateinit var installationStatusView: TextView
    private lateinit var schemaSpinner: Spinner
    private lateinit var languageSpinner: Spinner
    private lateinit var translationSwitch: Switch

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settingsStore = SettingsStore(this)
        setContentView(buildContentView())
    }

    override fun onResume() {
        super.onResume()
        refreshInstallationStatus()
    }

    // 页面离开前统一持久化当前选项，输入法下一次获得焦点时读取最新值。
    override fun onPause() {
        val selectedSchema = InputSchema.entries.getOrNull(schemaSpinner.selectedItemPosition)
        if (selectedSchema != null) {
            settingsStore.inputSchema = selectedSchema
        }
        val selectedLanguage = TargetLanguage.entries.getOrNull(languageSpinner.selectedItemPosition)
        if (selectedLanguage != null) {
            settingsStore.targetLanguage = selectedLanguage
        }
        settingsStore.translationEnabled = translationSwitch.isChecked
        super.onPause()
    }

    private fun buildContentView(): View {
        val scrollContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(28), dp(24), dp(36))
            setBackgroundColor(Color.rgb(245, 247, 250))
        }
        scrollContent.addView(TextView(this).apply {
            text = getString(R.string.app_name)
            textSize = 28f
            setTextColor(Color.rgb(18, 38, 48))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        scrollContent.addView(TextView(this).apply {
            text = "全拼、双拼、九键、五笔、离线手写与整句边写边译"
            textSize = 15f
            setTextColor(Color.rgb(83, 102, 113))
            setPadding(0, dp(6), 0, dp(24))
        })

        installationStatusView = sectionText("")
        scrollContent.addView(installationStatusView)
        scrollContent.addView(primaryButton("打开系统键盘设置") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        })
        scrollContent.addView(secondaryButton("选择当前输入法") {
            val inputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            inputMethodManager.showInputMethodPicker()
        })

        scrollContent.addView(sectionTitle("中文输入"))
        scrollContent.addView(sectionText("拼音方案"))
        schemaSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                InputSchema.entries.map { it.displayName },
            )
            setSelection(InputSchema.entries.indexOf(settingsStore.inputSchema))
        }
        scrollContent.addView(schemaSpinner, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(52),
        ))
        scrollContent.addView(sectionText("键盘底栏可在按键输入与离线手写之间切换；手写模型随应用安装，不需要下载模型或申请系统隐私权限。"))

        scrollContent.addView(sectionTitle("边写边译"))
        translationSwitch = Switch(this).apply {
            text = "启用停止输入 1 秒后的整句翻译"
            textSize = 16f
            isChecked = settingsStore.translationEnabled
            setTextColor(Color.rgb(24, 46, 56))
            setPadding(0, dp(8), 0, dp(12))
        }
        scrollContent.addView(translationSwitch)
        scrollContent.addView(sectionText("目标语言"))
        languageSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@SettingsActivity,
                android.R.layout.simple_spinner_dropdown_item,
                TargetLanguage.entries.map { it.displayName },
            )
            setSelection(TargetLanguage.entries.indexOf(settingsStore.targetLanguage))
        }
        scrollContent.addView(languageSpinner, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(52),
        ))

        scrollContent.addView(sectionTitle("使用说明"))
        scrollContent.addView(sectionText(
            "候选确认后，原文会先作为输入法草稿显示在当前编辑框。停止输入 1 秒后出现译文，可选择“使用译文”或“原文上屏”。密码等安全输入框不会发送远程翻译请求。",
        ))
        return android.widget.ScrollView(this).apply {
            addView(scrollContent)
        }
    }

    private fun refreshInstallationStatus() {
        val inputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val packageNameValue = packageName
        val enabledValue = inputMethodManager.enabledInputMethodList.any {
            it.packageName == packageNameValue
        }
        val selectedValue = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD,
        )?.startsWith(packageNameValue) == true
        installationStatusView.text = when {
            selectedValue -> "当前状态：Typing 东南亚正在使用"
            enabledValue -> "当前状态：已启用，请点击下方按钮切换"
            else -> "当前状态：尚未启用，请先在系统键盘设置中开启"
        }
    }

    private fun sectionTitle(titleText: String): TextView {
        return TextView(this).apply {
            text = titleText
            textSize = 19f
            setTextColor(Color.rgb(18, 38, 48))
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(0, dp(28), 0, dp(8))
        }
    }

    private fun sectionText(contentText: String): TextView {
        return TextView(this).apply {
            text = contentText
            textSize = 15f
            setTextColor(Color.rgb(73, 93, 104))
            setLineSpacing(0f, 1.18f)
            setPadding(0, dp(4), 0, dp(12))
        }
    }

    private fun primaryButton(labelText: String, clickAction: () -> Unit): Button {
        return Button(this).apply {
            text = labelText
            isAllCaps = false
            textSize = 16f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(23, 107, 135))
            setOnClickListener { clickAction() }
        }
    }

    private fun secondaryButton(labelText: String, clickAction: () -> Unit): Button {
        return Button(this).apply {
            text = labelText
            isAllCaps = false
            textSize = 16f
            setTextColor(Color.rgb(23, 107, 135))
            setOnClickListener { clickAction() }
        }
    }

    private fun dp(dpValue: Int): Int {
        return (dpValue * resources.displayMetrics.density).toInt()
    }
}
