package com.caizhichao.typingchao.handwriting

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.ceil
import kotlin.math.max

// 离线手写识别器只加载包内 PaddleOCR 模型，并在独立串行线程执行 Bitmap 预处理和 ONNX 推理。
class HandwritingRecognizer(context: Context) : AutoCloseable {
    private val assetManager = context.applicationContext.assets
    private val environment = OrtEnvironment.getEnvironment()
    private val characterList by lazy {
        assetManager.open(characterAssetPath).bufferedReader().use { readerValue -> readerValue.readLines() }
    }
    private val decoder by lazy { HandwritingCtcDecoder(characterList) }
    private var sessionValue: OrtSession? = null

    // 每次识别使用完整画布快照，裁掉空白后按官方 3×48×320 口径归一化。
    @Synchronized
    fun recognize(bitmapValue: Bitmap): List<HandwritingRecognitionCandidate> {
        val inputValue = prepareInput(bitmapValue) ?: return emptyList()
        val session = currentSession()
        val inputName = session.inputNames.singleOrNull()
            ?: throw IllegalStateException("手写模型输入数量异常")
        OnnxTensor.createTensor(
            environment,
            inputValue,
            longArrayOf(1, channelCount.toLong(), inputHeight.toLong(), inputWidth.toLong()),
        ).use { inputTensor ->
            session.run(mapOf(inputName to inputTensor)).use { resultValue ->
                val outputTensor = resultValue.get(0) as? OnnxTensor
                    ?: throw IllegalStateException("手写模型输出类型异常")
                val outputShape = outputTensor.info.shape
                if (outputShape.size != 3 || outputShape[0] != 1L) {
                    throw IllegalStateException("手写模型输出形状异常：${outputShape.contentToString()}")
                }
                val timeStepCount = outputShape[1].toInt()
                val classCount = outputShape[2].toInt()
                val scoreList = FloatArray(timeStepCount * classCount)
                outputTensor.floatBuffer.get(scoreList)
                return decoder.decode(scoreList, timeStepCount, classCount)
            }
        }
    }

    private fun currentSession(): OrtSession {
        val existingSession = sessionValue
        if (existingSession != null) return existingSession
        val modelValue = assetManager.open(modelAssetPath).use { inputStreamValue -> inputStreamValue.readBytes() }
        return environment.createSession(modelValue).also { createdSession ->
            sessionValue = createdSession
        }
    }

    private fun prepareInput(bitmapValue: Bitmap): java.nio.FloatBuffer? {
        val inkBounds = findInkBounds(bitmapValue) ?: return null
        val paddedBounds = paddedBounds(bitmapValue, inkBounds)
        val croppedBitmap = Bitmap.createBitmap(
            bitmapValue,
            paddedBounds.left,
            paddedBounds.top,
            paddedBounds.width(),
            paddedBounds.height(),
        )
        val resizedWidth = ceil(inputHeight * croppedBitmap.width.toDouble() / croppedBitmap.height)
            .toInt()
            .coerceIn(1, inputWidth)
        val resizedBitmap = Bitmap.createScaledBitmap(croppedBitmap, resizedWidth, inputHeight, true)
        if (croppedBitmap !== bitmapValue && croppedBitmap !== resizedBitmap) croppedBitmap.recycle()

        val inputBuffer = ByteBuffer.allocateDirect(channelCount * inputHeight * inputWidth * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        val pixelList = IntArray(resizedWidth * inputHeight)
        resizedBitmap.getPixels(pixelList, 0, resizedWidth, 0, 0, resizedWidth, inputHeight)
        for (channelIndex in 0 until channelCount) {
            for (yIndex in 0 until inputHeight) {
                for (xIndex in 0 until inputWidth) {
                    val normalizedValue = if (xIndex < resizedWidth) {
                        normalizedChannelValue(pixelList[yIndex * resizedWidth + xIndex], channelIndex)
                    } else {
                        0f
                    }
                    inputBuffer.put(normalizedValue)
                }
            }
        }
        inputBuffer.rewind()
        if (resizedBitmap !== bitmapValue) resizedBitmap.recycle()
        return inputBuffer
    }

    private fun findInkBounds(bitmapValue: Bitmap): Rect? {
        val pixelList = IntArray(bitmapValue.width * bitmapValue.height)
        bitmapValue.getPixels(pixelList, 0, bitmapValue.width, 0, 0, bitmapValue.width, bitmapValue.height)
        var leftValue = bitmapValue.width
        var topValue = bitmapValue.height
        var rightValue = -1
        var bottomValue = -1
        for (yIndex in 0 until bitmapValue.height) {
            for (xIndex in 0 until bitmapValue.width) {
                val pixelValue = pixelList[yIndex * bitmapValue.width + xIndex]
                if (!isInkPixel(pixelValue)) continue
                leftValue = minOf(leftValue, xIndex)
                topValue = minOf(topValue, yIndex)
                rightValue = maxOf(rightValue, xIndex)
                bottomValue = maxOf(bottomValue, yIndex)
            }
        }
        if (rightValue < leftValue || bottomValue < topValue) return null
        return Rect(leftValue, topValue, rightValue + 1, bottomValue + 1)
    }

    private fun paddedBounds(bitmapValue: Bitmap, inkBounds: Rect): Rect {
        val paddingValue = max(minimumInkPaddingPixels, minOf(inkBounds.width(), inkBounds.height()) / 8)
        return Rect(
            (inkBounds.left - paddingValue).coerceAtLeast(0),
            (inkBounds.top - paddingValue).coerceAtLeast(0),
            (inkBounds.right + paddingValue).coerceAtMost(bitmapValue.width),
            (inkBounds.bottom + paddingValue).coerceAtMost(bitmapValue.height),
        )
    }

    private fun isInkPixel(pixelValue: Int): Boolean {
        if (Color.alpha(pixelValue) == 0) return false
        val luminanceValue = (
            Color.red(pixelValue) * 299 +
                Color.green(pixelValue) * 587 +
                Color.blue(pixelValue) * 114
            ) / 1000
        return luminanceValue < inkLuminanceThreshold
    }

    private fun normalizedChannelValue(pixelValue: Int, channelIndex: Int): Float {
        val channelValue = when (channelIndex) {
            0 -> Color.blue(pixelValue)
            1 -> Color.green(pixelValue)
            else -> Color.red(pixelValue)
        }
        return channelValue / 127.5f - 1f
    }

    @Synchronized
    override fun close() {
        sessionValue?.close()
        sessionValue = null
    }

    private companion object {
        const val modelAssetPath = "handwriting/inference.onnx"
        const val characterAssetPath = "handwriting/characters.txt"
        const val channelCount = 3
        const val inputHeight = 48
        const val inputWidth = 320
        const val minimumInkPaddingPixels = 8
        const val inkLuminanceThreshold = 245
    }
}
