import Foundation
import Shared

/// Generates highlighted text snippets from search results
/// Extracts relevant context around matched terms and highlights them
public struct SnippetGenerator {

    /// Maximum snippet length in characters
    private let maxLength: Int

    /// Context characters to show before and after matches
    private let contextRadius: Int

    public init(
        maxLength: Int = 200,
        contextRadius: Int = 50
    ) {
        self.maxLength = maxLength
        self.contextRadius = contextRadius
    }

    // MARK: - Public API

    /// Generate snippet from FTS match (which may already have <mark> tags)
    public func generate(from ftsSnippet: String) -> String {
        // FTS already provides snippets with <mark> tags
        // We just need to truncate if too long
        if ftsSnippet.count <= maxLength {
            return ftsSnippet
        }

        // Find the first <mark> tag and center around it
        if let markRange = ftsSnippet.range(of: "<mark>") {
            let markPosition = ftsSnippet.distance(from: ftsSnippet.startIndex, to: markRange.lowerBound)
            let start = max(0, markPosition - contextRadius)
            let end = min(ftsSnippet.count, markPosition + maxLength - contextRadius)

            let startIndex = ftsSnippet.index(ftsSnippet.startIndex, offsetBy: start)
            let endIndex = ftsSnippet.index(ftsSnippet.startIndex, offsetBy: end)

            var snippet = String(ftsSnippet[startIndex..<endIndex])

            // Add ellipsis if truncated
            if start > 0 {
                snippet = "..." + snippet
            }
            if end < ftsSnippet.count {
                snippet = snippet + "..."
            }

            return snippet
        }

        // No marks found, just truncate
        let endIndex = ftsSnippet.index(ftsSnippet.startIndex, offsetBy: maxLength)
        return String(ftsSnippet[..<endIndex]) + "..."
    }

    /// Generate snippet from plain text and query terms
    public func generate(from text: String, queryTerms: [String]) -> String {
        guard !queryTerms.isEmpty else {
            return truncate(text)
        }

        // Find first occurrence of any query term
        var bestPosition: Int?
        var bestTerm: String?

        for term in queryTerms {
            if let range = text.lowercased().range(of: term.lowercased()) {
                let position = text.distance(from: text.startIndex, to: range.lowerBound)
                if bestPosition == nil || position < bestPosition! {
                    bestPosition = position
                    bestTerm = term
                }
            }
        }

        guard let matchPosition = bestPosition, let matchTerm = bestTerm else {
            // No matches found, return start of text
            return truncate(text)
        }

        // Extract context around match
        let start = max(0, matchPosition - contextRadius)
        let end = min(text.count, matchPosition + matchTerm.count + contextRadius)

        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: end)

        var snippet = String(text[startIndex..<endIndex])

        // Highlight all query terms in snippet
        snippet = highlightTerms(in: snippet, terms: queryTerms)

        // Add ellipsis
        if start > 0 {
            snippet = "..." + snippet
        }
        if end < text.count {
            snippet = snippet + "..."
        }

        return snippet
    }

    /// Extract matched text from snippet (text within <mark> tags)
    public func extractMatchedText(from snippet: String) -> String {
        let pattern = "<mark>(.*?)</mark>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: snippet, range: NSRange(snippet.startIndex..., in: snippet)),
              let range = Range(match.range(at: 1), in: snippet) else {
            // No marks found, return first few words
            let words = snippet.split(separator: " ").prefix(3)
            return words.joined(separator: " ")
        }
        return String(snippet[range])
    }

    // MARK: - Private Helpers

    /// Truncate text to max length
    private func truncate(_ text: String) -> String {
        if text.count <= maxLength {
            return text
        }

        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<endIndex]) + "..."
    }

    /// Highlight query terms in text with <mark> tags
    private func highlightTerms(in text: String, terms: [String]) -> String {
        var result = text

        for term in terms {
            // Case-insensitive replacement
            let pattern = "(?i)" + NSRegularExpression.escapedPattern(for: term)
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(result.startIndex..., in: result)
            let template = "<mark>$0</mark>"
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: template
            )
        }

        return result
    }
}
