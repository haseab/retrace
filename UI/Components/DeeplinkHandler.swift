import Foundation
import SwiftUI
import App
import Shared

/// Handles deeplink URL routing for Retrace
/// Supports encoded `state` payloads for search/timeline plus legacy:
/// - retrace://search?q={query}&t={unix_ms}&app={bundle_id}
/// - retrace://timeline?t={unix_ms}
/// - retrace://dashboard?start={unix_ms_or_ISO8601}&end={unix_ms_or_ISO8601}
///           (legacy timestamp key `timestamp` is also accepted)
@MainActor
public class DeeplinkHandler: ObservableObject {

    // MARK: - Published State

    @Published public var activeRoute: DeeplinkRoute?

    // MARK: - URL Handling

    public func handle(_ url: URL) {
        guard let route = Self.route(for: url) else { return }
        activeRoute = route

        switch route {
        case .search:
            Log.info("[DeeplinkHandler] Navigating to search", category: .ui)
        case let .timeline(state):
            Log.info("[DeeplinkHandler] Navigating to timeline: timestamp=\(String(describing: state.timestamp)), frameID=\(state.frameID.map(String.init) ?? "nil")", category: .ui)
        case let .dashboard(dateRange):
            Log.info("[DeeplinkHandler] Navigating to dashboard: range=\(String(describing: dateRange))", category: .ui)
        }
    }

    /// Parse a deeplink URL into a route, accepting both `t` and `timestamp`.
    public static func route(for url: URL, calendar: Calendar = .current) -> DeeplinkRoute? {
        guard url.scheme == "retrace" else {
            Log.warning("[DeeplinkHandler] Invalid scheme: \(url.scheme ?? "none")", category: .ui)
            return nil
        }

        guard let host = url.host else {
            Log.warning("[DeeplinkHandler] No host in URL: \(url)", category: .ui)
            return nil
        }

        let queryParams = url.queryParameters

        switch host.lowercased() {
        case "search":
            if let state = CLIDeeplinkBuilder.decodedSearchState(from: url) {
                return .search(state: state)
            }

            let query = queryParams["q"].flatMap { $0.trimmedOrNil }
            let timestamp = parseTimestamp(queryParams: queryParams)
            let appBundleID = queryParams["app"].flatMap { $0.trimmedOrNil }
            return .search(
                state: CLIDeeplinkSearchState(
                    queryText: query,
                    appBundleIDs: appBundleID.map { [$0] } ?? [],
                    appFilterMode: .include,
                    timestamp: timestamp
                )
            )

        case "timeline":
            if let state = CLIDeeplinkBuilder.decodedTimelineState(from: url) {
                return .timeline(state: state)
            }

            let timestamp = parseTimestamp(queryParams: queryParams)
            return .timeline(state: CLIDeeplinkTimelineState(timestamp: timestamp))

        case "dashboard":
            let boundItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter {
                $0.name == "start" || $0.name == "end"
            } ?? []
            guard !boundItems.isEmpty else {
                return .dashboard(dateRange: nil)
            }
            guard boundItems.count == 2,
                  let rawStart = queryParams["start"]?.trimmedOrNil,
                  let rawEnd = queryParams["end"]?.trimmedOrNil,
                  let start = parseDashboardDate(rawStart, isEnd: false, calendar: calendar),
                  let end = parseDashboardDate(rawEnd, isEnd: true, calendar: calendar),
                  start <= end else {
                Log.warning("[DeeplinkHandler] Dashboard requires valid start/end datetimes in ascending order", category: .ui)
                return nil
            }
            let daySpan = (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: start),
                to: calendar.startOfDay(for: end)
            ).day ?? 0) + 1
            guard daySpan <= DashboardViewModel.maxAppUsageRangeDays else {
                Log.warning("[DeeplinkHandler] Dashboard range exceeds 31 days", category: .ui)
                return nil
            }
            return .dashboard(dateRange: DateRangeCriterion(start: start, end: end))

        default:
            Log.warning("[DeeplinkHandler] Unknown route: \(host)", category: .ui)
            return nil
        }
    }

    private static func parseDashboardDate(_ text: String, isEnd: Bool, calendar: Calendar) -> Date? {
        if let milliseconds = Int64(text) {
            // Bound dates to years 1...9999 before calendar arithmetic or formatting.
            guard (-62_135_596_800_000...253_402_300_799_999).contains(milliseconds) else { return nil }
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }

        if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
            return isEnd ? DateRangeInputParser(calendar: calendar).endOfDay(date) : calendar.startOfDay(for: date)
        }

        // External apps must supply a timezone for exact datetimes.
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func parseTimestamp(queryParams: [String: String]) -> Date? {
        let canonicalTimestamp = queryParams["t"].flatMap { $0.trimmedOrNil }
        let legacyTimestamp = queryParams["timestamp"].flatMap { $0.trimmedOrNil }
        guard let rawTimestamp = canonicalTimestamp ?? legacyTimestamp else {
            return nil
        }

        guard let unixMs = Int64(rawTimestamp) else {
            Log.warning("[DeeplinkHandler] Invalid timestamp value: \(rawTimestamp)", category: .ui)
            return nil
        }

        return Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0)
    }

    // MARK: - URL Generation

    /// Generate a deeplink URL for sharing
    public static func generateSearchLink(
        query: String? = nil,
        timestamp: Date? = nil,
        appBundleID: String? = nil
    ) -> URL? {
        CLIDeeplinkBuilder.searchURL(query: query, timestamp: timestamp, appBundleID: appBundleID)
    }

    public static func generateSearchLink(state: CLIDeeplinkSearchState) -> URL? {
        CLIDeeplinkBuilder.searchURL(state: state)
    }

    public static func generateTimelineLink(timestamp: Date) -> URL? {
        CLIDeeplinkBuilder.timelineURL(timestamp: timestamp)
    }

    public static func generateTimelineLink(state: CLIDeeplinkTimelineState) -> URL? {
        CLIDeeplinkBuilder.timelineURL(state: state)
    }

    public static func generateDashboardLink(start: Date? = nil, end: Date? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "retrace"
        components.host = "dashboard"
        if start != nil || end != nil {
            guard let start, let end else { return nil }
            let bounds = [start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000]
            guard bounds.allSatisfy({ $0.isFinite && (-62_135_596_800_000...253_402_300_799_999).contains($0) }) else {
                return nil
            }
            components.queryItems = [
                URLQueryItem(name: "start", value: String(Int64(bounds[0].rounded()))),
                URLQueryItem(name: "end", value: String(Int64(bounds[1].rounded())))
            ]
        }
        guard let url = components.url, route(for: url) != nil else { return nil }
        return url
    }

    // MARK: - Reset

    public func clearActiveRoute() {
        activeRoute = nil
    }
}

// MARK: - Deeplink Route

public enum DeeplinkRoute: Equatable {
    case search(state: CLIDeeplinkSearchState)
    case timeline(state: CLIDeeplinkTimelineState)
    case dashboard(dateRange: DateRangeCriterion?)

    public static func == (lhs: DeeplinkRoute, rhs: DeeplinkRoute) -> Bool {
        switch (lhs, rhs) {
        case let (.search(s1), .search(s2)):
            return s1 == s2
        case let (.timeline(s1), .timeline(s2)):
            return s1 == s2
        case let (.dashboard(range1), .dashboard(range2)):
            return range1 == range2
        default:
            return false
        }
    }
}

// MARK: - URL Extensions

extension URL {
    var queryParameters: [String: String] {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return [:]
        }

        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value
        }
        return params
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
