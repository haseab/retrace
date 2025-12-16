import Foundation
import Shared

// MARK: - TextMerger

/// Merges text from OCR and Accessibility API sources
/// Handles deduplication and text combination
public struct TextMerger {

    /// Similarity threshold for considering two texts as duplicates (Jaccard similarity)
    private let deduplicationThreshold: Double

    public init(deduplicationThreshold: Double = 0.85) {
        self.deduplicationThreshold = deduplicationThreshold
    }

    // MARK: - Merging

    /// Merge OCR text with Accessibility text
    /// Returns combined deduplicated text
    public func mergeText(
        ocrText: String,
        accessibilityText: String?
    ) -> String {
        guard let axText = accessibilityText, !axText.isEmpty else {
            return ocrText
        }

        // If OCR is empty, just return AX text
        if ocrText.isEmpty {
            return axText
        }

        // Check similarity - if very similar, just return AX (more accurate)
        if textSimilarity(ocrText, axText) >= deduplicationThreshold {
            return axText
        }

        // Otherwise combine both
        return "\(axText)\n\(ocrText)"
    }

    /// Build full text string from text regions
    public func buildFullText(from regions: [TextRegion]) -> String {
        regions.map(\.text).joined(separator: " ")
    }

    // MARK: - Similarity Metrics

    /// Calculate Jaccard similarity between two texts
    /// Returns value between 0.0 (completely different) and 1.0 (identical)
    private func textSimilarity(_ a: String, _ b: String) -> Double {
        // Normalize and split into word sets
        let wordsA = Set(a.lowercased().split(separator: " ").map(String.init))
        let wordsB = Set(b.lowercased().split(separator: " ").map(String.init))

        // Handle empty sets
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }
        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0.0 }

        // Jaccard similarity: |intersection| / |union|
        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }

    /// Merge two text strings, removing duplicate words from secondary text
    private func mergeTexts(primary: String, secondary: String) -> String {
        // Handle empty strings
        if primary.isEmpty { return secondary }
        if secondary.isEmpty { return primary }

        // Extract primary words
        let primaryWords = Set(primary.lowercased().split(separator: " ").map(String.init))

        // Filter secondary words that don't appear in primary
        let secondaryUniqueWords = secondary.split(separator: " ").filter { word in
            !primaryWords.contains(word.lowercased())
        }

        // Combine
        if secondaryUniqueWords.isEmpty {
            return primary
        }

        return primary + " " + secondaryUniqueWords.joined(separator: " ")
    }
}
