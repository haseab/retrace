import Foundation
import Shared

/// Segments transcription words into sentences for timeline playback
/// Owner: PROCESSING agent (Audio subdirectory)
public struct SentenceSegmenter {

    /// Represents a segmented sentence with timing information
    public struct Sentence {
        public let text: String
        public let startTime: Double      // Relative to chunk start (seconds)
        public let endTime: Double        // Relative to chunk start (seconds)
        public let words: [TranscriptionWord]
        public let confidence: Double

        public init(text: String, startTime: Double, endTime: Double, words: [TranscriptionWord], confidence: Double) {
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
            self.words = words
            self.confidence = confidence
        }
    }

    /// Segment words into sentences based on punctuation and pauses
    /// - Parameters:
    ///   - words: Array of transcription words with timestamps
    ///   - fullText: Complete transcription text (for validation and fallback)
    /// - Returns: Array of sentences with timing information
    public static func segment(words: [TranscriptionWord], fullText: String) -> [Sentence] {
        guard !words.isEmpty else { return [] }

        // Precompute sentence boundaries from fullText as backup
        let fullTextSentences = fullText.components(separatedBy: CharacterSet(charactersIn: ".?!;:"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var sentences: [Sentence] = []
        var currentWords: [TranscriptionWord] = []
        var currentText = ""

        for (index, word) in words.enumerated() {
            currentWords.append(word)
            currentText += (currentText.isEmpty ? "" : " ") + word.word

            // Check if this word ends a sentence (primary method)
            let endsWithPunctuation = hasSentenceTerminator(word.word)

            // Check if current text matches any sentence from fullText (fallback method)
            let matchesFullTextSentence = fullTextSentences.contains { sentence in
                currentText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(sentence)
            }

            // Check for long pause (>0.5s) to next word (indicates sentence boundary)
            let hasLongPause: Bool
            if index < words.count - 1 {
                let nextWord = words[index + 1]
                hasLongPause = (nextWord.start - word.end) > 0.5
            } else {
                hasLongPause = false
            }

            // Check if we've accumulated too many words (force break at ~20 words)
            let tooManyWords = currentWords.count >= 20

            // Check if this is the last word
            let isLastWord = index == words.count - 1

            // End sentence if any condition is met
            if endsWithPunctuation || hasLongPause || tooManyWords || isLastWord || matchesFullTextSentence {
                // Calculate average confidence for the sentence
                let avgConfidence: Double
                if currentWords.isEmpty {
                    avgConfidence = 0.0
                } else {
                    let sum = currentWords.reduce(0.0) { $0 + ($1.confidence ?? 0) }
                    avgConfidence = sum / Double(currentWords.count)
                }

                sentences.append(Sentence(
                    text: currentText.trimmingCharacters(in: .whitespaces),
                    startTime: currentWords.first!.start,
                    endTime: currentWords.last!.end,
                    words: currentWords,
                    confidence: avgConfidence
                ))

                currentWords = []
                currentText = ""
            }
        }

        // Handle any remaining words (shouldn't happen, but safety check)
        if !currentWords.isEmpty {
            let avgConfidence = currentWords.reduce(0.0) { $0 + ($1.confidence ?? 0) } / Double(currentWords.count)
            sentences.append(Sentence(
                text: currentText.trimmingCharacters(in: .whitespaces),
                startTime: currentWords.first!.start,
                endTime: currentWords.last!.end,
                words: currentWords,
                confidence: avgConfidence
            ))
        }

        return sentences
    }

    /// Check if a word ends with sentence-terminating punctuation
    private static func hasSentenceTerminator(_ word: String) -> Bool {
        return word.hasSuffix(".") ||
               word.hasSuffix("?") ||
               word.hasSuffix("!") ||
               word.hasSuffix(":") ||
               word.hasSuffix(";") ||
               word.hasSuffix(".\u{201D}") ||  // period + closing quote
               word.hasSuffix("?\u{201D}") ||  // question mark + closing quote
               word.hasSuffix("!\u{201D}")     // exclamation + closing quote
    }
}
