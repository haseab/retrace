import Foundation
import AppKit
import Shared

// MARK: - Feedback Service

/// Collects diagnostic information and submits feedback
public final class FeedbackService {

    public static let shared = FeedbackService()

    private init() {}

    // MARK: - Diagnostic Collection

    /// Collect current diagnostic information
    public func collectDiagnostics() -> DiagnosticInfo {
        DiagnosticInfo(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            deviceModel: deviceModel,
            totalDiskSpace: totalDiskSpace,
            freeDiskSpace: freeDiskSpace,
            databaseStats: collectDatabaseStats(),
            recentErrors: collectRecentErrors()
        )
    }

    // MARK: - App Info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    // MARK: - System Info

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    // MARK: - Disk Space

    private var totalDiskSpace: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = attrs[.systemSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var freeDiskSpace: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    // MARK: - Database Stats

    private func collectDatabaseStats() -> DiagnosticInfo.DatabaseStats {
        // Get database file size
        let dbPath = NSString(string: AppPaths.databasePath).expandingTildeInPath
        let dbSize: Double
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int64 {
            dbSize = Double(size) / (1024 * 1024) // MB
        } else {
            dbSize = 0
        }

        // For now, return placeholder counts
        // In production, query actual counts from DatabaseManager
        return DiagnosticInfo.DatabaseStats(
            sessionCount: 0,
            frameCount: 0,
            segmentCount: 0,
            databaseSizeMB: dbSize
        )
    }

    // MARK: - Error Collection

    private func collectRecentErrors() -> [String] {
        // Collect recent errors from system log
        // For now, return empty - can be enhanced to read from os_log
        return []
    }

    // MARK: - Submission

    /// Submit feedback to the backend
    /// - Parameter submission: The feedback to submit
    /// - Returns: True if successful
    public func submitFeedback(_ submission: FeedbackSubmission) async throws -> Bool {
        // TODO: Replace with actual endpoint
        let endpoint = URL(string: "https://api.retrace.io/feedback")!

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(submission)

        // For now, simulate success (dummy endpoint)
        // In production, uncomment below:
        // let (_, response) = try await URLSession.shared.data(for: request)
        // guard let httpResponse = response as? HTTPURLResponse,
        //       (200...299).contains(httpResponse.statusCode) else {
        //     throw FeedbackError.submissionFailed
        // }

        // Simulate network delay
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        return true
    }

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

        let fileName = "retrace-diagnostics-\(ISO8601DateFormatter().string(from: Date())).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }
}

// MARK: - Errors

public enum FeedbackError: LocalizedError {
    case submissionFailed
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .submissionFailed:
            return "Failed to submit feedback. Please try again."
        case .invalidData:
            return "Invalid feedback data."
        }
    }
}
