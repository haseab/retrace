import Foundation
import Shared

/// Query parser implementation
/// Parses search queries with support for:
/// - Basic keywords: "error message"
/// - Exact phrases: "exact phrase"
/// - Exclusions: -excluded
/// - App filter: app:Chrome
/// - Date filters: after:2024-01-01 before:2024-12-31
public struct QueryParser: QueryParserProtocol {

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
        let tokens = tokenize(rawQuery)

        for token in tokens {
            if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count > 1 {
                // Exact phrase
                let phrase = String(token.dropFirst().dropLast())
                if !phrase.isEmpty {
                    phrases.append(phrase)
                }
            } else if token.hasPrefix("-") && token.count > 1 {
                // Excluded term
                excludedTerms.append(String(token.dropFirst()))
            } else if token.lowercased().hasPrefix("app:") {
                // App filter
                let appValue = String(token.dropFirst(4))
                if !appValue.isEmpty {
                    appFilter = appValue
                }
            } else if token.lowercased().hasPrefix("after:") {
                // Start date
                let dateStr = String(token.dropFirst(6))
                if let date = parseDate(dateStr) {
                    startDate = date
                }
            } else if token.lowercased().hasPrefix("before:") {
                // End date
                let dateStr = String(token.dropFirst(7))
                if let date = parseDate(dateStr) {
                    endDate = date
                }
            } else if !token.isEmpty {
                // Regular search term
                searchTerms.append(token)
            }
        }

        // Validate that we have at least some search criteria
        if searchTerms.isEmpty && phrases.isEmpty && excludedTerms.isEmpty {
            throw SearchError.invalidQuery(reason: "No search terms provided")
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

        // Check date range makes sense
        if let start = query.filters.startDate, let end = query.filters.endDate {
            if start > end {
                errors.append(QueryValidationError(message: "Start date must be before end date"))
            }
        }

        return errors
    }

    // MARK: - Private Helpers

    /// Tokenize query string while preserving quoted phrases
    private func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in query {
            if char == "\"" {
                if inQuotes {
                    // Ending quote
                    current.append(char)
                    tokens.append(current)
                    current = ""
                    inQuotes = false
                } else {
                    // Starting quote
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                    current.append(char)
                    inQuotes = true
                }
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        // Add any remaining content
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
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
            // Escape special FTS characters
            let escaped = escapeFTSSpecialChars(term)
            parts.append("\(escaped)*")
        }

        // Exact phrases
        for phrase in phrases {
            let escaped = escapeFTSSpecialChars(phrase)
            parts.append("\"\(escaped)\"")
        }

        // Excluded terms
        for term in excludedTerms {
            let escaped = escapeFTSSpecialChars(term)
            parts.append("NOT \(escaped)")
        }

        return parts.joined(separator: " ")
    }

    /// Escape FTS5 special characters
    private func escapeFTSSpecialChars(_ text: String) -> String {
        // FTS5 special chars: " * ( ) { } [ ] ^ : -
        var escaped = text
        let specialChars = ["\""]
        for char in specialChars {
            escaped = escaped.replacingOccurrences(of: char, with: "")
        }
        return escaped
    }
}
