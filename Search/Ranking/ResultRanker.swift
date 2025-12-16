import Foundation
import Shared

/// Ranks and sorts search results based on multiple signals
/// Combines FTS relevance with additional heuristics:
/// - Recency boost (newer results ranked higher)
/// - Metadata matching (query terms in window title/app name)
/// - Query term frequency
public struct ResultRanker {

    /// Recency boost weight (0-1)
    private let recencyWeight: Double

    /// Metadata boost weight (0-1)
    private let metadataWeight: Double

    public init(
        recencyWeight: Double = 0.2,
        metadataWeight: Double = 0.1
    ) {
        self.recencyWeight = recencyWeight
        self.metadataWeight = metadataWeight
    }

    // MARK: - Public API

    /// Rank and sort search results by relevance
    public func rank(_ results: [SearchResult], forQuery query: String) -> [SearchResult] {
        let queryTerms = extractQueryTerms(from: query)

        let scored = results.map { result in
            (result: result, score: computeScore(result, queryTerms: queryTerms))
        }

        return scored
            .sorted { $0.score > $1.score }
            .map(\.result)
    }

    /// Rank results with custom weights
    public func rank(
        _ results: [SearchResult],
        forQuery query: String,
        recencyWeight: Double,
        metadataWeight: Double
    ) -> [SearchResult] {
        let ranker = ResultRanker(
            recencyWeight: recencyWeight,
            metadataWeight: metadataWeight
        )
        return ranker.rank(results, forQuery: query)
    }

    // MARK: - Private Helpers

    /// Extract query terms for matching
    private func extractQueryTerms(from query: String) -> Set<String> {
        var terms: Set<String> = []

        // Simple tokenization
        let words = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        for word in words {
            // Skip filter keywords
            if word.hasPrefix("app:") || word.hasPrefix("after:") || word.hasPrefix("before:") {
                continue
            }
            // Skip exclusions
            if word.hasPrefix("-") {
                continue
            }
            // Remove quotes
            let cleaned = word.replacingOccurrences(of: "\"", with: "")
            if !cleaned.isEmpty {
                terms.insert(cleaned)
            }
        }

        return terms
    }

    /// Compute composite relevance score
    private func computeScore(_ result: SearchResult, queryTerms: Set<String>) -> Double {
        var score = result.relevanceScore

        // Add recency boost
        let recencyBoost = computeRecencyBoost(for: result.timestamp)
        score += recencyBoost * recencyWeight

        // Add metadata matching boost
        let metadataBoost = computeMetadataBoost(for: result, queryTerms: queryTerms)
        score += metadataBoost * metadataWeight

        return score
    }

    /// Compute recency boost (0-1, newer = higher)
    private func computeRecencyBoost(for timestamp: Date) -> Double {
        let ageInDays = Date().timeIntervalSince(timestamp) / 86400

        // Decay function: 1.0 for today, 0.0 after 30 days
        let boost = max(0, 1.0 - (ageInDays / 30.0))
        return boost
    }

    /// Compute metadata matching boost
    private func computeMetadataBoost(for result: SearchResult, queryTerms: Set<String>) -> Double {
        var boost: Double = 0

        // Check window title
        if let title = result.metadata.windowTitle {
            let titleLower = title.lowercased()
            let matchCount = queryTerms.filter { titleLower.contains($0) }.count
            boost += Double(matchCount) * 0.3
        }

        // Check app name
        if let appName = result.metadata.appName {
            let appLower = appName.lowercased()
            let matchCount = queryTerms.filter { appLower.contains($0) }.count
            boost += Double(matchCount) * 0.2
        }

        // Check browser URL
        if let url = result.metadata.browserURL {
            let urlLower = url.lowercased()
            let matchCount = queryTerms.filter { urlLower.contains($0) }.count
            boost += Double(matchCount) * 0.5  // URLs are very relevant
        }

        return min(boost, 1.0)  // Cap at 1.0
    }
}
