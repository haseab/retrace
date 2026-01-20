import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Shared

// MARK: - Feedback View Model

@MainActor
public final class FeedbackViewModel: ObservableObject {

    // MARK: - Form State

    @Published public var feedbackType: FeedbackType = .bug
    @Published public var email: String = ""
    @Published public var description: String = ""
    @Published public var attachedImage: NSImage?
    @Published public var attachedImageData: Data?

    // MARK: - Diagnostic Info

    @Published public var diagnostics: DiagnosticInfo?
    @Published public var showDiagnosticsDetail: Bool = false

    // MARK: - Submission State

    @Published public var isSubmitting: Bool = false
    @Published public var isSubmitted: Bool = false
    @Published public var error: String?

    // MARK: - Services

    private let feedbackService = FeedbackService.shared
    private weak var coordinatorWrapper: AppCoordinatorWrapper?

    // MARK: - Computed Properties

    public var canSubmit: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSubmitting &&
        isEmailValid
    }

    /// Email is valid if empty or matches email format
    public var isEmailValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return isValidEmailFormat(trimmed)
    }

    /// Shows error state for email field (only after user has typed something invalid)
    public var showEmailError: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isValidEmailFormat(trimmed)
    }

    public var diagnosticsSummary: String {
        guard let diagnostics = diagnostics else { return "Loading..." }
        return "v\(diagnostics.appVersion) • macOS \(diagnostics.macOSVersion) • \(diagnostics.deviceModel)"
    }

    // MARK: - Email Validation

    private func isValidEmailFormat(_ email: String) -> Bool {
        // Basic email validation: something@something.something
        // Must have: local part, @, domain, ., TLD (at least 2 chars)
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Initialization

    public init() {
        // Don't load diagnostics on init - load lazily when needed
    }

    /// Set the coordinator wrapper (diagnostics loaded lazily)
    public func setCoordinator(_ wrapper: AppCoordinatorWrapper) {
        self.coordinatorWrapper = wrapper
    }

    /// Load diagnostics when user wants to see details or on submit
    public func loadDiagnosticsIfNeeded() {
        guard diagnostics == nil else { return }
        Task {
            await loadDiagnosticsWithRealStats()
        }
    }

    // MARK: - Actions

    /// Load diagnostic information with placeholder stats
    public func loadDiagnostics() {
        diagnostics = feedbackService.collectDiagnostics()
    }

    /// Load diagnostic information with real database stats from coordinator
    private func loadDiagnosticsWithRealStats() async {
        guard let wrapper = coordinatorWrapper else {
            diagnostics = feedbackService.collectDiagnostics()
            return
        }

        do {
            let dbStats = try await wrapper.coordinator.getDatabaseStatistics()
            let sessionCount = try await wrapper.coordinator.getAppSessionCount()

            let stats = DiagnosticInfo.DatabaseStats(
                sessionCount: sessionCount,
                frameCount: dbStats.frameCount,
                segmentCount: dbStats.segmentCount, // Video segments
                databaseSizeMB: Double(dbStats.databaseSizeBytes) / (1024 * 1024)
            )

            await MainActor.run {
                self.diagnostics = feedbackService.collectDiagnostics(with: stats)
            }
        } catch {
            Log.warning("[FeedbackViewModel] Failed to load real stats: \(error)", category: .ui)
            diagnostics = feedbackService.collectDiagnostics()
        }
    }

    /// Submit the feedback
    public func submit() async {
        guard canSubmit else { return }

        isSubmitting = true
        error = nil

        // Load diagnostics if not already loaded
        if diagnostics == nil {
            await loadDiagnosticsWithRealStats()
        }

        guard let diagnostics = diagnostics else {
            self.error = "Failed to collect diagnostics"
            isSubmitting = false
            return
        }

        do {
            let submission = FeedbackSubmission(
                type: feedbackType,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description,
                diagnostics: diagnostics,
                includeScreenshot: attachedImageData != nil,
                screenshotData: attachedImageData
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
        email = ""
        description = ""
        attachedImage = nil
        attachedImageData = nil
        isSubmitted = false
        error = nil
        Task {
            await loadDiagnosticsWithRealStats()
        }
    }

    // MARK: - Image Attachment

    /// Attach an image from a file URL
    public func attachImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            Log.warning("[FeedbackViewModel] Failed to load image from: \(url.path)", category: .ui)
            return
        }
        attachImage(image)
    }

    /// Attach an NSImage directly
    public func attachImage(_ image: NSImage) {
        attachedImage = image

        // Convert to PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Log.warning("[FeedbackViewModel] Failed to convert image to PNG", category: .ui)
            return
        }
        attachedImageData = pngData
        Log.debug("[FeedbackViewModel] Image attached: \(pngData.count) bytes", category: .ui)
    }

    /// Remove the attached image
    public func removeAttachedImage() {
        attachedImage = nil
        attachedImageData = nil
    }

    /// Open file picker to select an image
    public func selectImageFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .gif, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select an image to attach"
        panel.prompt = "Attach"

        if panel.runModal() == .OK, let url = panel.url {
            attachImage(from: url)
        }
    }
}
