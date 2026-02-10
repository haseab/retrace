import Foundation
import SwiftUI
import Shared

/// Handles deeplink URL routing for Retrace
/// Supports: retrace://search?q={query}&t={unix_ms}&app={bundle_id}
///           retrace://timeline?t={unix_ms}
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
        case let .search(query, timestamp, appBundleID):
            Log.info("[DeeplinkHandler] Navigating to search: query=\(query ?? "nil"), timestamp=\(String(describing: timestamp)), app=\(appBundleID ?? "nil")", category: .ui)
        case let .timeline(timestamp):
            Log.info("[DeeplinkHandler] Navigating to timeline: timestamp=\(String(describing: timestamp))", category: .ui)
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
            let query = queryParams["q"].flatMap { $0.trimmedOrNil }
            let timestamp = parseTimestamp(queryParams: queryParams)
            let appBundleID = queryParams["app"].flatMap { $0.trimmedOrNil }
            return .search(query: query, timestamp: timestamp, appBundleID: appBundleID)

        case "timeline":
            let timestamp = parseTimestamp(queryParams: queryParams)
            return .timeline(timestamp: timestamp)

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
    public static func generateSearchLink(query: String? = nil, timestamp: Date? = nil, appBundleID: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "retrace"
        components.host = "search"

        var queryItems: [URLQueryItem] = []

        if let query = query {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }

        if let timestamp = timestamp {
            let unixMs = Int64(timestamp.timeIntervalSince1970 * 1000)
            queryItems.append(URLQueryItem(name: "t", value: "\(unixMs)"))
        }

        if let appBundleID = appBundleID {
            queryItems.append(URLQueryItem(name: "app", value: appBundleID))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        return components.url
    }

    public static func generateTimelineLink(timestamp: Date) -> URL? {
        var components = URLComponents()
        components.scheme = "retrace"
        components.host = "timeline"

        let unixMs = Int64(timestamp.timeIntervalSince1970 * 1000)
        components.queryItems = [URLQueryItem(name: "t", value: "\(unixMs)")]

        return components.url
    }

    // MARK: - Reset

    public func clearActiveRoute() {
        activeRoute = nil
    }
}

// MARK: - Deeplink Route

public enum DeeplinkRoute: Equatable {
    case search(query: String?, timestamp: Date?, appBundleID: String?)
    case timeline(timestamp: Date?)

    public static func == (lhs: DeeplinkRoute, rhs: DeeplinkRoute) -> Bool {
        switch (lhs, rhs) {
        case let (.search(q1, t1, a1), .search(q2, t2, a2)):
            return q1 == q2 && t1 == t2 && a1 == a2
        case let (.timeline(t1), .timeline(t2)):
            return t1 == t2
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
