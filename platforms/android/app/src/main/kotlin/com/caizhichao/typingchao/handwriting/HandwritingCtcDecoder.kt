package com.caizhichao.typingchao.handwriting

// CTC 解码器把模型时间步输出转换为首选文本，并生成少量单段替换候选。
class HandwritingCtcDecoder(
    private val characterList: List<String>,
) {
    fun decode(
        scoreList: FloatArray,
        timeStepCount: Int,
        classCount: Int,
        maximumCandidateCount: Int = 5,
    ): List<HandwritingRecognitionCandidate> {
        require(timeStepCount > 0)
        require(classCount == characterList.size + 1)
        require(scoreList.size == timeStepCount * classCount)

        val topClassList = IntArray(timeStepCount)
        for (timeStepIndex in 0 until timeStepCount) {
            var topClassIndex = 0
            var topScoreValue = Float.NEGATIVE_INFINITY
            val scoreOffset = timeStepIndex * classCount
            for (classIndex in 0 until classCount) {
                val scoreValue = scoreList[scoreOffset + classIndex]
                if (scoreValue > topScoreValue) {
                    topClassIndex = classIndex
                    topScoreValue = scoreValue
                }
            }
            topClassList[timeStepIndex] = topClassIndex
        }

        val segmentList = buildSegmentList(topClassList)
        if (segmentList.isEmpty()) return emptyList()
        val primaryClassList = segmentList.map { it.classIndex }
        val candidateScoreMap = linkedMapOf<String, Float>()
        val primaryText = decodeClassList(primaryClassList)
        if (primaryText.isNotEmpty()) {
            candidateScoreMap[primaryText] = segmentList.map { segmentValue ->
                averageClassScore(scoreList, classCount, segmentValue, segmentValue.classIndex)
            }.average().toFloat()
        }

        for (segmentIndex in segmentList.indices) {
            val segmentValue = segmentList[segmentIndex]
            for (alternativeValue in topAlternativeList(scoreList, classCount, segmentValue)) {
                val alternativeClassList = primaryClassList.toMutableList()
                alternativeClassList[segmentIndex] = alternativeValue.classIndex
                val alternativeText = decodeClassList(alternativeClassList)
                if (alternativeText.isEmpty() || candidateScoreMap.containsKey(alternativeText)) continue
                candidateScoreMap[alternativeText] = alternativeValue.scoreValue
                if (candidateScoreMap.size >= maximumCandidateCount) break
            }
            if (candidateScoreMap.size >= maximumCandidateCount) break
        }

        return candidateScoreMap.entries.map { candidateEntry ->
            HandwritingRecognitionCandidate(candidateEntry.key, candidateEntry.value)
        }
    }

    private fun buildSegmentList(topClassList: IntArray): List<CtcSegment> {
        val segmentList = mutableListOf<CtcSegment>()
        var currentClassIndex = blankClassIndex
        var currentStartIndex = -1
        for (timeStepIndex in topClassList.indices) {
            val classIndex = topClassList[timeStepIndex]
            if (classIndex == currentClassIndex) continue
            if (currentClassIndex != blankClassIndex) {
                segmentList.add(CtcSegment(currentStartIndex, timeStepIndex, currentClassIndex))
            }
            currentClassIndex = classIndex
            currentStartIndex = timeStepIndex
        }
        if (currentClassIndex != blankClassIndex) {
            segmentList.add(CtcSegment(currentStartIndex, topClassList.size, currentClassIndex))
        }
        return segmentList
    }

    private fun topAlternativeList(
        scoreList: FloatArray,
        classCount: Int,
        segmentValue: CtcSegment,
    ): List<ClassScore> {
        val topList = mutableListOf<ClassScore>()
        for (classIndex in 1 until classCount) {
            if (classIndex == segmentValue.classIndex) continue
            val scoreValue = averageClassScore(scoreList, classCount, segmentValue, classIndex)
            val insertionIndex = topList.indexOfFirst { it.scoreValue < scoreValue }
            if (insertionIndex < 0) {
                if (topList.size < alternativesPerSegment) topList.add(ClassScore(classIndex, scoreValue))
            } else {
                topList.add(insertionIndex, ClassScore(classIndex, scoreValue))
                if (topList.size > alternativesPerSegment) topList.removeAt(topList.lastIndex)
            }
        }
        return topList
    }

    private fun averageClassScore(
        scoreList: FloatArray,
        classCount: Int,
        segmentValue: CtcSegment,
        classIndex: Int,
    ): Float {
        var scoreSum = 0f
        for (timeStepIndex in segmentValue.startIndex until segmentValue.endIndex) {
            scoreSum += scoreList[timeStepIndex * classCount + classIndex]
        }
        return scoreSum / (segmentValue.endIndex - segmentValue.startIndex)
    }

    private fun decodeClassList(classList: List<Int>): String {
        return buildString {
            for (classIndex in classList) {
                val characterIndex = classIndex - 1
                if (characterIndex in characterList.indices) append(characterList[characterIndex])
            }
        }
    }

    // 同一非 blank 类别的连续时间步组成一个可替换识别片段。
    private data class CtcSegment(
        val startIndex: Int,
        val endIndex: Int,
        val classIndex: Int,
    )

    // 片段候选按该类别在片段内的平均模型分数排序。
    private data class ClassScore(
        val classIndex: Int,
        val scoreValue: Float,
    )

    private companion object {
        const val blankClassIndex = 0
        const val alternativesPerSegment = 3
    }
}
