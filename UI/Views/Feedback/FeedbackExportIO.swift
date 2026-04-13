import Foundation
import AppKit
import Shared

extension FeedbackService {
    // MARK: - Screenshot

    /// Capture current screen (main display)
    public func captureScreenshot() -> Data? {
        guard let screen = NSScreen.main else { return nil }

        let rect = screen.frame
        guard let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) else { return nil }

        let nsImage = NSImage(cgImage: image, size: rect.size)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return pngData
    }

    // MARK: - Export

    /// Export diagnostics as a shareable text file
    public func exportDiagnostics() -> URL? {
        let diagnostics = collectDiagnostics()
        let content = diagnostics.formattedText()

        let fileName = "retrace-diagnostics-\(Log.timestamp()).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }

    public func exportFeedbackReport(
        _ submission: FeedbackSubmission,
        to reportURL: URL,
        launchSource: FeedbackLaunchContext.Source? = nil
    ) async throws -> [URL] {
        let screenshotBaseURL: URL
        if reportURL.pathExtension == "gz" {
            screenshotBaseURL = reportURL.deletingPathExtension().deletingPathExtension()
        } else {
            screenshotBaseURL = reportURL.deletingPathExtension()
        }

        let screenshotURL = submission.includeScreenshot
            ? screenshotBaseURL.appendingPathExtension("screenshot.png")
            : nil
        let screenshotFileName = screenshotURL?.lastPathComponent
        let exportDocument = submission.exportText(
            generatedAt: Date(),
            launchSource: launchSource,
            screenshotFileName: screenshotFileName
        )

        return try await Task.detached(priority: .userInitiated) {
            let exportData = try Self.gzipCompress(Data(exportDocument.utf8))

            try exportData.write(to: reportURL, options: .atomic)

            var exportedURLs = [reportURL]
            if let screenshotURL,
               let screenshotData = submission.screenshotData {
                try screenshotData.write(to: screenshotURL, options: .atomic)
                exportedURLs.append(screenshotURL)
            }

            return exportedURLs
        }.value
    }
}
