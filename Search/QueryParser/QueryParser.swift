import Foundation
import Shared

/// Query parser implementation
/// Parses search queries with support for:
/// - Basic keywords: "error message"
/// - Exact phrases: "exact phrase"
/// - Exclusions: -excluded or -"exact phrase"
/// - App filter: app:Chrome
/// - Date filters: after:2024-01-01 before:2024-12-31
public struct QueryParser: QueryParserProtocol {
    private let tokenizer = QueryTokenizer()

    public init() {}

    // MARK: - QueryParserProtocol

    public func parse(rawQuery: String) throws -> ParsedQuery {
        guard !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SearchError.invalidQuery(reason: "Empty query")
        }

        var searchTerms: [String] = []
        var phrases: [String] = []
        var excludedTerms: [String] = []
        var appFilter: String? = nil
        var startDate: Date? = nil
        var endDate: Date? = nil

        // Tokenize preserving quotes
        let tokens = tokenizer.tokenize(rawQuery)

        for token in tokens {
            switch token.kind {
            case .ignoredShellOption:
                continue
            case .excludedTerm, .excludedPhrase:
                if !token.text.isEmpty {
                    excludedTerms.append(token.text)
                }
            case .phrase:
                let phrase = token.text
                if !phrase.isEmpty {
                    phrases.append(phrase)
                }
            case .term:
                let tokenText = token.text
                if tokenText.lowercased().hasPrefix("app:") {
                    // App filter
                    let appValue = String(tokenText.dropFirst(4))
                    if !appValue.isEmpty {
                        appFilter = appValue
                    }
                } else if tokenText.lowercased().hasPrefix("after:") {
                    // Start date
                    let dateStr = String(tokenText.dropFirst(6))
                    if let date = parseDate(dateStr) {
                        startDate = date
                    }
                } else if tokenText.lowercased().hasPrefix("before:") {
                    // End date
                    let dateStr = String(tokenText.dropFirst(7))
                    if let date = parseDate(dateStr) {
                        endDate = date
                    }
                } else if !tokenText.isEmpty {
                    // Regular search term
                    searchTerms.append(tokenText)
                }
            }
        }

        // Validate that we have at least some search criteria
        if searchTerms.isEmpty && phrases.isEmpty && excludedTerms.isEmpty {
            throw SearchError.invalidQuery(reason: "No search terms provided")
        }
        if searchTerms.isEmpty && phrases.isEmpty && !excludedTerms.isEmpty {
            throw SearchError.invalidQuery(reason: "Exclusions require at least one search term")
        }

        return ParsedQuery(
            searchTerms: searchTerms,
            phrases: phrases,
            excludedTerms: excludedTerms,
            appFilter: appFilter,
            dateRange: (start: startDate, end: endDate)
        )
    }

    public func validate(query: SearchQuery) -> [QueryValidationError] {
        var errors: [QueryValidationError] = []

        // Check query is not empty
        if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(QueryValidationError(message: "Query text cannot be empty"))
        }

        // Check limit is reasonable
        if query.limit <= 0 {
            errors.append(QueryValidationError(message: "Limit must be greater than 0"))
        }

        if query.limit > 1000 {
            errors.append(QueryValidationError(message: "Limit cannot exceed 1000"))
        }

        // Check offset is not negative
        if query.offset < 0 {
            errors.append(QueryValidationError(message: "Offset cannot be negative"))
        }

        // Check date range(s) make sense
        for range in query.filters.effectiveDateRanges {
            if let start = range.start, let end = range.end, start > end {
                errors.append(QueryValidationError(message: "Start date must be before end date"))
                break
            }
        }

        return errors
    }

    /// Parse date string in various formats
    private func parseDate(_ str: String) -> Date? {
        let formatters = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "MM/dd/yyyy",
            "dd/MM/yyyy"
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: str) {
                return date
            }
        }

        // Try relative dates
        let lowercased = str.lowercased()
        let calendar = Calendar.current
        let now = Date()

        switch lowercased {
        case "today":
            return calendar.startOfDay(for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "week", "lastweek", "last-week":
            return calendar.date(byAdding: .day, value: -7, to: now)
        case "month", "lastmonth", "last-month":
            return calendar.date(byAdding: .month, value: -1, to: now)
        case "year", "lastyear", "last-year":
            return calendar.date(byAdding: .year, value: -1, to: now)
        default:
            return nil
        }
    }
}

// MARK: - ParsedQuery Extension

extension ParsedQuery {
    /// Convert to FTS5 query syntax
    public func toFTSQuery() -> String {
        var parts: [String] = []

        // Regular terms with prefix matching
        for term in searchTerms {
            let escaped = QueryTokenizer.sanitizeFTSTerm(term)
            parts.append("\(escaped)*")
        }

        // Exact phrases
        for phrase in phrases {
            let escaped = QueryTokenizer.sanitizeFTSTerm(phrase)
            parts.append("\"\(escaped)\"")
        }

        // Excluded terms
        for term in excludedTerms {
            let escaped = QueryTokenizer.sanitizeFTSTerm(term)
            if term.contains(where: \.isWhitespace) {
                parts.append("NOT \"\(escaped)\"")
            } else {
                parts.append("NOT \(escaped)")
            }
        }

        return parts.joined(separator: " ")
    }
}
