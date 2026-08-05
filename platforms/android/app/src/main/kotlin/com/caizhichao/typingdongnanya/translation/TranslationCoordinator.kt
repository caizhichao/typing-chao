package com.caizhichao.typingdongnanya.translation

import android.os.Handler
import android.os.Looper
import com.caizhichao.typingdongnanya.settings.TargetLanguage
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// 防抖、取消和请求代次在单一协调器收口，迟到译文不能覆盖用户后续文本。
class TranslationCoordinator(
    private val listener: Listener,
    private val translationClient: TranslationClient = TranslationClient(),
) {
    interface Listener {
        fun onTranslationLoading(sourceText: String)
        fun onTranslationResult(sourceText: String, translatedText: String)
        fun onTranslationFailure(sourceText: String, userMessage: String)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val requestExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var pendingRunnable: Runnable? = null
    private var activeCall: TranslationClient.TranslationCall? = null
    private var requestGeneration = 0L

    // 每次草稿变化都从最后一次活动重新等待 1 秒，旧任务会立即失效并断开网络。
    fun schedule(sourceText: String, targetLanguage: TargetLanguage) {
        invalidate()
        val scheduledGeneration = requestGeneration
        val scheduledRunnable = Runnable {
            if (scheduledGeneration != requestGeneration) return@Runnable
            listener.onTranslationLoading(sourceText)
            val translationCall = translationClient.newCall(sourceText, targetLanguage)
            activeCall = translationCall
            requestExecutor.execute {
                val translationResult = translationCall.execute()
                mainHandler.post {
                    if (scheduledGeneration != requestGeneration || activeCall !== translationCall) {
                        return@post
                    }
                    activeCall = null
                    translationResult.onSuccess { translatedText ->
                        listener.onTranslationResult(sourceText, translatedText)
                    }.onFailure { errorValue ->
                        if (errorValue !is TranslationClient.TranslationException.Cancelled) {
                            listener.onTranslationFailure(sourceText, userMessage(errorValue))
                        }
                    }
                }
            }
        }
        pendingRunnable = scheduledRunnable
        mainHandler.postDelayed(scheduledRunnable, stableInputDelayMilliseconds)
    }

    fun invalidate() {
        requestGeneration += 1
        pendingRunnable?.let(mainHandler::removeCallbacks)
        pendingRunnable = null
        activeCall?.cancel()
        activeCall = null
    }

    fun close() {
        invalidate()
        requestExecutor.shutdownNow()
    }

    private fun userMessage(errorValue: Throwable): String {
        return when (errorValue) {
            TranslationClient.TranslationException.InvalidConfiguration -> "翻译服务地址无效，请重新安装后再试"
            TranslationClient.TranslationException.Timeout -> "翻译服务响应超时，请稍后继续输入"
            TranslationClient.TranslationException.EmptyResult -> "翻译服务没有返回有效译文"
            is TranslationClient.TranslationException.Server -> when (errorValue.statusCode) {
                429 -> "翻译请求过于频繁，请稍后继续输入"
                in 500..599 -> "翻译服务暂时不可用，请稍后重试"
                else -> "翻译服务暂不可用（HTTP ${errorValue.statusCode}）"
            }
            is TranslationClient.TranslationException.Network -> "暂时无法连接翻译服务，请检查网络后重试"
            else -> "翻译服务暂时不可用，请稍后重试"
        }
    }

    private companion object {
        const val stableInputDelayMilliseconds = 1_000L
    }
}
