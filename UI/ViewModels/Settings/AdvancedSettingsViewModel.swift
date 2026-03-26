import SwiftUI

@MainActor
final class AdvancedSettingsViewModel: ObservableObject {
    nonisolated static func buildTypeText(isDevBuild: Bool) -> String {
        isDevBuild ? "Dev Build" : "Official Release"
    }

    nonisolated static func shouldShowForkRow(isDevBuild: Bool, forkName: String) -> Bool {
        isDevBuild && !forkName.isEmpty
    }
}
