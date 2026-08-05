package com.caizhichao.typingdongnanya.handwriting

// 手写候选保留识别文本与模型分数，只在输入法进程内参与本轮候选排序。
data class HandwritingRecognitionCandidate(
    val textValue: String,
    val scoreValue: Float,
)
