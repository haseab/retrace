import Foundation
import SwiftUI

// MARK: - Feedback View Model

@MainActor
public final class FeedbackViewModel: ObservableObject {

    // MARK: - Form State

    @Published public var feedbackType: FeedbackType = .bug
    @Published public var description: String = ""
    @Published public var includeScreenshot: Bool = false

    // MARK: - Diagnostic Info

    @Published public var diagnostics: DiagnosticInfo?
    @Published public var showDiagnosticsDetail: Bool = false

    // MARK: - Submission State

    @Published public var isSubmitting: Bool = false
    @Published public var isSubmitted: Bool = false
    @Published public var error: String?

    // MARK: - Services

    private let feedbackService = FeedbackService.shared

    // MARK: - Computed Properties

    public var canSubmit: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    public var diagnosticsSummary: String {
        guard let diagnostics = diagnostics else { return "Loading..." }
        return "v\(diagnostics.appVersion) • macOS \(diagnostics.macOSVersion) • \(diagnostics.deviceModel)"
    }

    // MARK: - Initialization

    public init() {
        loadDiagnostics()
    }

    // MARK: - Actions

    /// Load diagnostic information
    public func loadDiagnostics() {
        diagnostics = feedbackService.collectDiagnostics()
    }

    /// Submit the feedback
    public func submit() async {
        guard canSubmit, let diagnostics = diagnostics else { return }

        isSubmitting = true
        error = nil

        do {
            // Capture screenshot if requested
            let screenshotData: Data? = includeScreenshot ? feedbackService.captureScreenshot() : nil

            let submission = FeedbackSubmission(
                type: feedbackType,
                description: description,
                diagnostics: diagnostics,
                includeScreenshot: includeScreenshot,
                screenshotData: screenshotData
            )

            _ = try await feedbackService.submitFeedback(submission)
            isSubmitted = true
        } catch {
            self.error = error.localizedDescription
        }

        isSubmitting = false
    }

    /// Copy diagnostics to clipboard
    public func copyDiagnostics() {
        guard let diagnostics = diagnostics else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.formattedText(), forType: .string)
    }

    /// Export diagnostics to file
    public func exportDiagnostics() {
        guard let url = feedbackService.exportDiagnostics() else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    /// Reset form for new submission
    public func reset() {
        feedbackType = .bug
        description = ""
        includeScreenshot = false
        isSubmitted = false
        error = nil
        loadDiagnostics()
    }
}
