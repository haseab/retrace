import Foundation
import SwiftyChrono

extension TimelineDateSearchSupport {
    static func parsePlayheadRelativeDateIfNeeded(
        _ text: String,
        relativeTo baseTimestamp: Date
    ) -> Date? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedRelativeInput = normalizeRelativeDateShorthand(normalized)
        return parsePlayheadRelativeDate(normalizedRelativeInput, relativeTo: baseTimestamp)
    }

    static func parsePlayheadRelativeDate(
        _ normalizedText: String,
        relativeTo baseTimestamp: Date
    ) -> Date? {
        guard let offset = parsePlayheadRelativeOffset(normalizedText) else {
            return nil
        }

        let directionSign: Int
        switch offset.direction {
        case .forward:
            directionSign = 1
        case .backward:
            directionSign = -1
        }

        return dateByApplyingPlayheadRelativeOffset(
            amount: offset.amount,
            unit: offset.unit,
            directionSign: directionSign,
            to: baseTimestamp
        )
    }

    static func parsePlayheadDayReferenceIfNeeded(
        _ text: String,
        relativeTo baseTimestamp: Date
    ) -> Date? {
        guard hasPlayheadDayReference(text) else {
            return nil
        }

        let normalizedInput = normalizedPlayheadDayReferenceInput(text)
        let calendar = Calendar.current

        if normalizedInput == "today" ||
            normalizedInput.range(of: #"^start of (?:the )?today$"#, options: .regularExpression) != nil {
            return calendar.startOfDay(for: baseTimestamp)
        }

        let strippedTodayInput = normalizedInput
            .replacingOccurrences(of: #"\btoday\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:at|on)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if strippedTodayInput.isEmpty {
            return calendar.startOfDay(for: baseTimestamp)
        }

        if let timeOnlyDate = parseTimeOnly(strippedTodayInput, relativeTo: baseTimestamp) {
            return timeOnlyDate
        }

        if let parsedStrippedInput = parseNaturalLanguageDate(strippedTodayInput, now: baseTimestamp) {
            return parsedStrippedInput
        }

        return parseNaturalLanguageDate(normalizedInput, now: baseTimestamp)
    }

    static func parseNaturalLanguageDate(_ text: String, now: Date = Date()) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        let lowercasedInput = trimmed.lowercased()
        let collapsedInput = lowercasedInput.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let normalizedRelativeInput = normalizeRelativeDateShorthand(collapsedInput)
        let normalizedWithCompactTimes = normalizeCompactTimeFormat(normalizedRelativeInput)

        if normalizedRelativeInput.range(of: #"^start of (the )?day$"#, options: .regularExpression) != nil {
            return calendar.startOfDay(for: now)
        }

        func finalizeParsedDate(_ parsedDate: Date) -> Date {
            let anchorMode = inferDateSearchAnchorMode(for: normalizedWithCompactTimes)
            let dateForYearAdjustment = normalizedAnchorDate(parsedDate, mode: anchorMode, calendar: calendar)

            var normalized = adjustTimeOnlyFutureDateToRecentPastIfNeeded(
                dateForYearAdjustment,
                input: normalizedRelativeInput,
                now: now,
                calendar: calendar
            )
            normalized = adjustYearlessAbsoluteFutureDateToRecentPastIfNeeded(
                normalized,
                input: normalizedRelativeInput,
                now: now,
                calendar: calendar
            )
            return normalizedAnchorDate(normalized, mode: anchorMode, calendar: calendar)
        }

        if let timeOnlyDate = parseTimeOnly(normalizedRelativeInput, relativeTo: now) {
            return finalizeParsedDate(timeOnlyDate)
        }

        if let standaloneMonthDate = parseStandaloneMonthReference(
            normalizedRelativeInput,
            now: now,
            calendar: calendar
        ) {
            return finalizeParsedDate(standaloneMonthDate)
        }

        if let standaloneYearDate = parseStandaloneYearReference(
            normalizedRelativeInput,
            now: now,
            calendar: calendar
        ) {
            return finalizeParsedDate(standaloneYearDate)
        }

        let chrono = Chrono()
        let chronoInputs = normalizedWithCompactTimes == trimmed
            ? [trimmed]
            : [normalizedWithCompactTimes, trimmed]
        for chronoInput in chronoInputs {
            if let result = chrono.parse(text: chronoInput, refDate: now, opt: [:]).first?.start.date {
                return finalizeParsedDate(result)
            }
        }

        let trimmedLower = normalizedRelativeInput
        let normalizedText = normalizedWithCompactTimes

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let detector = detector {
            let range = NSRange(normalizedText.startIndex..., in: normalizedText)
            if let match = detector.firstMatch(in: normalizedText, options: [], range: range),
               let date = match.date {
                return finalizeParsedDate(date)
            }
        }

        let formatStrings = [
            "MMM d yyyy h:mm a",
            "MMM d yyyy h:mma",
            "MMM d yyyy ha",
            "MMM d h:mm a",
            "MMM d h:mma",
            "MMM d ha",
            "MMM d h a",
            "MM/dd/yyyy h:mm a",
            "MM/dd h:mm a",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "MMM yyyy",
            "MMMM yyyy",
            "MMM d",
            "MMMM d",
        ]

        for formatString in formatStrings {
            let formatter = DateFormatter()
            formatter.dateFormat = formatString
            formatter.timeZone = .current
            formatter.defaultDate = now

            if let date = formatter.date(from: text) {
                return finalizeParsedDate(date)
            }
            if let date = formatter.date(from: trimmedLower) {
                return finalizeParsedDate(date)
            }
            let capitalized = trimmedLower.prefix(1).uppercased() + trimmedLower.dropFirst()
            if let date = formatter.date(from: capitalized) {
                return finalizeParsedDate(date)
            }
        }

        return nil
    }

    static func normalizedPlayheadDayReferenceInput(_ text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.replacingOccurrences(
            of: #"\b(?:same|that|this)[-\s]+day\b"#,
            with: "today",
            options: .regularExpression
        )
    }

    private static func normalizeRelativeDateShorthand(_ text: String) -> String {
        var normalized = text
        let compactReplacements: [(String, String)] = [
            (#"\b(\d+)daf\b"#, "$1 days after"),
            (#"\b(\d+)haf\b"#, "$1 hours after"),
            (#"\b(\d+)maf\b"#, "$1 minutes after"),
            (#"\b(\d+)db\b"#, "$1 days before"),
            (#"\b(\d+)hb\b"#, "$1 hours before"),
            (#"\b(\d+)mb\b"#, "$1 minutes before"),
            (#"\b(\d+)de\b"#, "$1 days earlier"),
            (#"\b(\d+)he\b"#, "$1 hours earlier"),
            (#"\b(\d+)me\b"#, "$1 minutes earlier"),
            (#"\b(\d+)dl\b"#, "$1 days later"),
            (#"\b(\d+)hl\b"#, "$1 hours later"),
            (#"\b(\d+)ml\b"#, "$1 minutes later"),
            (#"\b(\d+)da\b"#, "$1 days ago"),
            (#"\b(\d+)ha\b"#, "$1 hours ago"),
            (#"\b(\d+)ma\b"#, "$1 minutes ago"),
        ]
        for (pattern, replacement) in compactReplacements {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        let replacements: [(String, String)] = [
            (#"\bmins?\.(?=\s|$)"#, "minutes"),
            (#"\bmins?\b"#, "minutes"),
            (#"\bhrs?\.(?=\s|$)"#, "hours"),
            (#"\bhrs?\b"#, "hours"),
            (#"\bhr\.(?=\s|$)"#, "hour"),
            (#"\bhr\b"#, "hour"),
            (#"\bsecs?\.(?=\s|$)"#, "seconds"),
            (#"\bsecs?\b"#, "seconds"),
            (#"\bwks?\.(?=\s|$)"#, "weeks"),
            (#"\bwks?\b"#, "weeks"),
            (#"\bmos\.(?=\s|$)"#, "months"),
            (#"\bmos\b"#, "months"),
            (#"\bmo\.(?=\s|$)"#, "month"),
            (#"\bmo\b"#, "month"),
            (#"\byrs?\.(?=\s|$)"#, "years"),
            (#"\byrs?\b"#, "years"),
            (#"\byr\.(?=\s|$)"#, "year"),
            (#"\byr\b"#, "year"),
            (#"\b(\d+)\s*d(?=\s*(?:ago|before|earlier|after|later|from now)\b)"#, "$1 days"),
        ]
        for (pattern, replacement) in replacements {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return normalized
    }

    private static func normalizeCompactTimeFormat(_ text: String) -> String {
        let pattern = #"\b(\d{3,4})(\s*(am|pm))?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let nsText = text as NSString
        var normalized = text
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length)
        )

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let digits = nsText.substring(with: match.range(at: 1))
            guard let value = Int(digits) else { continue }

            let meridiem: String?
            if match.range(at: 3).location != NSNotFound {
                meridiem = nsText.substring(with: match.range(at: 3)).lowercased()
            } else {
                meridiem = nil
            }

            let tokenRange = match.range(at: 0)
            let tokenIsWholeInput = tokenRange.location == 0 && tokenRange.length == nsText.length

            if digits.count == 4,
               meridiem == nil,
               (1900...2099).contains(value),
               !tokenIsWholeInput {
                continue
            }

            let hour = value / 100
            let minute = value % 100
            guard minute < 60 else { continue }
            if meridiem != nil && hour > 12 {
                continue
            }
            guard hour < 24 else { continue }

            let replacement: String
            let paddedMinute = String(format: "%02d", minute)
            if let meridiem {
                replacement = "\(hour):\(paddedMinute) \(meridiem)"
            } else {
                replacement = "\(hour):\(paddedMinute)"
            }

            normalized = (normalized as NSString).replacingCharacters(in: tokenRange, with: replacement)
        }

        return normalized
    }

    private static func parseTimeOnly(_ text: String, relativeTo baseTimestamp: Date) -> Date? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let calendar = Calendar.current

        if trimmed == "noon" {
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: baseTimestamp)
        }
        if trimmed == "midnight" {
            return calendar.date(bySettingHour: 0, minute: 0, second: 0, of: baseTimestamp)
        }

        let normalizedCompactTime = normalizeCompactTimeFormat(trimmed)
        let normalized = normalizedCompactTime.replacingOccurrences(
            of: #"\b(\d{1,2})(am|pm)\b"#,
            with: "$1 $2",
            options: .regularExpression
        )
        let hasExplicitMinutes = normalized.range(of: #":\d{2}\b"#, options: .regularExpression) != nil
        let formatStrings = [
            "h a",
            "h:mm a",
            "H:mm",
            "HH:mm",
            "H",
            "HH",
        ]
        for formatString in formatStrings {
            let formatter = DateFormatter()
            formatter.dateFormat = formatString
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.defaultDate = baseTimestamp

            if let date = formatter.date(from: normalized) {
                guard !hasExplicitMinutes else { return date }
                return calendar.date(
                    bySettingHour: calendar.component(.hour, from: date),
                    minute: 0,
                    second: 0,
                    of: date
                )
            }
        }

        return nil
    }

    private static func parseStandaloneMonthReference(
        _ normalizedText: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let pattern = #"^(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+(\d{4}))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        guard let match = regex.firstMatch(in: normalizedText, options: [], range: range) else {
            return nil
        }

        let monthToken = (normalizedText as NSString).substring(with: match.range(at: 1)).lowercased()
        let monthMap: [String: Int] = [
            "jan": 1, "january": 1,
            "feb": 2, "february": 2,
            "mar": 3, "march": 3,
            "apr": 4, "april": 4,
            "may": 5,
            "jun": 6, "june": 6,
            "jul": 7, "july": 7,
            "aug": 8, "august": 8,
            "sep": 9, "sept": 9, "september": 9,
            "oct": 10, "october": 10,
            "nov": 11, "november": 11,
            "dec": 12, "december": 12,
        ]
        guard let month = monthMap[monthToken] else { return nil }

        let year: Int
        if match.range(at: 2).location != NSNotFound,
           let parsedYear = Int((normalizedText as NSString).substring(with: match.range(at: 2))) {
            year = parsedYear
        } else {
            year = calendar.component(.year, from: now)
        }

        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: year,
            month: month,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0
        )
        return components.date
    }

    private static func parseStandaloneYearReference(
        _ normalizedText: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        if let year = Int(normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)),
           (1000...9999).contains(year) {
            return DateComponents(
                calendar: calendar,
                timeZone: .current,
                year: year,
                month: 1,
                day: 1,
                hour: 0,
                minute: 0,
                second: 0
            ).date
        }

        let lowercased = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseYear = calendar.component(.year, from: now)
        let resolvedYear: Int?
        switch lowercased {
        case "this year":
            resolvedYear = baseYear
        case "last year":
            resolvedYear = baseYear - 1
        case "next year":
            resolvedYear = baseYear + 1
        default:
            resolvedYear = nil
        }

        guard let year = resolvedYear else { return nil }
        return DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: year,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0
        ).date
    }

    private static func adjustYearlessAbsoluteFutureDateToRecentPastIfNeeded(
        _ parsedDate: Date,
        input: String,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let normalized = input.lowercased()
        if normalized.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil {
            return parsedDate
        }
        if normalized.range(
            of: #"\b(?:today|tomorrow|yesterday|next|last|ago|in)\b"#,
            options: .regularExpression
        ) != nil {
            return parsedDate
        }
        guard parsedDate > now else { return parsedDate }
        return calendar.date(byAdding: .year, value: -1, to: parsedDate) ?? parsedDate
    }

    private static func adjustTimeOnlyFutureDateToRecentPastIfNeeded(
        _ parsedDate: Date,
        input: String,
        now: Date,
        calendar: Calendar
    ) -> Date {
        let normalized = input.lowercased()
        let hasExplicitDateToken = normalized.range(
            of: #"\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b|\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{4}\b"#,
            options: .regularExpression
        ) != nil
        let hasRelativeDateToken = normalized.range(
            of: #"\b(?:today|tomorrow|yesterday|next|last|ago|in)\b"#,
            options: .regularExpression
        ) != nil
        let hasTimeToken = normalized.range(
            of: #"\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*(am|pm)\b|\b\d{3,4}\b|\bnoon\b|\bmidnight\b"#,
            options: .regularExpression
        ) != nil

        guard hasTimeToken, !hasExplicitDateToken, !hasRelativeDateToken else {
            return parsedDate
        }
        guard parsedDate > now else { return parsedDate }
        return calendar.date(byAdding: .day, value: -1, to: parsedDate) ?? parsedDate
    }

    private static func parsePlayheadRelativeOffset(_ text: String) -> PlayheadRelativeOffset? {
        let normalized = normalizeRelativeDateShorthand(
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        let pattern = #"\b(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs|h|day|days|d|week|weeks|wk|wks|w|month|months|mo|mos|year|years|yr|yrs|y)\s*(before|earlier|after|later)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range) else {
            return nil
        }

        let amountString = (normalized as NSString).substring(with: match.range(at: 1))
        let unitString = (normalized as NSString).substring(with: match.range(at: 2))
        let directionToken = (normalized as NSString).substring(with: match.range(at: 3))
        guard let amount = Int(amountString),
              let unit = PlayheadRelativeUnit(token: unitString) else {
            return nil
        }

        let direction: PlayheadRelativeDirection
        switch directionToken {
        case "before", "earlier":
            direction = .backward
        case "after", "later":
            direction = .forward
        default:
            return nil
        }

        return PlayheadRelativeOffset(amount: amount, unit: unit, direction: direction)
    }

    private static func parseAgoRelativeOffset(_ text: String) -> PlayheadRelativeOffset? {
        let normalized = normalizeRelativeDateShorthand(
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        let pattern = #"\b(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs|h|day|days|d|week|weeks|wk|wks|w|month|months|mo|mos|year|years|yr|yrs|y)\s+ago\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range) else {
            return nil
        }

        let amountString = (normalized as NSString).substring(with: match.range(at: 1))
        let unitString = (normalized as NSString).substring(with: match.range(at: 2))
        guard let amount = Int(amountString),
              let unit = PlayheadRelativeUnit(token: unitString) else {
            return nil
        }

        return PlayheadRelativeOffset(amount: amount, unit: unit, direction: .backward)
    }

    private static func dateByApplyingPlayheadRelativeOffset(
        amount: Int,
        unit: PlayheadRelativeUnit,
        directionSign: Int,
        to baseTimestamp: Date
    ) -> Date? {
        let calendar = Calendar.current
        let signedAmount = directionSign * amount
        let component: Calendar.Component
        switch unit {
        case .minute:
            component = .minute
        case .hour:
            component = .hour
        case .day:
            component = .day
        case .week:
            component = .day
        case .month:
            component = .month
        case .year:
            component = .year
        }

        if unit == .week {
            return calendar.date(byAdding: component, value: signedAmount * 7, to: baseTimestamp)
        }
        return calendar.date(byAdding: component, value: signedAmount, to: baseTimestamp)
    }

    static func hasPlayheadDayReference(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:same|that)[-\s]+day\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}

extension TimelineDateSearchSupport {
    static func relativeLookbackRangeIfNeeded(
        parsedDate: Date,
        input: String,
        now: Date = Date()
    ) -> RelativeLookbackRange? {
        if let range = playheadLookbackRangeIfNeeded(parsedDate: parsedDate, input: input) {
            return range
        }
        if let range = agoLookbackRangeIfNeeded(parsedDate: parsedDate, input: input, now: now) {
            return range
        }
        return nil
    }

    static func inferDateSearchAnchorMode(for input: String) -> DateSearchAnchorMode {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedRelativeInput = normalizeRelativeDateShorthand(normalized)
        let normalizedWithCompactTimes = normalizeCompactTimeFormat(normalizedRelativeInput)

        if isStandaloneMonthBucketInput(normalizedRelativeInput) {
            return .firstFrameInMonth
        }

        if isStandaloneYearBucketInput(normalizedRelativeInput) {
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
            of: #"\b(?:in\s+\d+\s*(?:day|days|d|week|weeks|wk|wks|w|month|months|mo|mos|year|years|yr|yrs|y)|\d+\s*(?:day|days|d|week|weeks|wk|wks|w|month|months|mo|mos|year|years|yr|yrs|y)\s*(?:ago|from now))\b"#,
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

    static func bucketRange(
        for date: Date,
        mode: DateSearchAnchorMode
    ) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let interval: DateInterval?

        switch mode {
        case .exact:
            return nil
        case .firstFrameInMinute:
            interval = calendar.dateInterval(of: .minute, for: date)
        case .firstFrameInHour:
            interval = calendar.dateInterval(of: .hour, for: date)
        case .firstFrameInDay:
            interval = calendar.dateInterval(of: .day, for: date)
        case .firstFrameInMonth:
            interval = calendar.dateInterval(of: .month, for: date)
        case .firstFrameInYear:
            interval = calendar.dateInterval(of: .year, for: date)
        }

        guard let interval else { return nil }
        let inclusiveEnd = interval.end.addingTimeInterval(-boundedLoadBoundaryEpsilonSeconds)
        guard inclusiveEnd >= interval.start else { return nil }
        return (start: interval.start, end: inclusiveEnd)
    }

    static func normalizedAnchorDate(
        _ date: Date,
        mode: DateSearchAnchorMode,
        calendar: Calendar
    ) -> Date {
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

    private static func playheadLookbackRangeIfNeeded(
        parsedDate: Date,
        input: String
    ) -> RelativeLookbackRange? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let offset = parsePlayheadRelativeOffset(normalized) else {
            return nil
        }

        switch offset.unit {
        case .hour, .day, .month:
            break
        case .minute, .week, .year:
            return nil
        }

        let inverseDirectionSign: Int
        switch offset.direction {
        case .backward:
            inverseDirectionSign = 1
        case .forward:
            inverseDirectionSign = -1
        }

        guard let baseTimestamp = dateByApplyingPlayheadRelativeOffset(
            amount: offset.amount,
            unit: offset.unit,
            directionSign: inverseDirectionSign,
            to: parsedDate
        ) else {
            return nil
        }

        let start = min(parsedDate, baseTimestamp)
        let end = max(parsedDate, baseTimestamp)

        switch offset.direction {
        case .backward:
            return RelativeLookbackRange(start: start, end: end, anchorEdge: .first)
        case .forward:
            return RelativeLookbackRange(start: start, end: end, anchorEdge: .last)
        }
    }

    private static func agoLookbackRangeIfNeeded(
        parsedDate: Date,
        input: String,
        now: Date
    ) -> RelativeLookbackRange? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let offset = parseAgoRelativeOffset(normalized) else {
            return nil
        }

        let lookbackEnd = now
        guard let lookbackStart = dateByApplyingPlayheadRelativeOffset(
            amount: offset.amount,
            unit: offset.unit,
            directionSign: -1,
            to: lookbackEnd
        ) else {
            return nil
        }

        if lookbackStart <= lookbackEnd {
            return RelativeLookbackRange(start: lookbackStart, end: lookbackEnd, anchorEdge: .first)
        }
        return RelativeLookbackRange(start: lookbackEnd, end: lookbackStart, anchorEdge: .first)
    }

    private static func isStandaloneMonthBucketInput(_ normalizedText: String) -> Bool {
        normalizedText.range(
            of: #"^(?:last|this|next)\s+month$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isStandaloneYearBucketInput(_ normalizedText: String) -> Bool {
        normalizedText.range(
            of: #"^(?:last|this|next)\s+year$"#,
            options: .regularExpression
        ) != nil
    }
}
