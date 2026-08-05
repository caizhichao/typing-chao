package com.caizhichao.typingdongnanya.ime

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.inputmethodservice.InputMethodService
import com.caizhichao.typingdongnanya.handwriting.HandwritingRecognizer
import com.caizhichao.typingdongnanya.rime.RimeDataInstaller
import com.caizhichao.typingdongnanya.rime.RimeCandidate
import com.caizhichao.typingdongnanya.rime.RimeNative
import com.caizhichao.typingdongnanya.rime.RimeSnapshot
import com.caizhichao.typingdongnanya.settings.InputSchema
import com.caizhichao.typingdongnanya.settings.KeyboardInputMode
import com.caizhichao.typingdongnanya.settings.SettingsActivity
import com.caizhichao.typingdongnanya.settings.SettingsStore
import com.caizhichao.typingdongnanya.settings.TargetLanguage
import com.caizhichao.typingdongnanya.translation.TranslationCoordinator
import com.caizhichao.typingdongnanya.ui.KeyboardUiState
import com.caizhichao.typingdongnanya.ui.TypingKeyboardView
import java.util.concurrent.Executors

// Android 输入法主链统一维护 librime 会话、内部原文草稿、宿主 composing text 与翻译代次。
class TypingDongnanyaInputMethodService : InputMethodService(),
    TypingKeyboardView.ActionListener,
    TranslationCoordinator.Listener {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val engineExecutor = Executors.newSingleThreadExecutor()
    private val handwritingExecutor = Executors.newSingleThreadExecutor()
    private val draftState = ImeDraft()
    private val translationCoordinator = TranslationCoordinator(this)

    private lateinit var settingsStore: SettingsStore
    private lateinit var handwritingRecognizer: HandwritingRecognizer
    private var keyboardView: TypingKeyboardView? = null
    private var rimeSessionIdentifier = 0L
    private var rimeSnapshot = RimeSnapshot.emptySnapshot()
    private var engineReadyValue = false
    private var engineErrorMessage: String? = null
    private var secureEditorValue = false
    private var editorActionValue = EditorInfo.IME_ACTION_NONE
    private var translationStatus: TranslationStatus = TranslationStatus.Hidden
    private var translatedTextValue: String? = null
    private var handwritingGenerationValue = 0L
    private var handwritingRecognitionRunnable: Runnable? = null
    private var handwritingStatus: HandwritingStatus = HandwritingStatus.Idle
    private var handwritingCandidateList: List<RimeCandidate> = emptyList()

    override fun onCreate() {
        super.onCreate()
        settingsStore = SettingsStore(this)
        handwritingRecognizer = HandwritingRecognizer(this)
        prepareRimeEngine()
    }

    override fun onCreateInputView(): View {
        return TypingKeyboardView(this, this).also { createdView ->
            keyboardView = createdView
            renderKeyboard()
        }
    }

    // 输入法始终保留宿主页面上下文，横屏也不进入系统全屏提取编辑模式。
    override fun onEvaluateFullscreenMode(): Boolean = false

    // 新编辑器必须清空上一宿主的组合与翻译事务，不能把草稿跨输入框带入。
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        translationCoordinator.invalidate()
        translatedTextValue = null
        translationStatus = TranslationStatus.Hidden
        resetHandwritingRecognition(true)
        draftState.clear()
        secureEditorValue = attribute?.let(::isSecureEditor) == true
        editorActionValue = attribute?.imeOptions?.and(EditorInfo.IME_MASK_ACTION)
            ?: EditorInfo.IME_ACTION_NONE
        if (rimeSessionIdentifier != 0L) {
            RimeNative.clearComposition(rimeSessionIdentifier)
            rimeSnapshot = RimeNative.currentSnapshot(rimeSessionIdentifier)
        }
        updateHostComposingText()
        renderKeyboard()
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        settingsStore = SettingsStore(this)
        secureEditorValue = info?.let(::isSecureEditor) == true
        applyStoredInputSchema()
        refreshTranslationForCurrentDraft()
        renderKeyboard()
    }

    // 宿主自行粘贴时只捕获“选区变化长度、光标前正文和当前剪贴板完全一致”的文本，避免读取或接管其它编辑内容。
    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(
            oldSelStart,
            oldSelEnd,
            newSelStart,
            newSelEnd,
            candidatesStart,
            candidatesEnd,
        )
        captureHostPastedText(oldSelStart, oldSelEnd, newSelStart, newSelEnd)
    }

    // 输入连接即将结束时优先上屏用户原文，避免系统切换编辑器后遗失 marked draft。
    override fun onFinishInput() {
        commitOriginalDraft()
        resetHandwritingRecognition(true)
        super.onFinishInput()
    }

    override fun onDestroy() {
        translationCoordinator.close()
        resetHandwritingRecognition(true)
        if (rimeSessionIdentifier != 0L) {
            RimeNative.destroySession(rimeSessionIdentifier)
            rimeSessionIdentifier = 0L
        }
        engineExecutor.shutdownNow()
        handwritingExecutor.shutdownNow()
        runCatching { handwritingRecognizer.close() }.onFailure { errorValue ->
            Log.e(logTag, "Handwriting recognizer shutdown failed", errorValue)
        }
        super.onDestroy()
    }

    override fun onTextKey(keyText: String) {
        if (settingsStore.keyboardInputMode == KeyboardInputMode.HANDWRITING) return
        processRimeKey(keyText, keyText)
    }

    override fun onBackspace() {
        if (!engineReadyValue) return
        if (rimeSnapshot.isComposing) {
            applyRimeSnapshot(RimeNative.processKey(rimeSessionIdentifier, "BackSpace"))
            return
        }
        if (draftState.removeLastCharacter()) {
            updateHostComposingText()
            refreshTranslationForCurrentDraft()
            renderKeyboard()
            return
        }
        currentInputConnection?.deleteSurroundingText(1, 0)
    }

    override fun onEnter() {
        if (!engineReadyValue) return
        resetHandwritingRecognition(true)
        if (rimeSnapshot.isComposing) {
            applyRimeSnapshot(RimeNative.commitComposition(rimeSessionIdentifier))
        }
        if (draftState.textValue.isNotEmpty()) {
            commitOriginalDraft()
        } else {
            performEnterAction()
        }
    }

    override fun onSpace() {
        if (!engineReadyValue) return
        if (rimeSnapshot.isComposing) {
            applyRimeSnapshot(RimeNative.processKey(rimeSessionIdentifier, "space"))
            return
        }
        if (draftState.textValue.isEmpty()) {
            currentInputConnection?.commitText(" ", 1)
            return
        }
        draftState.append(" ")
        updateHostComposingText()
        refreshTranslationForCurrentDraft()
        renderKeyboard()
    }

    override fun onToggleAsciiMode() {
        if (!engineReadyValue) return
        applyRimeSnapshot(
            RimeNative.setOption(
                rimeSessionIdentifier,
                "ascii_mode",
                !rimeSnapshot.isAsciiMode,
            ),
        )
    }

    // 手写和按键输入共用同一原文草稿，切换模式时只收口当前 Rime 组合，不提交宿主正文。
    override fun onToggleHandwritingMode() {
        if (!engineReadyValue) return
        val nextMode = if (settingsStore.keyboardInputMode == KeyboardInputMode.HANDWRITING) {
            KeyboardInputMode.KEYBOARD
        } else {
            KeyboardInputMode.HANDWRITING
        }
        if (nextMode == KeyboardInputMode.HANDWRITING && rimeSnapshot.isComposing) {
            val committedSnapshot = RimeNative.commitComposition(rimeSessionIdentifier)
            rimeSnapshot = committedSnapshot
            if (committedSnapshot.commitText.isNotEmpty()) {
                draftState.append(committedSnapshot.commitText)
            }
            updateHostComposingText()
            refreshTranslationForCurrentDraft()
        }
        settingsStore.keyboardInputMode = nextMode
        resetHandwritingRecognition(true)
        renderKeyboard()
    }

    // 笔迹变化只重置代次并安排一次停顿识别，移动过程不会提交推理任务。
    override fun onHandwritingChanged(hasInkValue: Boolean) {
        if (settingsStore.keyboardInputMode != KeyboardInputMode.HANDWRITING) return
        invalidateHandwritingRecognition()
        handwritingCandidateList = emptyList()
        if (!hasInkValue) {
            handwritingStatus = HandwritingStatus.Idle
            renderKeyboard()
            return
        }
        handwritingStatus = HandwritingStatus.Waiting
        val requestGeneration = handwritingGenerationValue
        val recognitionRunnable = Runnable {
            handwritingRecognitionRunnable = null
            val bitmapValue = keyboardView?.createHandwritingBitmap()
            if (bitmapValue == null) {
                handwritingStatus = HandwritingStatus.Idle
                renderKeyboard()
                return@Runnable
            }
            handwritingStatus = HandwritingStatus.Loading
            renderKeyboard()
            handwritingExecutor.execute {
                val recognitionResult = runCatching { handwritingRecognizer.recognize(bitmapValue) }
                bitmapValue.recycle()
                mainHandler.post {
                    if (requestGeneration != handwritingGenerationValue ||
                        settingsStore.keyboardInputMode != KeyboardInputMode.HANDWRITING
                    ) {
                        return@post
                    }
                    recognitionResult.onSuccess { recognitionCandidateList ->
                        handwritingCandidateList = recognitionCandidateList.map { candidateValue ->
                            RimeCandidate().apply {
                                textValue = candidateValue.textValue
                                commentText = "手写"
                            }
                        }
                        handwritingStatus = if (handwritingCandidateList.isEmpty()) {
                            HandwritingStatus.Failure("未识别到文字，请写大一点后重试")
                        } else {
                            HandwritingStatus.Result
                        }
                    }.onFailure { errorValue ->
                        Log.e(logTag, "Handwriting recognition failed", errorValue)
                        handwritingCandidateList = emptyList()
                        handwritingStatus = HandwritingStatus.Failure("手写识别失败，请清空后重试")
                    }
                    renderKeyboard()
                }
            }
        }
        handwritingRecognitionRunnable = recognitionRunnable
        mainHandler.postDelayed(recognitionRunnable, handwritingRecognitionDelayMilliseconds)
        renderKeyboard()
    }

    @Suppress("DEPRECATION")
    override fun onSwitchInputMethod() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            switchToNextInputMethod(false)
            return
        }
        val inputMethodWindowToken = window.window?.attributes?.token ?: return
        val inputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        inputMethodManager.switchToNextInputMethod(inputMethodWindowToken, false)
    }

    override fun onPasteClipboard() {
        val clipboardText = currentClipboardText()
        if (clipboardText == null) {
            translationCoordinator.invalidate()
            translatedTextValue = null
            translationStatus = TranslationStatus.ClipboardUnavailable
            renderKeyboard()
            return
        }
        resetHandwritingRecognition(true)
        appendClipboardText(clipboardText)
    }

    // 九键“重输”只清除当前未确认组合和旧译文，保留已经进入草稿的正文。
    override fun onClearComposition() {
        clearCompositionAndTranslation()
    }

    // 上滑删除只清除尚未正式上屏的拼音和翻译草稿，不删除宿主已有历史正文。
    override fun onClearDraft() {
        translationCoordinator.invalidate()
        resetHandwritingRecognition(true)
        draftState.clear()
        translatedTextValue = null
        translationStatus = TranslationStatus.Hidden
        if (rimeSessionIdentifier != 0L) {
            RimeNative.clearComposition(rimeSessionIdentifier)
            rimeSnapshot = RimeNative.currentSnapshot(rimeSessionIdentifier)
        }
        currentInputConnection?.commitText("", 1)
        renderKeyboard()
    }

    override fun onCandidateSelected(candidateIndex: Int) {
        if (settingsStore.keyboardInputMode == KeyboardInputMode.HANDWRITING) {
            val selectedCandidate = handwritingCandidateList.getOrNull(candidateIndex) ?: return
            draftState.append(selectedCandidate.textValue)
            resetHandwritingRecognition(true)
            updateHostComposingText()
            refreshTranslationForCurrentDraft()
            renderKeyboard()
            return
        }
        if (!engineReadyValue || candidateIndex < 0) return
        applyRimeSnapshot(RimeNative.selectCandidate(rimeSessionIdentifier, candidateIndex))
    }

    override fun onPageChanged(pageBackward: Boolean) {
        if (settingsStore.keyboardInputMode == KeyboardInputMode.HANDWRITING) return
        if (!engineReadyValue) return
        applyRimeSnapshot(RimeNative.changePage(rimeSessionIdentifier, pageBackward))
    }

    // 译文直接提交到仍有效的 composing 区，由宿主原子替换原文草稿，不能先结束组合后追加。
    override fun onUseTranslation() {
        val translatedText = translatedTextValue ?: return
        val inputConnection = currentInputConnection ?: return
        inputConnection.commitText(translatedText, 1)
        clearCurrentTransaction()
    }

    override fun onCommitOriginal() {
        commitOriginalDraft()
    }

    override fun onOpenSettings() {
        commitOriginalDraft()
        startActivity(Intent(this, SettingsActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    override fun onTranslationLoading(sourceText: String) {
        if (draftState.normalizedSourceText() != sourceText) return
        translationStatus = TranslationStatus.Loading
        translatedTextValue = null
        renderKeyboard()
    }

    override fun onTranslationResult(sourceText: String, translatedText: String) {
        if (draftState.normalizedSourceText() != sourceText) return
        translationStatus = TranslationStatus.Result
        translatedTextValue = translatedText
        renderKeyboard()
    }

    override fun onTranslationFailure(sourceText: String, userMessage: String) {
        if (draftState.normalizedSourceText() != sourceText) return
        translationStatus = TranslationStatus.Failure(userMessage)
        translatedTextValue = null
        renderKeyboard()
    }

    // 物理键盘只接管无 Command/Control/Alt 的文本键，宿主快捷键前先收口当前原文草稿。
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (event.isCtrlPressed || event.isMetaPressed || event.isAltPressed) {
            commitOriginalDraft()
            return super.onKeyDown(keyCode, event)
        }
        if (!engineReadyValue) {
            return super.onKeyDown(keyCode, event)
        }
        return when (keyCode) {
            KeyEvent.KEYCODE_DEL -> {
                onBackspace()
                true
            }
            KeyEvent.KEYCODE_ENTER -> {
                onEnter()
                true
            }
            KeyEvent.KEYCODE_SPACE -> {
                onSpace()
                true
            }
            KeyEvent.KEYCODE_ESCAPE -> {
                clearCompositionAndTranslation()
                true
            }
            else -> {
                val unicodeValue = event.unicodeChar
                if (unicodeValue in 0x20..0x7E) {
                    val keyText = unicodeValue.toChar().toString()
                    processRimeKey(keyText, keyText)
                    true
                } else {
                    super.onKeyDown(keyCode, event)
                }
            }
        }
    }

    private fun prepareRimeEngine() {
        engineExecutor.execute {
            val initializationResult = runCatching {
                val dataDirectories = RimeDataInstaller.prepare(applicationContext)
                check(RimeNative.initialize(
                    dataDirectories.sharedDataDirectory.absolutePath,
                    dataDirectories.userDataDirectory.absolutePath,
                ))
                val sessionIdentifier = RimeNative.createSession()
                check(sessionIdentifier != 0L)
                sessionIdentifier
            }
            mainHandler.post {
                initializationResult.onSuccess { sessionIdentifier ->
                    rimeSessionIdentifier = sessionIdentifier
                    rimeSnapshot = RimeNative.selectSchema(
                        sessionIdentifier,
                        settingsStore.inputSchema.schemaIdentifier,
                    )
                    engineReadyValue = true
                    engineErrorMessage = null
                }.onFailure { errorValue ->
                    Log.e(logTag, "Rime engine initialization failed", errorValue)
                    engineReadyValue = false
                    engineErrorMessage = "拼音引擎初始化失败，请重新安装应用后再试"
                }
                refreshTranslationForCurrentDraft()
                renderKeyboard()
            }
        }
    }

    // librime 提交内容只进入内部原文草稿，直到用户明确选择译文或原文上屏。
    private fun applyRimeSnapshot(snapshotValue: RimeSnapshot, fallbackText: String? = null) {
        val compositionChangedValue = rimeSnapshot.preeditText != snapshotValue.preeditText ||
            rimeSnapshot.isComposing != snapshotValue.isComposing
        rimeSnapshot = snapshotValue
        var draftChangedValue = false
        if (snapshotValue.commitText.isNotEmpty()) {
            draftState.append(snapshotValue.commitText)
            draftChangedValue = true
        } else if (!snapshotValue.wasHandled && fallbackText != null) {
            draftState.append(fallbackText)
            draftChangedValue = true
        }
        updateHostComposingText()
        if (draftChangedValue || compositionChangedValue) {
            refreshTranslationForCurrentDraft()
        }
        renderKeyboard()
    }

    // 设置页选择的方案只切换当前 librime 会话，切换前清空未确认组合并保留宿主输入法身份。
    private fun applyStoredInputSchema() {
        if (!engineReadyValue || rimeSessionIdentifier == 0L) return
        val selectedSchema = settingsStore.inputSchema
        if (rimeSnapshot.schemaIdentifier == selectedSchema.schemaIdentifier) return
        translationCoordinator.invalidate()
        translatedTextValue = null
        translationStatus = TranslationStatus.Hidden
        RimeNative.clearComposition(rimeSessionIdentifier)
        rimeSnapshot = RimeNative.selectSchema(
            rimeSessionIdentifier,
            selectedSchema.schemaIdentifier,
        )
        updateHostComposingText()
    }

    private fun processRimeKey(keyName: String, fallbackText: String?) {
        if (!engineReadyValue || rimeSessionIdentifier == 0L) return
        applyRimeSnapshot(
            RimeNative.processKey(rimeSessionIdentifier, keyName),
            fallbackText,
        )
    }

    // 键盘粘贴按钮始终把剪贴板正文并入同一内部草稿，再从最后一次变化重新等待 1 秒翻译。
    private fun appendClipboardText(clipboardText: String) {
        if (rimeSnapshot.isComposing && rimeSessionIdentifier != 0L) {
            val committedSnapshot = RimeNative.commitComposition(rimeSessionIdentifier)
            rimeSnapshot = committedSnapshot
            if (committedSnapshot.commitText.isNotEmpty()) {
                draftState.append(committedSnapshot.commitText)
            }
        }
        draftState.append(clipboardText)
        updateHostComposingText()
        refreshTranslationForCurrentDraft()
        renderKeyboard()
    }

    // 系统菜单粘贴已先进入宿主时，只把精确匹配当前剪贴板的新增范围重新标记为本输入法 composing 草稿。
    private fun captureHostPastedText(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
    ) {
        if (!engineReadyValue || secureEditorValue || !settingsStore.translationEnabled) return
        if (draftState.textValue.isNotEmpty() || rimeSnapshot.isComposing) return
        if (oldSelStart < 0 || oldSelEnd < 0 || newSelStart < 0 || newSelStart != newSelEnd) return
        val replacedSelectionStart = minOf(oldSelStart, oldSelEnd)
        val clipboardText = currentClipboardText() ?: return
        if (clipboardText.length < minimumHostPasteCharacters) return
        if (newSelStart != replacedSelectionStart + clipboardText.length) return
        val inputConnection = currentInputConnection ?: return
        val textBeforeCursor = inputConnection.getTextBeforeCursor(clipboardText.length, 0)?.toString() ?: return
        if (textBeforeCursor != clipboardText) return
        if (!inputConnection.setComposingRegion(replacedSelectionStart, newSelStart)) return
        draftState.append(clipboardText)
        updateHostComposingText()
        refreshTranslationForCurrentDraft()
        renderKeyboard()
    }

    private fun currentClipboardText(): String? {
        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clipData = clipboardManager.primaryClip ?: return null
        if (clipData.itemCount == 0) return null
        val clipboardText = clipData.getItemAt(0).coerceToText(this).toString()
        return clipboardText.takeIf { it.isNotEmpty() }
    }

    private fun updateHostComposingText() {
        val inputConnection = currentInputConnection ?: return
        val composingText = draftState.textValue + rimeSnapshot.preeditText
        if (composingText.isEmpty()) {
            inputConnection.setComposingText("", 1)
            inputConnection.finishComposingText()
        } else {
            inputConnection.setComposingText(composingText, 1)
        }
    }

    // 当前草稿资格变化时立即隐藏旧译文，再按安全输入、长度和 1 秒防抖重新调度。
    private fun refreshTranslationForCurrentDraft() {
        translationCoordinator.invalidate()
        translatedTextValue = null
        val sourceText = draftState.normalizedSourceText()
        translationStatus = when {
            rimeSnapshot.isComposing -> TranslationStatus.Hidden
            draftState.textValue.isEmpty() -> TranslationStatus.Hidden
            !settingsStore.translationEnabled -> TranslationStatus.Disabled
            secureEditorValue -> TranslationStatus.SecureInput
            draftState.exceedsCharacterLimit -> TranslationStatus.TooLong
            sourceText == null -> TranslationStatus.Hidden
            else -> {
                translationCoordinator.schedule(sourceText, settingsStore.targetLanguage)
                TranslationStatus.Waiting
            }
        }
    }

    private fun commitOriginalDraft() {
        val inputConnection = currentInputConnection
        if (rimeSnapshot.isComposing && rimeSessionIdentifier != 0L) {
            val committedSnapshot = RimeNative.commitComposition(rimeSessionIdentifier)
            rimeSnapshot = committedSnapshot
            if (committedSnapshot.commitText.isNotEmpty()) {
                draftState.append(committedSnapshot.commitText)
            }
        }
        if (draftState.textValue.isNotEmpty()) {
            inputConnection?.commitText(draftState.textValue, 1)
        } else {
            inputConnection?.finishComposingText()
        }
        clearCurrentTransaction()
    }

    private fun clearCompositionAndTranslation() {
        resetHandwritingRecognition(true)
        if (rimeSessionIdentifier != 0L) {
            RimeNative.clearComposition(rimeSessionIdentifier)
            rimeSnapshot = RimeNative.currentSnapshot(rimeSessionIdentifier)
        }
        translationCoordinator.invalidate()
        translatedTextValue = null
        translationStatus = TranslationStatus.Hidden
        updateHostComposingText()
        renderKeyboard()
    }

    // 完成译文或原文提交后统一清空 composing text、librime 组合与网络代次。
    private fun clearCurrentTransaction() {
        translationCoordinator.invalidate()
        resetHandwritingRecognition(true)
        draftState.clear()
        translatedTextValue = null
        translationStatus = TranslationStatus.Hidden
        if (rimeSessionIdentifier != 0L) {
            RimeNative.clearComposition(rimeSessionIdentifier)
            rimeSnapshot = RimeNative.currentSnapshot(rimeSessionIdentifier)
        }
        updateHostComposingText()
        renderKeyboard()
    }

    private fun invalidateHandwritingRecognition() {
        handwritingGenerationValue += 1
        handwritingRecognitionRunnable?.let(mainHandler::removeCallbacks)
        handwritingRecognitionRunnable = null
    }

    // 输入会话、模式或已确认候选变化时统一取消旧推理，并按需清空仍未确认的画布笔迹。
    private fun resetHandwritingRecognition(clearCanvasValue: Boolean) {
        invalidateHandwritingRecognition()
        handwritingCandidateList = emptyList()
        handwritingStatus = HandwritingStatus.Idle
        if (clearCanvasValue) keyboardView?.clearHandwritingCanvas()
    }

    // 空草稿下优先执行宿主声明的发送、搜索、完成等动作，否则提交换行字符。
    private fun performEnterAction() {
        val inputConnection = currentInputConnection ?: return
        val handledActionValue = when (editorActionValue) {
            EditorInfo.IME_ACTION_DONE,
            EditorInfo.IME_ACTION_GO,
            EditorInfo.IME_ACTION_NEXT,
            EditorInfo.IME_ACTION_PREVIOUS,
            EditorInfo.IME_ACTION_SEARCH,
            EditorInfo.IME_ACTION_SEND -> inputConnection.performEditorAction(editorActionValue)
            else -> false
        }
        if (!handledActionValue) {
            sendKeyChar('\n')
        }
    }

    private fun renderKeyboard() {
        val targetLanguage = settingsStore.targetLanguage
        val handwritingModeValue = settingsStore.keyboardInputMode == KeyboardInputMode.HANDWRITING
        val handwritingActiveValue = handwritingModeValue &&
            (handwritingStatus != HandwritingStatus.Idle || draftState.textValue.isEmpty())
        val languagePairTitle = if (handwritingActiveValue) {
            "中文手写 · 本地识别"
        } else {
            "简体中文 → ${targetLanguage.displayName}"
        }
        val translationMessage = when (val statusValue = translationStatus) {
            TranslationStatus.Hidden -> ""
            TranslationStatus.Disabled -> "边写边译已关闭，可在设置中开启"
            TranslationStatus.SecureInput -> "安全输入已暂停远程翻译"
            TranslationStatus.TooLong -> "内容超过 ${ImeDraft.maxSourceCharacters} 字，请先上屏原文"
            TranslationStatus.ClipboardUnavailable -> "剪贴板中没有可翻译文本"
            TranslationStatus.Waiting -> "停止输入 1 秒后翻译整句"
            TranslationStatus.Loading -> "正在翻译…"
            TranslationStatus.Result -> ""
            is TranslationStatus.Failure -> statusValue.userMessage
        }
        val handwritingMessage = when (val statusValue = handwritingStatus) {
            HandwritingStatus.Idle -> "在下方书写，停顿后自动识别"
            HandwritingStatus.Waiting -> "继续书写会延后识别"
            HandwritingStatus.Loading -> "正在本地识别…"
            HandwritingStatus.Result -> ""
            is HandwritingStatus.Failure -> statusValue.userMessage
        }
        val engineMessage = engineErrorMessage ?: "正在准备拼音词库…"
        val visibleValue = !engineReadyValue || handwritingActiveValue || translationStatus != TranslationStatus.Hidden
        val displayedCandidateList = if (handwritingModeValue) {
            handwritingCandidateList
        } else {
            rimeSnapshot.candidateList.toList()
        }
        val displayedTranslatedText = if (handwritingActiveValue) null else translatedTextValue
        keyboardView?.render(KeyboardUiState(
            engineReady = engineReadyValue,
            languagePairTitle = languagePairTitle,
            translationVisible = visibleValue,
            translationMessage = if (!engineReadyValue) {
                engineMessage
            } else if (handwritingActiveValue) {
                handwritingMessage
            } else {
                translationMessage
            },
            translatedText = displayedTranslatedText,
            translationActionVisible = displayedTranslatedText != null,
            candidateList = displayedCandidateList,
            highlightedCandidateIndex = if (handwritingModeValue && displayedCandidateList.isNotEmpty()) {
                0
            } else {
                rimeSnapshot.highlightedIndex
            },
            pageNumber = if (handwritingModeValue) 0 else rimeSnapshot.pageNumber,
            isLastPage = if (handwritingModeValue) true else rimeSnapshot.isLastPage,
            isAsciiMode = rimeSnapshot.isAsciiMode,
            isNineKeyLayout = rimeSnapshot.schemaIdentifier == InputSchema.NINE_KEY_PINYIN.schemaIdentifier &&
                !rimeSnapshot.isAsciiMode,
            isWubiLayout = rimeSnapshot.schemaIdentifier == InputSchema.WUBI_86.schemaIdentifier &&
                !rimeSnapshot.isAsciiMode,
            isHandwritingMode = handwritingModeValue,
            canSwitchInputMethod = canSwitchInputMethod(),
            enterKeyLabel = enterKeyLabel(),
        ))
    }

    @Suppress("DEPRECATION")
    private fun canSwitchInputMethod(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return shouldOfferSwitchingToNextInputMethod()
        }
        val inputMethodWindowToken = window.window?.attributes?.token ?: return false
        val inputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        return inputMethodManager.shouldOfferSwitchingToNextInputMethod(inputMethodWindowToken)
    }

    private fun enterKeyLabel(): String {
        return when (editorActionValue) {
            EditorInfo.IME_ACTION_DONE -> "完成"
            EditorInfo.IME_ACTION_GO -> "前往"
            EditorInfo.IME_ACTION_NEXT -> "下一项"
            EditorInfo.IME_ACTION_PREVIOUS -> "上一项"
            EditorInfo.IME_ACTION_SEARCH -> "搜索"
            EditorInfo.IME_ACTION_SEND -> "发送"
            else -> "换行"
        }
    }

    private fun isSecureEditor(editorInfo: EditorInfo): Boolean {
        val inputClass = editorInfo.inputType and InputType.TYPE_MASK_CLASS
        val inputVariation = editorInfo.inputType and InputType.TYPE_MASK_VARIATION
        val passwordVariationValue = when (inputClass) {
            InputType.TYPE_CLASS_TEXT -> inputVariation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                inputVariation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                inputVariation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> inputVariation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
        val noLearningValue = editorInfo.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0
        return passwordVariationValue || noLearningValue
    }

    private sealed interface TranslationStatus {
        data object Hidden : TranslationStatus
        data object Disabled : TranslationStatus
        data object SecureInput : TranslationStatus
        data object TooLong : TranslationStatus
        data object ClipboardUnavailable : TranslationStatus
        data object Waiting : TranslationStatus
        data object Loading : TranslationStatus
        data object Result : TranslationStatus
        data class Failure(val userMessage: String) : TranslationStatus
    }

    private sealed interface HandwritingStatus {
        data object Idle : HandwritingStatus
        data object Waiting : HandwritingStatus
        data object Loading : HandwritingStatus
        data object Result : HandwritingStatus
        data class Failure(val userMessage: String) : HandwritingStatus
    }

    private companion object {
        const val logTag = "TypingDongnanyaIme"
        const val minimumHostPasteCharacters = 2
        const val handwritingRecognitionDelayMilliseconds = 420L
    }
}
