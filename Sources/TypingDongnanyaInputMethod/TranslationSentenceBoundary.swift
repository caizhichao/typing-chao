import Foundation

// 负责从光标前文本中识别当前完整句的 UTF-16 范围，避免 Emoji surrogate 被当成独立标量读取。
enum TranslationSentenceBoundary {
    static func currentSentenceRange(in documentText: String) -> NSRange? {
        let documentNSString = documentText as NSString
        var sentenceEnd = documentNSString.length
        while sentenceEnd > 0 {
            let characterRange = documentNSString.rangeOfComposedCharacterSequence(at: sentenceEnd - 1)
            let characterText = documentNSString.substring(with: characterRange)
            guard characterMatches(characterText, characterSet: .whitespacesAndNewlines) else {
                break
            }
            sentenceEnd = characterRange.location
        }
        guard sentenceEnd > 0 else { return nil }

        let boundaryCharacterSet = TranslationPolicy.sentenceBoundaryCharacters.union(.newlines)
        let finalCharacterRange = documentNSString.rangeOfComposedCharacterSequence(at: sentenceEnd - 1)
        let finalCharacterText = documentNSString.substring(with: finalCharacterRange)
        var boundarySearchEnd = sentenceEnd
        if characterMatches(finalCharacterText, characterSet: boundaryCharacterSet) {
            boundarySearchEnd = finalCharacterRange.location
        }

        var sentenceStart = 0
        if boundarySearchEnd > 0 {
            let boundaryRange = documentNSString.rangeOfCharacter(
                from: boundaryCharacterSet,
                options: .backwards,
                range: NSRange(location: 0, length: boundarySearchEnd)
            )
            if boundaryRange.location != NSNotFound {
                sentenceStart = NSMaxRange(boundaryRange)
            }
        }
        while sentenceStart < sentenceEnd {
            let characterRange = documentNSString.rangeOfComposedCharacterSequence(at: sentenceStart)
            let characterText = documentNSString.substring(with: characterRange)
            guard characterMatches(characterText, characterSet: .whitespacesAndNewlines) else {
                break
            }
            sentenceStart = NSMaxRange(characterRange)
        }
        guard sentenceStart < sentenceEnd else { return nil }
        return NSRange(location: sentenceStart, length: sentenceEnd - sentenceStart)
    }

    private static func characterMatches(_ characterText: String, characterSet: CharacterSet) -> Bool {
        characterText.unicodeScalars.allSatisfy(characterSet.contains)
    }
}
