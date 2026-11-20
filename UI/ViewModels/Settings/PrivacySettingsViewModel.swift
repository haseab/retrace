import SwiftUI

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    nonisolated static func decodeExcludedApps(from rawValue: String) -> [ExcludedAppInfo] {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let apps = try? JSONDecoder().decode([ExcludedAppInfo].self, from: data) else {
            return []
        }

        return apps
    }

    nonisolated static func encodeExcludedApps(_ apps: [ExcludedAppInfo]) -> String {
        guard let data = try? JSONEncoder().encode(apps),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }

        return string
    }
}
