import Foundation
import Shared

/// AVFoundation sometimes requires an MP4 extension for extensionless recordings.
/// The caller owns the link until all reader work has finished, including errors.
struct TemporaryVideoLink: Sendable {
    let url: URL
    private let ownsLink: Bool

    init(source: URL, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(AppPaths.logSubsystem + ".video-read-links")) throws {
        guard source.pathExtension.lowercased() != "mp4" else {
            url = source
            ownsLink = false
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
        ownsLink = true
    }

    func cleanup() {
        if ownsLink { try? FileManager.default.removeItem(at: url) }
    }
}
