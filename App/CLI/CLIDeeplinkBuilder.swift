import AppKit
import Foundation

public enum CLIDeeplinkBuilder {
    private static let payloadQueryItem = "state"
    private static let payloadVersion = 2

    private struct EncodedPayload<Payload: Codable>: Codable {
        let version: Int
        let payload: Payload
    }

    public static func timelineURL(timestamp: Date) -> URL? {
        timelineURL(state: CLIDeeplinkTimelineState(timestamp: timestamp))
    }

    public static func timelineURL(state: CLIDeeplinkTimelineState) -> URL? {
        guard let encodedState = encoded(state) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "retrace"
        components.host = "timeline"
        components.queryItems = [URLQueryItem(name: payloadQueryItem, value: encodedState)]
        return components.url
    }

    public static func searchURL(query: String?, timestamp: Date?, appBundleID: String?) -> URL? {
        let state = CLIDeeplinkSearchState(
            queryText: query,
            appBundleIDs: appBundleID.map { [$0] } ?? [],
            appFilterMode: .include,
            timestamp: timestamp
        )
        return searchURL(state: state)
    }

    public static func searchURL(state: CLIDeeplinkSearchState) -> URL? {
        guard let encodedState = encoded(state) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "retrace"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: payloadQueryItem, value: encodedState)]
        return components.url
    }

    public static func decodedTimelineState(from url: URL) -> CLIDeeplinkTimelineState? {
        decodePayload(from: url)
    }

    public static func decodedSearchState(from url: URL) -> CLIDeeplinkSearchState? {
        decodePayload(from: url)
    }

    @discardableResult
    public static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    private static func encoded<Payload: Codable>(_ payload: Payload) -> String? {
        let wrapped = EncodedPayload(version: payloadVersion, payload: payload)
        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)

        guard let data = try? encoder.encode(wrapped) else {
            return nil
        }

        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodePayload<Payload: Codable>(from url: URL) -> Payload? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedState = components.queryItems?.first(where: { $0.name == payloadQueryItem })?.value,
              let data = base64URLDecodedData(from: encodedState) else {
            return nil
        }

        let decoder = JSONDecoder()
        CLIDateCoding.configure(decoder)

        guard let wrapped = try? decoder.decode(EncodedPayload<Payload>.self, from: data),
              wrapped.version == payloadVersion else {
            return nil
        }

        return wrapped.payload
    }

    private static func base64URLDecodedData(from value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }
}
