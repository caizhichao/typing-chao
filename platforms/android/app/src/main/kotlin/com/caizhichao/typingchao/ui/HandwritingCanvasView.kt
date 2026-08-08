package com.caizhichao.typingchao.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View

// 手写画布只保存当前未确认笔迹，识别快照不包含辅助网格和其它 UI 装饰。
@SuppressLint("ViewConstructor")
class HandwritingCanvasView(
    context: Context,
    private val strokeChangedAction: (Boolean) -> Unit,
) : View(context) {
    private val strokeList = mutableListOf<Path>()
    private var currentStrokeValue: Path? = null
    private var previousXValue = 0f
    private var previousYValue = 0f
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(31, 44, 51)
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        strokeWidth = dp(strokeWidthDp).toFloat()
    }
    private val gridPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(226, 232, 236)
        style = Paint.Style.STROKE
        strokeWidth = dp(1).toFloat()
    }

    val hasInk: Boolean
        get() = strokeList.isNotEmpty() || currentStrokeValue != null

    override fun onDraw(canvasValue: Canvas) {
        super.onDraw(canvasValue)
        canvasValue.drawColor(Color.WHITE)
        canvasValue.drawLine(width / 2f, dp(10).toFloat(), width / 2f, height - dp(10).toFloat(), gridPaint)
        canvasValue.drawLine(dp(10).toFloat(), height / 2f, width - dp(10).toFloat(), height / 2f, gridPaint)
        for (strokeValue in strokeList) canvasValue.drawPath(strokeValue, strokePaint)
        currentStrokeValue?.let { strokeValue -> canvasValue.drawPath(strokeValue, strokePaint) }
    }

    // 每次抬笔才通知主链，移动事件只重绘本地路径，避免高频触发模型推理。
    override fun onTouchEvent(motionEvent: MotionEvent): Boolean {
        when (motionEvent.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                previousXValue = motionEvent.x
                previousYValue = motionEvent.y
                currentStrokeValue = Path().apply { moveTo(previousXValue, previousYValue) }
                invalidate()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val middleXValue = (previousXValue + motionEvent.x) / 2f
                val middleYValue = (previousYValue + motionEvent.y) / 2f
                currentStrokeValue?.quadTo(previousXValue, previousYValue, middleXValue, middleYValue)
                previousXValue = motionEvent.x
                previousYValue = motionEvent.y
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP -> {
                currentStrokeValue?.lineTo(motionEvent.x, motionEvent.y)
                currentStrokeValue?.let(strokeList::add)
                currentStrokeValue = null
                parent?.requestDisallowInterceptTouchEvent(false)
                performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                performClick()
                invalidate()
                strokeChangedAction(hasInk)
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                currentStrokeValue = null
                parent?.requestDisallowInterceptTouchEvent(false)
                invalidate()
                strokeChangedAction(hasInk)
                return true
            }
        }
        return super.onTouchEvent(motionEvent)
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    fun undoLastStroke(): Boolean {
        if (strokeList.isEmpty()) return false
        strokeList.removeAt(strokeList.lastIndex)
        invalidate()
        strokeChangedAction(hasInk)
        return true
    }

    fun clearStrokes(notifyValue: Boolean = true) {
        if (!hasInk) return
        strokeList.clear()
        currentStrokeValue = null
        invalidate()
        if (notifyValue) strokeChangedAction(false)
    }

    // 模型输入使用独立白底 Bitmap，避免把 View 网格、圆角和外层背景误当成笔迹。
    fun createRecognitionBitmap(): Bitmap? {
        if (!hasInk || width <= 0 || height <= 0) return null
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmapValue ->
            val canvasValue = Canvas(bitmapValue)
            canvasValue.drawColor(Color.WHITE)
            for (strokeValue in strokeList) canvasValue.drawPath(strokeValue, strokePaint)
            currentStrokeValue?.let { strokeValue -> canvasValue.drawPath(strokeValue, strokePaint) }
        }
    }

    private fun dp(dpValue: Int): Int {
        return (dpValue * resources.displayMetrics.density).toInt()
    }

    private companion object {
        const val strokeWidthDp = 6
    }
}
