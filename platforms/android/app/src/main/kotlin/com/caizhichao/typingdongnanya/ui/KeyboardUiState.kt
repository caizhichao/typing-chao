package com.caizhichao.typingdongnanya.ui

import com.caizhichao.typingdongnanya.rime.RimeCandidate

// 键盘只消费已经派生好的展示状态，不直接持有 librime 会话或网络任务。
data class KeyboardUiState(
    val engineReady: Boolean,
    val languagePairTitle: String,
    val translationVisible: Boolean,
    val translationMessage: String,
    val translatedText: String?,
    val translationActionVisible: Boolean,
    val candidateList: List<RimeCandidate>,
    val highlightedCandidateIndex: Int,
    val pageNumber: Int,
    val isLastPage: Boolean,
    val isAsciiMode: Boolean,
    val isNineKeyLayout: Boolean,
    val isWubiLayout: Boolean,
    val isHandwritingMode: Boolean,
    val canSwitchInputMethod: Boolean,
    val enterKeyLabel: String,
)
