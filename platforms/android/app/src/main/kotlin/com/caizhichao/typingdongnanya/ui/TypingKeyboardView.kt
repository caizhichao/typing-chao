package com.caizhichao.typingdongnanya.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import com.caizhichao.typingdongnanya.rime.RimeCandidate

// 原生 View 键盘让候选与翻译共用固定高度栏位，避免状态变化反复撑高或缩短键盘。
@SuppressLint("ViewConstructor")
class TypingKeyboardView(
    context: Context,
    private val actionListener: ActionListener,
) : LinearLayout(context) {
    interface ActionListener {
        fun onTextKey(keyText: String)
        fun onBackspace()
        fun onClearComposition()
        fun onClearDraft()
        fun onEnter()
        fun onSpace()
        fun onToggleAsciiMode()
        fun onToggleHandwritingMode()
        fun onHandwritingChanged(hasInkValue: Boolean)
        fun onSwitchInputMethod()
        fun onPasteClipboard()
        fun onCandidateSelected(candidateIndex: Int)
        fun onPageChanged(pageBackward: Boolean)
        fun onUseTranslation()
        fun onCommitOriginal()
        fun onOpenSettings()
    }

    private val repeatedActionHandler = Handler(Looper.getMainLooper())
    private var repeatedActionValue: (() -> Unit)? = null
    private val repeatedActionRunnable = object : Runnable {
        override fun run() {
            val repeatedAction = repeatedActionValue ?: return
            repeatedAction()
            repeatedActionHandler.postDelayed(this, backspaceRepeatIntervalMilliseconds)
        }
    }
    private val translationCard = LinearLayout(context)
    private val languagePairView = TextView(context)
    private val translationMessageView = TextView(context)
    private val translationActionRow = LinearLayout(context)
    private val useTranslationButton = Button(context)
    private val commitOriginalButton = Button(context)
    private val candidateContainer = LinearLayout(context)
    private val keyboardRowsContainer = LinearLayout(context)
    private var renderedNineKeyLayout: Boolean? = null
    private var renderedWubiLayout: Boolean? = null
    private var renderedHandwritingMode: Boolean? = null
    private val candidateScrollView = HorizontalScrollView(context)
    private val pageBackwardButton = keyTextView("‹") { actionListener.onPageChanged(true) }
    private val pageForwardButton = keyTextView("›") { actionListener.onPageChanged(false) }
    private val asciiModeButton = keyTextView("中") { actionListener.onToggleAsciiMode() }
    private val switchInputMethodButton = keyTextView("🌐") { actionListener.onSwitchInputMethod() }
    private val enterButton = keyTextView("换行") { actionListener.onEnter() }
    private val handwritingCanvasView = HandwritingCanvasView(context) { hasInkValue ->
        actionListener.onHandwritingChanged(hasInkValue)
    }
    private val backspaceButton = repeatableKeyTextView(
        "⌫",
        { actionListener.onBackspace() },
        { actionListener.onClearDraft() },
    )

    init {
        orientation = VERTICAL
        setPadding(dp(6), dp(6), dp(6), dp(8))
        setBackgroundColor(surfaceColor)
        addView(buildCandidateBar())
        keyboardRowsContainer.orientation = VERTICAL
        addView(keyboardRowsContainer)
        renderKeyboardRows(false, false, false)
    }

    // 候选与翻译只在同一个 48dp 栏位内切换，任何翻译状态都不改变输入法整体高度。
    fun render(stateValue: KeyboardUiState) {
        val candidateVisibleValue = stateValue.candidateList.isNotEmpty()
        candidateScrollView.visibility = if (candidateVisibleValue) VISIBLE else GONE
        translationCard.visibility = if (candidateVisibleValue) GONE else VISIBLE
        languagePairView.text = stateValue.languagePairTitle
        val resultText = stateValue.translatedText
        translationMessageView.text = when {
            resultText != null -> resultText
            stateValue.translationVisible -> stateValue.translationMessage
            else -> "译文将在这里显示"
        }
        translationMessageView.setTextColor(if (resultText == null) secondaryTextColor else primaryTextColor)
        translationActionRow.visibility = if (stateValue.translationActionVisible && !candidateVisibleValue) VISIBLE else GONE
        renderCandidates(
            stateValue.candidateList,
            stateValue.highlightedCandidateIndex,
            stateValue.pageNumber,
            stateValue.isLastPage,
        )
        asciiModeButton.text = if (stateValue.isAsciiMode) "英" else "中"
        switchInputMethodButton.visibility = if (stateValue.canSwitchInputMethod) VISIBLE else GONE
        enterButton.text = stateValue.enterKeyLabel
        renderKeyboardRows(stateValue.isNineKeyLayout, stateValue.isWubiLayout, stateValue.isHandwritingMode)
        isEnabled = stateValue.engineReady
        alpha = if (stateValue.engineReady) 1f else 0.72f
    }

    private fun buildTranslationCard(): View {
        translationCard.apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(3), dp(4), dp(3))
            visibility = VISIBLE
        }
        val translationTextColumn = LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER_VERTICAL
        }
        languagePairView.apply {
            textSize = 10f
            setTextColor(accentColor)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
        }
        translationMessageView.apply {
            textSize = 14f
            setTextColor(primaryTextColor)
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
            setLineSpacing(0f, 1.02f)
            setOnClickListener {
                if (translationActionRow.visibility == VISIBLE) {
                    performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    actionListener.onUseTranslation()
                }
            }
        }
        translationActionRow.apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            visibility = GONE
        }
        configureActionButton(useTranslationButton, "使用", true) {
            actionListener.onUseTranslation()
        }
        configureActionButton(commitOriginalButton, "原文", false) {
            actionListener.onCommitOriginal()
        }
        translationActionRow.addView(commitOriginalButton)
        translationActionRow.addView(useTranslationButton)
        translationTextColumn.addView(languagePairView)
        translationTextColumn.addView(translationMessageView)
        translationCard.addView(translationTextColumn, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
        translationCard.addView(translationActionRow)
        return translationCard
    }

    private fun buildCandidateBar(): View {
        val candidateBar = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = roundedBackground(Color.WHITE, dp(12).toFloat(), borderColor)
            minimumHeight = dp(48)
        }
        candidateScrollView.apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = OVER_SCROLL_NEVER
            addView(candidateContainer.apply {
                orientation = HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(2), 0, dp(2), 0)
            })
        }
        candidateBar.addView(buildTranslationCard(), LayoutParams(0, dp(48), 1f))
        candidateBar.addView(candidateScrollView, LayoutParams(0, dp(48), 1f))
        pageBackwardButton.visibility = GONE
        pageForwardButton.visibility = GONE
        candidateBar.addView(pageBackwardButton, LayoutParams(dp(38), dp(42)))
        candidateBar.addView(pageForwardButton, LayoutParams(dp(38), dp(42)))
        candidateBar.addView(keyTextView("⚙") { actionListener.onOpenSettings() }, LayoutParams(dp(44), dp(42)))
        return candidateBar.apply {
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, dp(48)).apply {
                bottomMargin = dp(6)
            }
        }
    }

    private fun buildAlphabetKeyboardRows(wubiLayoutValue: Boolean): View {
        return LinearLayout(context).apply {
            orientation = VERTICAL
            addView(letterRow(listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p"), wubiLayoutValue = wubiLayoutValue))
            addView(letterRow(
                listOf("a", "s", "d", "f", "g", "h", "j", "k", "l"),
                horizontalInset = 14,
                wubiLayoutValue = wubiLayoutValue,
            ))
            addView(actionRow(listOf(
                KeySpec("，", 1f) { actionListener.onTextKey(",") },
                letterKeySpec("z", wubiLayoutValue),
                letterKeySpec("x", wubiLayoutValue),
                letterKeySpec("c", wubiLayoutValue),
                letterKeySpec("v", wubiLayoutValue),
                letterKeySpec("b", wubiLayoutValue),
                letterKeySpec("n", wubiLayoutValue),
                letterKeySpec("m", wubiLayoutValue),
                KeySpec("⌫", 1.25f, customView = backspaceButton),
            )))
            addView(actionRow(listOf(
                KeySpec("中/英", 1.25f, customView = asciiModeButton),
                KeySpec("切换", 0.9f, customView = switchInputMethodButton),
                KeySpec("手写", 1f) { actionListener.onToggleHandwritingMode() },
                KeySpec("粘贴", 0.9f) { actionListener.onPasteClipboard() },
                KeySpec("空格", 2.75f) { actionListener.onSpace() },
                KeySpec("。", 1f) { actionListener.onTextKey(".") },
                KeySpec("换行", 1.4f, customView = enterButton),
            )))
        }
    }

    // 输入方案改变时只重建键区，不重建候选和翻译栏，避免键盘高度和网络状态抖动。
    private fun renderKeyboardRows(
        nineKeyLayoutValue: Boolean,
        wubiLayoutValue: Boolean,
        handwritingModeValue: Boolean,
    ) {
        if (renderedNineKeyLayout == nineKeyLayoutValue &&
            renderedWubiLayout == wubiLayoutValue &&
            renderedHandwritingMode == handwritingModeValue
        ) {
            return
        }
        renderedNineKeyLayout = nineKeyLayoutValue
        renderedWubiLayout = wubiLayoutValue
        renderedHandwritingMode = handwritingModeValue
        keyboardRowsContainer.removeAllViews()
        keyboardRowsContainer.addView(
            when {
                handwritingModeValue -> buildHandwritingRows()
                nineKeyLayoutValue -> buildNineKeyKeyboardRows()
                else -> buildAlphabetKeyboardRows(wubiLayoutValue)
            },
        )
    }

    // 九键按成熟中文输入法的职责分区组织标点、数字、编辑键和底部模式键，不复制第三方代码或视觉资源。
    private fun buildNineKeyKeyboardRows(): View {
        return LinearLayout(context).apply {
            orientation = VERTICAL
            addView(LinearLayout(context).apply {
                orientation = HORIZONTAL
                addView(nineKeySideColumn(listOf(
                    KeySpec("，", 1f) { actionListener.onTextKey(",") },
                    KeySpec("。", 1f) { actionListener.onTextKey(".") },
                    KeySpec("？", 1f) { actionListener.onTextKey("?") },
                    KeySpec("！", 1f) { actionListener.onTextKey("!") },
                )), LayoutParams(0, dp(162), 0.8f))
                addView(LinearLayout(context).apply {
                    orientation = VERTICAL
                    addView(actionRow(listOf(
                        KeySpec("", 1f, customView = stackedKeyView("1", "符号") { actionListener.onTextKey("1") }),
                        KeySpec("", 1f, customView = stackedKeyView("2", "ABC") { actionListener.onTextKey("2") }),
                        KeySpec("", 1f, customView = stackedKeyView("3", "DEF") { actionListener.onTextKey("3") }),
                    )))
                    addView(actionRow(listOf(
                        KeySpec("", 1f, customView = stackedKeyView("4", "GHI") { actionListener.onTextKey("4") }),
                        KeySpec("", 1f, customView = stackedKeyView("5", "JKL") { actionListener.onTextKey("5") }),
                        KeySpec("", 1f, customView = stackedKeyView("6", "MNO") { actionListener.onTextKey("6") }),
                    )))
                    addView(actionRow(listOf(
                        KeySpec("", 1f, customView = stackedKeyView("7", "PQRS") { actionListener.onTextKey("7") }),
                        KeySpec("", 1f, customView = stackedKeyView("8", "TUV") { actionListener.onTextKey("8") }),
                        KeySpec("", 1f, customView = stackedKeyView("9", "WXYZ") { actionListener.onTextKey("9") }),
                    )))
                }, LayoutParams(0, dp(162), 3.2f))
                addView(nineKeySideColumn(listOf(
                    KeySpec("⌫", 1f, customView = backspaceButton),
                    KeySpec("重输", 1f) { actionListener.onClearComposition() },
                    KeySpec("换行", 1.25f, customView = enterButton),
                )), LayoutParams(0, dp(162), 0.9f))
            }, LayoutParams(LayoutParams.MATCH_PARENT, dp(162)))
            addView(actionRow(listOf(
                KeySpec("切换", 0.8f, customView = switchInputMethodButton),
                KeySpec("手写", 0.9f) { actionListener.onToggleHandwritingMode() },
                KeySpec("粘贴", 0.9f) { actionListener.onPasteClipboard() },
                KeySpec("", 2.5f, customView = stackedKeyView("0", "空格") { actionListener.onSpace() }),
                KeySpec("中/英", 1f, customView = asciiModeButton),
            )), LayoutParams(LayoutParams.MATCH_PARENT, dp(54)))
        }
    }

    // 九键侧栏使用纵向权重分配高度，保证主键区总高度固定且换行键拥有更大的触控区域。
    private fun nineKeySideColumn(keyList: List<KeySpec>): View {
        return LinearLayout(context).apply {
            orientation = VERTICAL
            for (keyValue in keyList) {
                val keyView = keyValue.customView ?: keyTextView(keyValue.labelText) { keyValue.action() }
                (keyView.parent as? ViewGroup)?.removeView(keyView)
                addView(keyView, verticalKeyLayoutParams(keyValue.weightValue))
            }
        }
    }

    // 手写区与四行键盘保持相同总高度，工具栏只保留模式切换、笔迹编辑和宿主必要动作。
    private fun buildHandwritingRows(): View {
        return LinearLayout(context).apply {
            orientation = VERTICAL
            handwritingCanvasView.background = roundedBackground(Color.WHITE, dp(12).toFloat(), borderColor)
            handwritingCanvasView.clipToOutline = true
            addView(handwritingCanvasView, LayoutParams(LayoutParams.MATCH_PARENT, dp(162)).apply {
                setMargins(dp(3), 0, dp(3), 0)
            })
            addView(actionRow(listOf(
                KeySpec("键盘", 1f) { actionListener.onToggleHandwritingMode() },
                KeySpec("撤销", 1f) { handwritingCanvasView.undoLastStroke() },
                KeySpec("清空", 1f) { handwritingCanvasView.clearStrokes() },
                KeySpec("粘贴", 1f) { actionListener.onPasteClipboard() },
                KeySpec("⌫", 1f, customView = backspaceButton),
                KeySpec("换行", 1.2f, customView = enterButton),
            )))
        }
    }

    fun createHandwritingBitmap(): Bitmap? {
        return handwritingCanvasView.createRecognitionBitmap()
    }

    fun clearHandwritingCanvas() {
        handwritingCanvasView.clearStrokes(false)
    }

    private fun letterRow(
        letterList: List<String>,
        horizontalInset: Int = 0,
        wubiLayoutValue: Boolean = false,
    ): View {
        return LinearLayout(context).apply {
            orientation = HORIZONTAL
            setPadding(dp(horizontalInset), 0, dp(horizontalInset), 0)
            for (letterText in letterList) {
                val labelText = letterKeyLabel(letterText, wubiLayoutValue)
                addView(keyTextView(labelText) { actionListener.onTextKey(letterText) }, keyLayoutParams(1f))
            }
        }
    }

    private fun letterKeySpec(letterText: String, wubiLayoutValue: Boolean): KeySpec {
        return KeySpec(letterKeyLabel(letterText, wubiLayoutValue), 1f) {
            actionListener.onTextKey(letterText)
        }
    }

    private fun letterKeyLabel(letterText: String, wubiLayoutValue: Boolean): String {
        val rootHintText = if (wubiLayoutValue) wubiRootHintMap[letterText] else null
        return if (rootHintText == null) letterText else "$letterText\n$rootHintText"
    }

    // 方案切换会复用中英、切换、删除和回车键，加入新行前必须先从旧键区安全解绑。
    private fun actionRow(keyList: List<KeySpec>): View {
        return LinearLayout(context).apply {
            orientation = HORIZONTAL
            for (keyValue in keyList) {
                val keyView = keyValue.customView ?: keyTextView(keyValue.labelText) { keyValue.action() }
                (keyView.parent as? ViewGroup)?.removeView(keyView)
                addView(keyView, keyLayoutParams(keyValue.weightValue))
            }
        }
    }

    private fun renderCandidates(
        candidateList: List<RimeCandidate>,
        highlightedIndex: Int,
        pageNumber: Int,
        isLastPage: Boolean,
    ) {
        candidateContainer.removeAllViews()
        candidateList.forEachIndexed { candidateIndex, candidateValue ->
            candidateContainer.addView(candidateView(candidateValue, candidateIndex, candidateIndex == highlightedIndex))
        }
        pageBackwardButton.visibility = if (pageNumber > 0) VISIBLE else GONE
        pageForwardButton.visibility = if (!isLastPage && candidateList.isNotEmpty()) VISIBLE else GONE
    }

    private fun candidateView(candidateValue: RimeCandidate, candidateIndex: Int, highlightedValue: Boolean): View {
        return LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(3), dp(12), dp(3))
            background = if (highlightedValue) roundedBackground(selectionColor, dp(9).toFloat()) else null
            addView(TextView(context).apply {
                text = candidateValue.textValue
                textSize = 20f
                gravity = Gravity.CENTER
                setTextColor(primaryTextColor)
            })
            if (candidateValue.commentText.isNotBlank()) {
                addView(TextView(context).apply {
                    text = candidateValue.commentText
                    textSize = 9f
                    gravity = Gravity.CENTER
                    setTextColor(secondaryTextColor)
                    maxLines = 1
                })
            }
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                actionListener.onCandidateSelected(candidateIndex)
            }
        }
    }

    private fun keyTextView(labelText: String, clickAction: () -> Unit): TextView {
        return TextView(context).apply {
            text = labelText
            textSize = 17f
            gravity = Gravity.CENTER
            setTextColor(primaryTextColor)
            background = roundedBackground(keyColor, dp(9).toFloat(), borderColor)
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                clickAction()
            }
        }
    }

    // 数字与功能说明分层绘制，避免原始换行在不同字体缩放和屏幕密度下产生裁切或基线错位。
    private fun stackedKeyView(
        primaryText: String,
        secondaryText: String,
        clickAction: () -> Unit,
    ): View {
        return LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
            background = roundedBackground(keyColor, dp(9).toFloat(), borderColor)
            addView(TextView(context).apply {
                text = primaryText
                textSize = 18f
                gravity = Gravity.CENTER
                setTextColor(primaryTextColor)
            })
            addView(TextView(context).apply {
                text = secondaryText
                textSize = 9.5f
                gravity = Gravity.CENTER
                setTextColor(secondaryTextColor)
            })
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                clickAction()
            }
        }
    }

    // 删除键按下立即执行一次，持续按住越过首轮延迟后稳定连删，松手或取消时立即停止。
    @SuppressLint("ClickableViewAccessibility")
    private fun repeatableKeyTextView(
        labelText: String,
        repeatedAction: () -> Unit,
        clearAction: () -> Unit,
    ): TextView {
        var suppressTouchClickValue = false
        var touchStartRawY = 0f
        var clearArmedValue = false
        return TextView(context).apply {
            text = labelText
            textSize = 17f
            gravity = Gravity.CENTER
            setTextColor(primaryTextColor)
            background = roundedBackground(keyColor, dp(9).toFloat(), borderColor)
            setOnClickListener {
                if (!suppressTouchClickValue) {
                    performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    repeatedAction()
                }
            }
            setOnTouchListener { touchedView, motionEvent ->
                when (motionEvent.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        suppressTouchClickValue = true
                        touchStartRawY = motionEvent.rawY
                        clearArmedValue = false
                        text = labelText
                        touchedView.isPressed = true
                        touchedView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        repeatedAction()
                        startRepeatedAction(repeatedAction)
                        true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!clearArmedValue && touchStartRawY - motionEvent.rawY >= dp(backspaceClearSwipeDistanceDp)) {
                            clearArmedValue = true
                            stopRepeatedAction()
                            text = "清空"
                            touchedView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        }
                        true
                    }
                    MotionEvent.ACTION_UP -> {
                        stopRepeatedAction()
                        touchedView.isPressed = false
                        if (clearArmedValue) clearAction()
                        text = labelText
                        touchedView.performClick()
                        suppressTouchClickValue = false
                        clearArmedValue = false
                        true
                    }
                    MotionEvent.ACTION_CANCEL -> {
                        stopRepeatedAction()
                        touchedView.isPressed = false
                        text = labelText
                        suppressTouchClickValue = false
                        clearArmedValue = false
                        true
                    }
                    else -> true
                }
            }
        }
    }

    // 同一时刻只允许一个连续动作，避免 View 重建或重复按下留下多个删除循环。
    private fun startRepeatedAction(repeatedAction: () -> Unit) {
        stopRepeatedAction()
        repeatedActionValue = repeatedAction
        repeatedActionHandler.postDelayed(repeatedActionRunnable, backspaceRepeatInitialDelayMilliseconds)
    }

    private fun stopRepeatedAction() {
        repeatedActionHandler.removeCallbacks(repeatedActionRunnable)
        repeatedActionValue = null
    }

    override fun onDetachedFromWindow() {
        stopRepeatedAction()
        super.onDetachedFromWindow()
    }

    private fun keyLayoutParams(weightValue: Float): LayoutParams {
        return LayoutParams(0, dp(48), weightValue).apply {
            setMargins(dp(3), dp(3), dp(3), dp(3))
        }
    }

    private fun verticalKeyLayoutParams(weightValue: Float): LayoutParams {
        return LayoutParams(LayoutParams.MATCH_PARENT, 0, weightValue).apply {
            setMargins(dp(3), dp(3), dp(3), dp(3))
        }
    }

    private fun configureActionButton(
        buttonView: Button,
        labelText: String,
        primaryValue: Boolean,
        clickAction: () -> Unit,
    ) {
        buttonView.apply {
            text = labelText
            isAllCaps = false
            textSize = 12f
            minHeight = 0
            minimumHeight = 0
            minWidth = 0
            minimumWidth = 0
            setPadding(dp(8), dp(4), dp(8), dp(4))
            setTextColor(if (primaryValue) Color.WHITE else accentColor)
            background = roundedBackground(if (primaryValue) accentColor else Color.TRANSPARENT, dp(10).toFloat())
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                clickAction()
            }
            layoutParams = LayoutParams(LayoutParams.WRAP_CONTENT, dp(32)).apply {
                marginStart = dp(4)
            }
        }
    }

    private fun roundedBackground(fillColor: Int, radiusValue: Float, strokeColor: Int? = null): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = radiusValue
            setColor(fillColor)
            if (strokeColor != null) {
                setStroke(dp(1), strokeColor)
            }
        }
    }

    private fun dp(dpValue: Int): Int {
        return (dpValue * resources.displayMetrics.density).toInt()
    }

    private data class KeySpec(
        val labelText: String,
        val weightValue: Float,
        val customView: View? = null,
        val action: () -> Unit = {},
    )

    private companion object {
        // 五笔 86 主键区只显示通用字根分区提示，不复制任何第三方键盘视觉资源。
        val wubiRootHintMap = mapOf(
            "a" to "工", "b" to "子", "c" to "又", "d" to "大", "e" to "月",
            "f" to "土", "g" to "王", "h" to "目", "i" to "水", "j" to "日",
            "k" to "口", "l" to "田", "m" to "山", "n" to "已", "o" to "火",
            "p" to "之", "q" to "金", "r" to "白", "s" to "木", "t" to "禾",
            "u" to "立", "v" to "女", "w" to "人", "x" to "纟", "y" to "言",
        )
        val surfaceColor = Color.rgb(231, 235, 240)
        val keyColor = Color.rgb(252, 253, 254)
        val borderColor = Color.rgb(211, 218, 225)
        val primaryTextColor = Color.rgb(28, 43, 51)
        val secondaryTextColor = Color.rgb(103, 119, 128)
        val accentColor = Color.rgb(23, 107, 135)
        val selectionColor = Color.rgb(220, 241, 245)
        const val backspaceRepeatInitialDelayMilliseconds = 350L
        const val backspaceRepeatIntervalMilliseconds = 55L
        const val backspaceClearSwipeDistanceDp = 42
    }
}
