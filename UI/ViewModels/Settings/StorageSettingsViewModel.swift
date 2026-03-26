import SwiftUI

@MainActor
final class StorageSettingsViewModel: ObservableObject {
    nonisolated static func normalizeRewindFolderPath(_ path: String) -> String {
        let normalized = NSString(string: path).expandingTildeInPath
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory), !isDirectory.boolValue {
            return (normalized as NSString).deletingLastPathComponent
        }

        let lastComponent = (normalized as NSString).lastPathComponent.lowercased()
        if lastComponent.hasSuffix(".sqlite3") || lastComponent.hasSuffix(".db") {
            return (normalized as NSString).deletingLastPathComponent
        }

        return normalized
    }
}
