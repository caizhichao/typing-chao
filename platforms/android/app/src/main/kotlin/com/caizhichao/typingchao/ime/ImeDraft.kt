package com.caizhichao.typingchao.ime

import android.icu.text.BreakIterator
import java.util.Locale

// 输入法内部草稿先拥有整段原文，宿主只显示 composing text，确认后才一次性提交。
class ImeDraft {
    var textValue: String = ""
        private set

    val exceedsCharacterLimit: Boolean
        get() = textValue.codePointCount(0, textValue.length) > maxSourceCharacters

    fun append(contentText: String) {
        if (contentText.isEmpty()) return
        textValue += contentText
    }

    fun removeLastCharacter(): Boolean {
        if (textValue.isEmpty()) return false
        val characterIterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        characterIterator.setText(textValue)
        val lastBoundary = characterIterator.last()
        val previousBoundary = characterIterator.preceding(lastBoundary)
        textValue = if (previousBoundary == BreakIterator.DONE) "" else textValue.substring(0, previousBoundary)
        return true
    }

    fun normalizedSourceText(): String? {
        if (exceedsCharacterLimit) return null
        val normalizedText = textValue.trim()
        if (normalizedText.isEmpty()) return null
        val hasTranslatableContent = normalizedText.any { characterValue ->
            characterValue.isLetterOrDigit()
        }
        return normalizedText.takeIf { hasTranslatableContent }
    }

    fun clear() {
        textValue = ""
    }

    companion object {
        const val maxSourceCharacters = 600
    }
}
