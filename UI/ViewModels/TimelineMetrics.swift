import App
import Database
import Foundation

enum TimelineMetrics {
    static func recordPositionRecoveryHintAction(
        coordinator: AppCoordinator,
        action: String,
        source: String,
        seconds: Int? = nil
    ) {
        var payload: [String: Any] = [
            "action": action,
            "source": source
        ]
        if let seconds {
            payload["seconds"] = seconds
        }
        UIMetricsRecorder.record(
            coordinator: coordinator,
            type: .timelinePositionRecoveryHintAction,
            metadata: UIMetricsRecorder.jsonMetadata(payload)
        )
    }
}

private enum UIMetricsRecorder {
    static func record(
        coordinator: AppCoordinator,
        type: DailyMetricsQueries.MetricType,
        metadata: String? = nil
    ) {
        Task {
            try? await coordinator.recordMetricEvent(metricType: type, metadata: metadata)
        }
    }

    static func jsonMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
