import App
import Database
import Foundation

enum UIMetricsRecorder {
    static func record(
        coordinator: AppCoordinator,
        type: DailyMetricsQueries.MetricType,
        metadata: String? = nil
    ) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: type, metadata: metadata)
        }
    }

    static func recordString<T: CustomStringConvertible>(
        coordinator: AppCoordinator,
        type: DailyMetricsQueries.MetricType,
        value: T?
    ) {
        record(
            coordinator: coordinator,
            type: type,
            metadata: value.map(\.description)
        )
    }

    static func recordDictionary(
        coordinator: AppCoordinator,
        type: DailyMetricsQueries.MetricType,
        payload: [String: Any]
    ) {
        record(
            coordinator: coordinator,
            type: type,
            metadata: jsonMetadata(payload)
        )
    }

    static func recordEncodable<T: Encodable>(
        coordinator: AppCoordinator,
        type: DailyMetricsQueries.MetricType,
        payload: T
    ) {
        record(
            coordinator: coordinator,
            type: type,
            metadata: jsonMetadata(payload)
        )
    }

    static func jsonMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    static func jsonMetadata<T: Encodable>(_ payload: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
