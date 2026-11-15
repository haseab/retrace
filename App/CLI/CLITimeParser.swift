import Foundation
import Shared

public struct CLITimeParser {
    private let calendar: Calendar
    private let naturalLanguageParser: NaturalLanguageDateParser
    private let isoFormatterWithFractionalSeconds: ISO8601DateFormatter
    private let isoFormatter: ISO8601DateFormatter

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.naturalLanguageParser = NaturalLanguageDateParser(calendar: calendar)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatterWithFractionalSeconds = fractional

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        self.isoFormatter = standard
    }

    public func parseRange(_ rawValue: String) throws -> DateRangeCriterion {
        guard let separatorRange = rawValue.range(of: "..") else {
            throw CLIError.invalidValue(
                option: "--range",
                value: rawValue,
                details: ["format": "<start>..<end>"]
            )
        }

        let rawStart = String(rawValue[..<separatorRange.lowerBound])
        let rawEnd = String(rawValue[separatorRange.upperBound...])
        let start = try parseBound(rawStart, role: .start)
        let end = try parseBound(rawEnd, role: .end)

        if let start, let end, start > end {
            throw CLIError.invalidValue(
                option: "--range",
                value: rawValue,
                details: ["reason": "start must be less than or equal to end"]
            )
        }

        return DateRangeCriterion(start: start, end: end)
    }

    public func parseInstant(_ rawValue: String, optionName: String = "--at") throws -> Date {
        try parseDate(rawValue, optionName: optionName).date
    }

    private func parseBound(_ rawValue: String, role: BoundRole) throws -> Date? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed = try parseDate(trimmed, optionName: "--range")
        switch parsed.resolution {
        case .exact:
            return parsed.date
        case .day:
            switch role {
            case .start:
                return calendar.startOfDay(for: parsed.date)
            case .end:
                return endOfDay(for: parsed.date)
            }
        case .month:
            switch role {
            case .start:
                return calendar.dateInterval(of: .month, for: parsed.date)?.start ?? parsed.date
            case .end:
                return endOfMonth(for: parsed.date)
            }
        case .year:
            switch role {
            case .start:
                return calendar.dateInterval(of: .year, for: parsed.date)?.start ?? parsed.date
            case .end:
                return endOfYear(for: parsed.date)
            }
        }
    }

    private func parseDate(_ rawValue: String, optionName: String) throws -> ParsedDate {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = isoFormatterWithFractionalSeconds.date(from: trimmed) ?? isoFormatter.date(from: trimmed) {
            return ParsedDate(date: parsed, resolution: .exact)
        }

        if let parsed = naturalLanguageParser.parse(trimmed) {
            return ParsedDate(date: parsed.date, resolution: parsed.resolution)
        }

        throw CLIError.invalidValue(
            option: optionName,
            value: rawValue,
            details: ["format": "Use a natural-language timestamp, ISO8601, yyyy-MM-dd, yyyy/MM/dd, or <start>..<end>"]
        )
    }

    private func endOfDay(for date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return startOfDay
        }
        return nextDay.addingTimeInterval(-0.001)
    }

    private func endOfMonth(for date: Date) -> Date {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date) else {
            return endOfDay(for: date)
        }
        return monthInterval.end.addingTimeInterval(-0.001)
    }

    private func endOfYear(for date: Date) -> Date {
        guard let yearInterval = calendar.dateInterval(of: .year, for: date) else {
            return endOfDay(for: date)
        }
        return yearInterval.end.addingTimeInterval(-0.001)
    }
}

private enum BoundRole {
    case start
    case end
}

private struct ParsedDate {
    let date: Date
    let resolution: NaturalLanguageDateResolution
}
