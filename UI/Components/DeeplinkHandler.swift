import Foundation
import SwiftUI
import App
import Shared

/// Handles deeplink URL routing for Retrace
/// Supports encoded `state` payloads for search/timeline plus legacy:
/// - retrace://search?q={query}&t={unix_ms}&app={bundle_id}
/// - retrace://timeline?t={unix_ms}
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
        case let .search(state):
            Log.info("[DeeplinkHandler] Navigating to search: query=\(state.queryText ?? "nil"), timestamp=\(String(describing: state.timestamp)), apps=\(state.appBundleIDs.joined(separator: ","))", category: .ui)
        case let .timeline(state):
            Log.info("[DeeplinkHandler] Navigating to timeline: timestamp=\(String(describing: state.timestamp)), frameID=\(state.frameID.map(String.init) ?? "nil")", category: .ui)
        }
    }

    /// Parse a deeplink URL into a route, accepting both `t` and `timestamp`.
    public static func route(for url: URL) -> DeeplinkRoute? {
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

        default:
            Log.warning("[DeeplinkHandler] Unknown route: \(host)", category: .ui)
            return nil
        }
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

    // MARK: - Reset

    public func clearActiveRoute() {
        activeRoute = nil
    }
}

// MARK: - Deeplink Route

public enum DeeplinkRoute: Equatable {
    case search(state: CLIDeeplinkSearchState)
    case timeline(state: CLIDeeplinkTimelineState)

    public static func == (lhs: DeeplinkRoute, rhs: DeeplinkRoute) -> Bool {
        switch (lhs, rhs) {
        case let (.search(s1), .search(s2)):
            return s1 == s2
        case let (.timeline(s1), .timeline(s2)):
            return s1 == s2
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
