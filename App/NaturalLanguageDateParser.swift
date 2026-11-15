import Foundation
import SwiftyChrono

public enum NaturalLanguageDateResolution: String, Sendable, Equatable {
    case exact
    case day
    case month
    case year
}

public struct NaturalLanguageParsedDate: Sendable, Equatable {
    public let date: Date
    public let resolution: NaturalLanguageDateResolution

    public init(date: Date, resolution: NaturalLanguageDateResolution) {
        self.date = date
        self.resolution = resolution
    }
}

public struct NaturalLanguageDateParser: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func date(from text: String, now: Date = Date()) -> Date? {
        parse(text, now: now)?.date
    }

    public func parse(_ text: String, now: Date = Date()) -> NaturalLanguageParsedDate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedInput = trimmed.lowercased()
        let collapsedInput = lowercasedInput.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalizedRelativeInput = normalizeRelativeDateShorthand(collapsedInput)
        let normalizedWithCompactTimes = normalizeCompactTimeFormat(normalizedRelativeInput)

        if normalizedRelativeInput.range(of: #"^start of (the )?day$"#, options: .regularExpression) != nil {
            return NaturalLanguageParsedDate(
                date: calendar.startOfDay(for: now),
                resolution: .day
            )
        }

        func finalizeParsedDate(
            _ parsedDate: Date,
            resolution: NaturalLanguageDateResolution
        ) -> NaturalLanguageParsedDate {
            let anchorMode = inferDateSearchAnchorMode(for: normalizedWithCompactTimes)
            let dateForYearAdjustment = normalizedAnchorDate(parsedDate, mode: anchorMode)

            var normalized = adjustYearlessAbsoluteFutureDateToRecentPastIfNeeded(
                dateForYearAdjustment,
                input: normalizedRelativeInput,
                now: now
            )
            normalized = adjustTimeOnlyFutureDateToRecentPastIfNeeded(
                normalized,
                input: normalizedRelativeInput,
                now: now
            )
            let normalizedAnchor = normalizedAnchorDate(normalized, mode: anchorMode)
            return NaturalLanguageParsedDate(
                date: normalizedAnchor,
                resolution: resolvedResolution(
                    explicitResolution: resolution,
                    anchorMode: anchorMode
                )
            )
        }

        if let timeOnlyDate = parseTimeOnly(normalizedRelativeInput, relativeTo: now) {
            return finalizeParsedDate(timeOnlyDate, resolution: .exact)
        }

        if let dateWithLeadingTime = parseDateWithLeadingTimeComponent(
            normalizedWithCompactTimes,
            now: now
        ) {
            return finalizeParsedDate(dateWithLeadingTime, resolution: .exact)
        }

        if let standaloneMonthDate = parseStandaloneMonthReference(normalizedRelativeInput, now: now) {
            return finalizeParsedDate(standaloneMonthDate, resolution: .month)
        }

        if let standaloneYearDate = parseStandaloneYearReference(normalizedRelativeInput, now: now) {
            return finalizeParsedDate(standaloneYearDate, resolution: .year)
        }

        let chrono = Chrono()
        let chronoInputs = normalizedWithCompactTimes == trimmed
            ? [trimmed]
            : [normalizedWithCompactTimes, trimmed]
        for chronoInput in chronoInputs {
            if let result = chrono.parse(text: chronoInput, refDate: now, opt: [:]).first?.start.date {
                return finalizeParsedDate(result, resolution: .exact)
            }
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let detector {
            let range = NSRange(normalizedWithCompactTimes.startIndex..., in: normalizedWithCompactTimes)
            if let match = detector.firstMatch(in: normalizedWithCompactTimes, options: [], range: range),
               let date = match.date {
                return finalizeParsedDate(date, resolution: .exact)
            }
        }

        for format in Self.dateTimeFormats {
            if let parsedDate = parseDate(trimmed, with: format, defaultDate: now) ??
                parseDate(normalizedRelativeInput, with: format, defaultDate: now) {
                return finalizeParsedDate(parsedDate, resolution: .exact)
            }
        }

        for format in Self.monthYearFormats {
            if let parsedDate = parseDate(trimmed, with: format, defaultDate: now) ??
                parseDate(normalizedRelativeInput, with: format, defaultDate: now) {
                return finalizeParsedDate(parsedDate, resolution: .month)
            }
        }

        for format in Self.dateOnlyFormats {
            if let parsedDate = parseDate(trimmed, with: format, defaultDate: now) ??
                parseDate(normalizedRelativeInput, with: format, defaultDate: now) {
                return finalizeParsedDate(parsedDate, resolution: .day)
            }
        }

        for format in Self.monthDayFormats {
            if let parsedDate = parseDate(trimmed, with: format, defaultDate: now) ??
                parseDate(normalizedRelativeInput, with: format, defaultDate: now) {
                return finalizeParsedDate(parsedDate, resolution: .day)
            }
        }

        return nil
    }

    private enum DateSearchAnchorMode {
        case exact
        case firstFrameInMinute
        case firstFrameInHour
        case firstFrameInDay
        case firstFrameInMonth
        case firstFrameInYear
    }

    private func resolvedResolution(
        explicitResolution: NaturalLanguageDateResolution,
        anchorMode: DateSearchAnchorMode
    ) -> NaturalLanguageDateResolution {
        switch anchorMode {
        case .firstFrameInDay:
            return .day
        case .firstFrameInMonth:
            return .month
        case .firstFrameInYear:
            return .year
        case .exact, .firstFrameInMinute, .firstFrameInHour:
            return explicitResolution
        }
    }

    private func parseDate(_ text: String, with format: String, defaultDate: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        formatter.defaultDate = defaultDate

        if let date = formatter.date(from: text) {
            return date
        }

        let capitalized = text.prefix(1).uppercased() + text.dropFirst()
        return formatter.date(from: capitalized)
    }

    private func parseStandaloneMonthReference(_ normalizedText: String, now: Date) -> Date? {
        guard let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start else {
            return nil
        }

        switch normalizedText {
        case "last month":
            return calendar.date(byAdding: .month, value: -1, to: currentMonthStart)
        case "this month":
            return currentMonthStart
        case "next month":
            return calendar.date(byAdding: .month, value: 1, to: currentMonthStart)
        default:
            return nil
        }
    }

    private func parseStandaloneYearReference(_ normalizedText: String, now: Date) -> Date? {
        if let explicitYear = parseExplicitStandaloneYear(normalizedText) {
            return explicitYear
        }

        guard let currentYearStart = calendar.dateInterval(of: .year, for: now)?.start else {
            return nil
        }

        switch normalizedText {
        case "last year":
            return calendar.date(byAdding: .year, value: -1, to: currentYearStart)
        case "this year":
            return currentYearStart
        case "next year":
            return calendar.date(byAdding: .year, value: 1, to: currentYearStart)
        default:
            return nil
        }
    }

    private func parseExplicitStandaloneYear(_ normalizedText: String) -> Date? {
        guard normalizedText.range(of: #"^(?:19|20|21)\d{2}$"#, options: .regularExpression) != nil,
              let year = Int(normalizedText) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = .current
        components.year = year
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    private func isStandaloneMonthBucketInput(_ normalizedText: String) -> Bool {
        normalizedText.range(
            of: #"^(?:last|this|next)\s+month$"#,
            options: .regularExpression
        ) != nil
    }

    private func isStandaloneYearBucketInput(_ normalizedText: String) -> Bool {
        normalizedText.range(
            of: #"^(?:last|this|next)\s+year$"#,
            options: .regularExpression
        ) != nil
    }

    private func inferDateSearchAnchorMode(for input: String) -> DateSearchAnchorMode {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedRelativeInput = normalizeRelativeDateShorthand(normalized)
        let normalizedWithCompactTimes = normalizeCompactTimeFormat(normalizedRelativeInput)

        if isStandaloneMonthBucketInput(normalizedRelativeInput) {
            return .firstFrameInMonth
        }

        if isStandaloneYearBucketInput(normalizedRelativeInput) ||
            normalizedRelativeInput.range(of: #"^(?:19|20|21)\d{2}$"#, options: .regularExpression) != nil {
            return .firstFrameInYear
        }

        if normalizedRelativeInput.range(
            of: #"^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+\d{4})?$"#,
            options: .regularExpression
        ) != nil {
            return .firstFrameInMonth
        }

        if normalizedRelativeInput.range(
            of: #"\b\d+\s*(minute|minutes|min|mins)\s+ago\b"#,
            options: .regularExpression
        ) != nil {
            return .firstFrameInMinute
        }

        if normalizedRelativeInput.range(
            of: #"\b\d+\s*(hour|hours|hr|hrs|h)\s+ago\b"#,
            options: .regularExpression
        ) != nil {
            return .firstFrameInHour
        }

        let hasCalendarDateToken = normalizedRelativeInput.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b"#,
            options: .regularExpression
        ) != nil
        let hasDayLevelNaturalLanguageToken = normalizedRelativeInput.range(
            of: #"\b(?:today|tomorrow|yesterday|(?:next|last|this)\s+(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\b"#,
            options: .regularExpression
        ) != nil
        let hasDayLevelRelativeOffsetToken = normalizedRelativeInput.range(
            of: #"\b(?:in\s+\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)|\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)\s*(?:ago|from now))\b"#,
            options: .regularExpression
        ) != nil
        let hasDateLikeToken = hasCalendarDateToken
            || hasDayLevelNaturalLanguageToken
            || hasDayLevelRelativeOffsetToken
        let hasExplicitTime = normalizedWithCompactTimes.range(
            of: #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\b\d{3,4}\s*(am|pm)\b|\bnoon\b|\bmidnight\b"#,
            options: .regularExpression
        ) != nil

        if hasDateLikeToken && !hasExplicitTime {
            return .firstFrameInDay
        }

        return .exact
    }

    private func normalizedAnchorDate(_ date: Date, mode: DateSearchAnchorMode) -> Date {
        switch mode {
        case .firstFrameInDay:
            return calendar.startOfDay(for: date)
        case .firstFrameInMonth:
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        case .firstFrameInYear:
            return calendar.dateInterval(of: .year, for: date)?.start ?? date
        case .exact, .firstFrameInMinute, .firstFrameInHour:
            return date
        }
    }

    private func adjustYearlessAbsoluteFutureDateToRecentPastIfNeeded(
        _ parsedDate: Date,
        input: String,
        now: Date
    ) -> Date {
        guard parsedDate > now else { return parsedDate }
        guard shouldCoerceYearlessAbsoluteDateToPast(input) else { return parsedDate }
        guard let priorYearDate = calendar.date(byAdding: .year, value: -1, to: parsedDate) else {
            return parsedDate
        }
        guard priorYearDate <= now else { return parsedDate }

        let maxRecentWindow: TimeInterval = 366 * 24 * 60 * 60
        guard now.timeIntervalSince(priorYearDate) <= maxRecentWindow else { return parsedDate }

        return priorYearDate
    }

    private func adjustTimeOnlyFutureDateToRecentPastIfNeeded(
        _ parsedDate: Date,
        input: String,
        now: Date
    ) -> Date {
        guard parsedDate > now else { return parsedDate }
        guard shouldCoerceTimeOnlyDateToPast(input) else { return parsedDate }
        guard let priorDayDate = calendar.date(byAdding: .day, value: -1, to: parsedDate) else {
            return parsedDate
        }
        guard priorDayDate <= now else { return parsedDate }

        return priorDayDate
    }

    private func shouldCoerceYearlessAbsoluteDateToPast(_ input: String) -> Bool {
        let normalizedInput = normalizeRelativeDateShorthand(input)
        if normalizedInput.range(
            of: #"\b(today|tomorrow|yesterday|next|last|ago|this|now|tonight)\b|from now"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        let hasMonthDay = normalizedInput.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}\b"#,
            options: .regularExpression
        ) != nil

        guard hasMonthDay else { return false }

        if normalizedInput.range(
            of: #"\b\d{4}\b|\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b|\b\d{2,4}[/-]\d{1,2}[/-]\d{1,2}\b"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        return true
    }

    private func shouldCoerceTimeOnlyDateToPast(_ input: String) -> Bool {
        let normalizedInput = normalizeRelativeDateShorthand(input)
        if normalizedInput.range(
            of: #"\b(today|tomorrow|yesterday|next|last|ago|this|now|tonight|earlier|later|before|after)\b|from now|\bin\s+\d+"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        if normalizedInput.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b|\b\d{4}-\d{1,2}-\d{1,2}\b"#,
            options: .regularExpression
        ) != nil {
            return false
        }

        let normalized = normalizedInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\s*at\s+"#, with: "", options: .regularExpression)

        return normalized.range(
            of: #"^(?:\d{1,2}(?::\d{2})?\s*(?:am|pm|a|p)?|\d{3,4}\s*(?:am|pm|a|p)?|noon|midnight)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func normalizeRelativeDateShorthand(_ text: String) -> String {
        var normalized = text

        normalized = rewriteRelativeDateShorthand(
            in: normalized,
            pattern: #"(?<!\w)(\d+)\s*(minute|minutes|min|mins|m|hour|hours|hr|hrs|h|day|days|d|week|weeks|wk|wks|w|month|months|mo|mos|year|years|yr|yrs|y)\.?\s*(ago|before|later|earlier|after)\b"#
        ) { amountToken, unitToken, directionToken in
            guard
                let amount = Int(amountToken),
                amount > 0,
                let unit = canonicalRelativeDateUnit(token: unitToken, amount: amount)
            else {
                return nil
            }

            return "\(amount) \(unit) \(directionToken)"
        }

        normalized = rewriteRelativeDateShorthand(
            in: normalized,
            pattern: #"(?<!\w)(\d+)\s*(minute|minutes|min|mins|m|hour|hours|hr|hrs|h|day|days|d|week|weeks|wk|wks|w|month|months|mo|mos|year|years|yr|yrs|y)(af|a|b|e|l)\b"#
        ) { amountToken, unitToken, directionToken in
            guard
                let amount = Int(amountToken),
                amount > 0,
                let unit = canonicalRelativeDateUnit(token: unitToken, amount: amount),
                let direction = canonicalRelativeDateCompactDirection(token: directionToken)
            else {
                return nil
            }

            return "\(amount) \(unit) \(direction)"
        }

        return normalized
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rewriteRelativeDateShorthand(
        in text: String,
        pattern: String,
        transform: (_ amount: String, _ unit: String, _ direction: String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let searchRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: searchRange)
        guard !matches.isEmpty else {
            return text
        }

        var result = text
        for match in matches.reversed() {
            guard
                let fullRange = Range(match.range(at: 0), in: result),
                let amountRange = Range(match.range(at: 1), in: text),
                let unitRange = Range(match.range(at: 2), in: text),
                let directionRange = Range(match.range(at: 3), in: text)
            else {
                continue
            }

            let amountToken = String(text[amountRange]).lowercased()
            let unitToken = String(text[unitRange]).lowercased()
            let directionToken = String(text[directionRange]).lowercased()
            guard let replacement = transform(amountToken, unitToken, directionToken) else {
                continue
            }

            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }

    private func canonicalRelativeDateUnit(token: String, amount: Int) -> String? {
        let isPlural = amount != 1

        switch token {
        case "minute", "minutes", "min", "mins", "m":
            return isPlural ? "minutes" : "minute"
        case "hour", "hours", "hr", "hrs", "h":
            return isPlural ? "hours" : "hour"
        case "day", "days", "d":
            return isPlural ? "days" : "day"
        case "week", "weeks", "wk", "wks", "w":
            return isPlural ? "weeks" : "week"
        case "month", "months", "mo", "mos":
            return isPlural ? "months" : "month"
        case "year", "years", "yr", "yrs", "y":
            return isPlural ? "years" : "year"
        default:
            return nil
        }
    }

    private func canonicalRelativeDateCompactDirection(token: String) -> String? {
        switch token {
        case "af":
            return "after"
        case "a":
            return "ago"
        case "b":
            return "before"
        case "e":
            return "earlier"
        case "l":
            return "later"
        default:
            return nil
        }
    }

    private func parseTimeOnly(_ text: String, relativeTo now: Date) -> Date? {
        var input = text.trimmingCharacters(in: .whitespaces)
        var isPM = false
        var isAM = false
        if input.hasSuffix("pm") || input.hasSuffix("p") {
            isPM = true
            input = input.replacingOccurrences(of: "pm", with: "")
                .replacingOccurrences(of: "p", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else if input.hasSuffix("am") || input.hasSuffix("a") {
            isAM = true
            input = input.replacingOccurrences(of: "am", with: "")
                .replacingOccurrences(of: "a", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        var hour: Int?
        var minute = 0

        if input.contains(":") {
            let parts = input.split(separator: ":")
            if parts.count == 2,
               let parsedHour = Int(parts[0]),
               let parsedMinute = Int(parts[1]),
               parsedHour >= 0 && parsedHour <= 23 &&
               parsedMinute >= 0 && parsedMinute <= 59 {
                hour = parsedHour
                minute = parsedMinute
            }
        } else if input.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil,
                  let numericValue = Int(input) {
            switch input.count {
            case 1, 2:
                guard numericValue >= 0 && numericValue <= 23 else {
                    return nil
                }
                hour = numericValue
            case 3, 4:
                let parsedHour = numericValue / 100
                let parsedMinute = numericValue % 100
                guard parsedHour >= 0 && parsedHour <= 23 &&
                    parsedMinute >= 0 && parsedMinute <= 59 else {
                    return nil
                }
                hour = parsedHour
                minute = parsedMinute
            default:
                return nil
            }
        }

        guard var finalHour = hour else { return nil }
        if isPM && finalHour < 12 {
            finalHour += 12
        } else if isAM && finalHour == 12 {
            finalHour = 0
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = finalHour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func parseDateWithLeadingTimeComponent(_ text: String, now: Date) -> Date? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*((?:\d{1,2}:\d{2}(?:\s*(?:am|pm|a|p))?|\d{3,4}(?:\s*(?:am|pm|a|p))?|\d{1,2}\s*(?:am|pm|a|p)))\s+(.+?)\s*$"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let searchRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: searchRange),
              let timeRange = Range(match.range(at: 1), in: text),
              let dateRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let timeToken = String(text[timeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let dateToken = String(text[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedDateToken = dateToken.lowercased()
        let dateTokenHasRelativeContext = lowercasedDateToken.range(
            of: #"\b(?:today|tomorrow|yesterday|tonight|(?:next|last|this)\s+(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|week|month|year)|\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)\s*(?:ago|from now)|in\s+\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs))\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        if timeToken.range(of: #"^\d{4}$"#, options: .regularExpression) != nil,
           let numericTimeToken = Int(timeToken),
           (1900...2100).contains(numericTimeToken),
           !dateTokenHasRelativeContext {
            return nil
        }

        guard !dateToken.isEmpty,
              let timeDate = parseTimeOnly(timeToken, relativeTo: now),
              let dateOnly = date(from: dateToken, now: now)
        else {
            return nil
        }

        var dateComponents = calendar.dateComponents([.year, .month, .day], from: dateOnly)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: timeDate)
        dateComponents.hour = timeComponents.hour
        dateComponents.minute = timeComponents.minute
        dateComponents.second = 0
        return calendar.date(from: dateComponents)
    }

    private func normalizeCompactTimeFormat(_ text: String) -> String {
        let pattern = #"(\d{3,4})\s*(am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }

        var result = text
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: result),
                  let suffixRange = Range(match.range(at: 2), in: result) else {
                continue
            }

            let numberStr = String(result[numberRange])
            let suffix = String(result[suffixRange])
            guard let numericValue = Int(numberStr) else { continue }

            let hour: Int
            let minute: Int
            if numericValue >= 100 && numericValue <= 1259 {
                hour = numericValue / 100
                minute = numericValue % 100
            } else {
                continue
            }

            guard hour >= 1 && hour <= 12 && minute >= 0 && minute <= 59 else {
                continue
            }

            let normalizedTime = "\(hour):\(String(format: "%02d", minute))\(suffix)"
            let fullMatchRange = Range(match.range, in: result)!
            result.replaceSubrange(fullMatchRange, with: normalizedTime)
        }

        let lowercasedResult = result.lowercased()
        let hasRelativeDateContext = lowercasedResult.range(
            of: #"\b(?:today|tomorrow|yesterday|tonight|(?:next|last|this)\s+(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|week|month|year)|\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs)\s*(?:ago|from now)|in\s+\d+\s*(?:day|days|week|weeks|wk|wks|month|months|mo|mos|year|years|yr|yrs))\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let hasCalendarDateContext = lowercasedResult.range(
            of: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b|\b\d{4}-\d{1,2}-\d{1,2}\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        if hasRelativeDateContext || hasCalendarDateContext,
           let standaloneTimeRegex = try? NSRegularExpression(pattern: #"\b\d{3,4}\b"#) {
            let searchRange = NSRange(result.startIndex..., in: result)
            let matches = standaloneTimeRegex.matches(in: result, options: [], range: searchRange)

            for match in matches.reversed() {
                guard let tokenRange = Range(match.range, in: result) else {
                    continue
                }

                let token = String(result[tokenRange])
                guard let numericValue = Int(token) else {
                    continue
                }

                if tokenRange.lowerBound > result.startIndex {
                    let previousIndex = result.index(before: tokenRange.lowerBound)
                    let previousCharacter = result[previousIndex]
                    if previousCharacter == "/" || previousCharacter == "-" {
                        continue
                    }
                }
                if tokenRange.upperBound < result.endIndex {
                    let nextCharacter = result[tokenRange.upperBound]
                    if nextCharacter == "/" || nextCharacter == "-" {
                        continue
                    }
                }

                let hour = numericValue / 100
                let minute = numericValue % 100
                guard hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 else {
                    continue
                }

                if !hasRelativeDateContext, (1900...2100).contains(numericValue) {
                    continue
                }

                let hourString = token.count == 4 ? String(format: "%02d", hour) : "\(hour)"
                let normalizedTime = "\(hourString):\(String(format: "%02d", minute))"
                result.replaceSubrange(tokenRange, with: normalizedTime)
            }
        }

        return result
    }

    private static let dateOnlyFormats = [
        "yyyy-MM-dd",
        "yyyy/MM/dd"
    ]

    private static let dateTimeFormats = [
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy/MM/dd HH:mm",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm"
    ]

    private static let monthYearFormats = [
        "MMM yyyy",
        "MMMM yyyy"
    ]

    private static let monthDayFormats = [
        "MMM d",
        "MMMM d"
    ]
}
