import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Dispatch
import App
import Shared

// MARK: - Feedback View Model

struct FeedbackSubmissionFailureState: Equatable {
    let title: String
    let detail: String
    let symbolName: String
    let isNetworkRelated: Bool
}

struct FeedbackCompletionPresentation: Equatable {
    let title: String
    let detail: String
    let callToActionTitle: String?
    let linkTitle: String?
    let linkURL: URL?
    let linkSymbolName: String?
}

enum FeedbackCompletionState: Equatable {
    case submitted
    case exported

    private static let directChatURL = URL(string: "https://retrace.to/chat")!

    var presentation: FeedbackCompletionPresentation {
        switch self {
        case .submitted:
            return FeedbackCompletionPresentation(
                title: "Feedback Sent!",
                detail: "Thanks for helping improve Retrace.",
                callToActionTitle: "Need a faster response?",
                linkTitle: "Chat with me on retrace.to",
                linkURL: Self.directChatURL,
                linkSymbolName: "message.fill"
            )
        case .exported:
            return FeedbackCompletionPresentation(
                title: "Download Complete",
                detail: "Your report was saved. Use chat to choose whether to send it by email, Discord, or live chat.",
                callToActionTitle: "Next Steps:",
                linkTitle: "Choose a Channel to Send",
                linkURL: Self.directChatURL,
                linkSymbolName: "message.fill"
            )
        }
    }
}

enum FeedbackExportDestinationError: LocalizedError {
    case downloadsUnavailable

    var errorDescription: String? {
        switch self {
        case .downloadsUnavailable:
            return "Retrace couldn't find your Downloads folder."
        }
    }
}

@MainActor
public final class FeedbackViewModel: ObservableObject {

    // MARK: - Form State

    @Published public var feedbackType: FeedbackType = .bug
    @Published public var email: String = ""
    @Published public var description: String = ""
    @Published public var attachedImage: NSImage?
    @Published public var attachedImageData: Data?

    // MARK: - Diagnostic Info

    @Published public var diagnostics: DiagnosticInfo? {
        didSet {
            diagnosticSections = diagnostics?.sectionSummaries(includeVerboseSections: true) ?? []
        }
    }
    @Published private(set) var diagnosticSections: [DiagnosticInfo.SectionSummary] = []
    @Published private(set) var includedDiagnosticSections: Set<DiagnosticInfo.SectionID> = Set(DiagnosticInfo.SectionID.allCases)
    @Published public var showDiagnosticsDetail: Bool = false

    // MARK: - Submission State

    @Published public var isSubmitting: Bool = false
    @Published public var isExporting: Bool = false
    @Published public var isSubmitted: Bool = false
    @Published public var error: String?
    @Published private(set) var submissionStage: FeedbackSubmissionStage?
    @Published private(set) var submissionProgress: Double = 0
    @Published private(set) var submissionFailure: FeedbackSubmissionFailureState?
    @Published private(set) var completionState: FeedbackCompletionState?

    // MARK: - Services

    private let feedbackService = FeedbackService.shared
    private weak var coordinatorWrapper: AppCoordinatorWrapper?
    private let launchSource: FeedbackLaunchContext.Source?
    private var submissionProgressTask: Task<Void, Never>?
    private var submissionStageTask: Task<Void, Never>?
    private var uploadStageStartedAt: Date?
    private var uploadStageInitialProgress: Double = 0

    private let minimumUploadDisplaySeconds: TimeInterval = 8.0
    private let uploadProgressRampSeconds: TimeInterval = 8.0
    private let recentMetricEventLimit = 100
    private static let defaultDiagnosticSections = Set(DiagnosticInfo.SectionID.allCases)

    // MARK: - Computed Properties

    public var canSubmit: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSubmitting &&
        !isExporting &&
        isEmailValid
    }

    public var canExport: Bool {
        !isSubmitting &&
        !isExporting
    }

    var submissionTitle: String {
        FeedbackSubmissionProgress.copy(
            for: feedbackType,
            stage: submissionStage
        ).title
    }

    var submissionDetail: String {
        FeedbackSubmissionProgress.copy(
            for: feedbackType,
            stage: submissionStage
        ).detail
    }

    var submissionSteps: [FeedbackSubmissionStep] {
        FeedbackSubmissionProgress.steps(
            for: feedbackType,
            currentStage: submissionStage
        )
    }

    var submissionPercentText: String {
        "\(max(1, Int((submissionProgress * 100).rounded())))%"
    }

    var hasSubmissionFailure: Bool {
        submissionFailure != nil
    }

    var hasSuccessfulCompletion: Bool {
        completionState != nil
    }

    var completionPresentation: FeedbackCompletionPresentation? {
        completionState?.presentation
    }

    var submissionFailureTitle: String {
        submissionFailure?.title ?? "Feedback wasn't sent"
    }

    var submissionFailureDetail: String {
        submissionFailure?.detail ?? "Something went wrong while sending feedback."
    }

    var submissionFailureSymbolName: String {
        submissionFailure?.symbolName ?? "exclamationmark.triangle.fill"
    }

    var submissionFailureIsNetworkRelated: Bool {
        submissionFailure?.isNetworkRelated ?? false
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

    /// Include logs only for bug reports.
    public var includesLogsInDiagnostics: Bool {
        feedbackType == .bug
    }

    public var diagnosticsSummary: String {
        guard let diagnostics = diagnostics else { return "Loading..." }
        return "v\(diagnostics.appVersion) • macOS \(diagnostics.macOSVersion) • \(diagnostics.deviceModel)"
    }

    var includedDiagnosticSectionCount: Int {
        diagnosticSections.filter { includedDiagnosticSections.contains($0.id) }.count
    }

    var excludedDiagnosticSectionCount: Int {
        max(0, diagnosticSections.count - includedDiagnosticSectionCount)
    }

    var hasSelectedDiagnosticSections: Bool {
        includedDiagnosticSectionCount > 0
    }

    private var fallbackDatabaseStats: DiagnosticInfo.DatabaseStats {
        diagnostics?.databaseStats ?? DiagnosticInfo.DatabaseStats(
            sessionCount: 0,
            frameCount: 0,
            segmentCount: 0,
            databaseSizeMB: 0
        )
    }

    // MARK: - Email Validation

    private func isValidEmailFormat(_ email: String) -> Bool {
        // Basic email validation: something@something.something
        // Must have: local part, @, domain, ., TLD (at least 2 chars)
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Initialization

    public init(launchContext: FeedbackLaunchContext? = nil) {
        self.launchSource = launchContext?.source
        if let launchContext {
            feedbackType = launchContext.feedbackType
            description = launchContext.prefilledDescription ?? ""
        }
        // Don't load diagnostics on init - load lazily when needed
    }

    /// Set the coordinator wrapper (diagnostics loaded lazily)
    public func setCoordinator(_ wrapper: AppCoordinatorWrapper) {
        self.coordinatorWrapper = wrapper
    }

    /// Load diagnostics when user wants to see details (uses quick method for fast preview)
    public func loadDiagnosticsIfNeeded() {
        guard diagnostics == nil else { return }
        Task {
            await loadDiagnosticsQuick()
        }
    }

    /// Update feedback type and refresh diagnostics preview for the selected type.
    public func setFeedbackType(_ type: FeedbackType) {
        guard feedbackType != type else { return }
        feedbackType = type
        diagnostics = nil
        resetDiagnosticSectionSelection()
        if showDiagnosticsDetail {
            loadDiagnosticsIfNeeded()
        }
    }

    public func isDiagnosticSectionIncluded(_ section: DiagnosticInfo.SectionID) -> Bool {
        includedDiagnosticSections.contains(section)
    }

    public func toggleDiagnosticSection(_ section: DiagnosticInfo.SectionID) {
        setDiagnosticSection(section, isIncluded: !includedDiagnosticSections.contains(section))
    }

    public func setDiagnosticSection(
        _ section: DiagnosticInfo.SectionID,
        isIncluded: Bool
    ) {
        let wasIncluded = includedDiagnosticSections.contains(section)
        guard wasIncluded != isIncluded else { return }

        if isIncluded {
            includedDiagnosticSections.insert(section)
        } else {
            includedDiagnosticSections.remove(section)
        }
    }

    // MARK: - Actions

    /// Load diagnostic information with placeholder stats
    public func loadDiagnostics() {
        let includeLogs = includesLogsInDiagnostics
        let stats = fallbackDatabaseStats
        Task {
            let collectedDiagnostics = await collectFullDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: includeLogs ? nil : stats
            )
            diagnostics = collectedDiagnostics
        }
    }

    /// Load diagnostics quickly for preview (5-minute log window, optimized query)
    /// This is fast enough for the "Details" button
    private func loadDiagnosticsQuick() async {
        let includeLogs = includesLogsInDiagnostics

        guard let wrapper = coordinatorWrapper else {
            // Fallback to basic diagnostics without coordinator
            let stats = DiagnosticInfo.DatabaseStats(
                sessionCount: 0,
                frameCount: 0,
                segmentCount: 0,
                databaseSizeMB: 0
            )
            let collectedDiagnostics = await collectQuickDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: stats
            )
            diagnostics = collectedDiagnostics
            return
        }

        do {
            // Use the optimized single-query method
            let quickStats = try await wrapper.coordinator.getDatabaseStatisticsQuick()

            // Get database file size (fast - just file attributes)
            let dbPath = NSString(string: AppPaths.databasePath).expandingTildeInPath
            var dbSizeMB: Double = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
               let size = attrs[.size] as? Int64 {
                dbSizeMB = Double(size) / (1024 * 1024)
            }

            let stats = DiagnosticInfo.DatabaseStats(
                sessionCount: quickStats.sessionCount,
                frameCount: quickStats.frameCount,
                segmentCount: 0, // Not fetched in quick query
                databaseSizeMB: dbSizeMB
            )

            let collectedDiagnostics = await collectQuickDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: stats
            )
            self.diagnostics = collectedDiagnostics
        } catch {
            Log.warning("[FeedbackViewModel] Failed to load quick stats: \(error)", category: .ui)
            let stats = DiagnosticInfo.DatabaseStats(
                sessionCount: 0,
                frameCount: 0,
                segmentCount: 0,
                databaseSizeMB: 0
            )
            let collectedDiagnostics = await collectQuickDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: stats
            )
            diagnostics = collectedDiagnostics
        }
    }

    /// Load full diagnostic information with complete stats.
    private func loadDiagnosticsWithRealStats(includeLogs: Bool) async {
        guard let wrapper = coordinatorWrapper else {
            let collectedDiagnostics = await collectFullDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: includeLogs ? nil : fallbackDatabaseStats
            )
            diagnostics = collectedDiagnostics
            return
        }

        do {
            let quickStats = try await wrapper.coordinator.getDatabaseStatisticsQuick()

            // Get database file size (fast - just file attributes)
            let dbPath = NSString(string: AppPaths.databasePath).expandingTildeInPath
            var dbSizeMB: Double = 0
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
               let size = attrs[.size] as? Int64 {
                dbSizeMB = Double(size) / (1024 * 1024)
            }

            let stats = DiagnosticInfo.DatabaseStats(
                sessionCount: quickStats.sessionCount,
                frameCount: quickStats.frameCount,
                segmentCount: 0, // Not needed for feedback
                databaseSizeMB: dbSizeMB
            )

            let collectedDiagnostics = await collectFullDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: stats
            )
            self.diagnostics = collectedDiagnostics
        } catch {
            Log.warning("[FeedbackViewModel] Failed to load real stats: \(error)", category: .ui)
            let collectedDiagnostics = await collectFullDiagnosticsInBackground(
                includeLogs: includeLogs,
                stats: includeLogs ? nil : fallbackDatabaseStats
            )
            diagnostics = collectedDiagnostics
        }
    }

    /// Submit the feedback
    public func submit() async {
        guard canSubmit else { return }

        let submissionType = feedbackType
        isSubmitting = true
        error = nil
        submissionFailure = nil
        beginSubmissionExperience(for: submissionType)

        do {
            transitionSubmission(to: .packaging, cancelAutomaticStages: true)
            let submission = try await buildSubmission(forUpload: true)

            transitionSubmission(to: .upload, cancelAutomaticStages: true)
            _ = try await feedbackService.submitFeedback(submission)
            await waitForMinimumUploadDisplay()
            transitionSubmission(to: .confirmation, cancelAutomaticStages: true)
            await completeSubmissionExperience()
            completionState = .submitted
            isSubmitted = true
        } catch {
            if uploadStageStartedAt != nil {
                await waitForMinimumUploadDisplay()
            }
            self.error = error.localizedDescription
            submissionFailure = Self.makeSubmissionFailure(from: error)
            resetSubmissionExperience()
        }

        isSubmitting = false
    }

    public func exportFeedbackReport() async {
        guard canExport else { return }

        error = nil

        let suggestedFileName = "\(FeedbackSubmission.suggestedBaseName(forType: feedbackType.rawValue)).json.gz"
        let exportURL: URL
        do {
            guard let selectedExportURL = try await chooseExportURL(defaultFileName: suggestedFileName) else {
                recordFeedbackExportMetric(outcome: "cancelled", exportedFileCount: 0)
                return
            }
            exportURL = selectedExportURL
        } catch {
            self.error = "Failed to save feedback report: \(error.localizedDescription)"
            recordFeedbackExportMetric(outcome: "failed", exportedFileCount: 0)
            return
        }

        isExporting = true
        defer { isExporting = false }

        do {
            let submission = try await buildSubmission(forUpload: true)
            let exportedURLs = try await feedbackService.exportFeedbackReport(
                submission,
                to: exportURL,
                launchSource: launchSource
            )
            NSWorkspace.shared.activateFileViewerSelecting(exportedURLs)
            completionState = .exported
            recordFeedbackExportMetric(outcome: "exported", exportedFileCount: exportedURLs.count)
        } catch {
            self.error = "Failed to save feedback report: \(error.localizedDescription)"
            recordFeedbackExportMetric(outcome: "failed", exportedFileCount: 0)
        }
    }

    /// Copy diagnostics to clipboard
    public func copyDiagnostics() {
        guard let diagnostics = diagnostics else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            diagnostics.formattedText(including: includedDiagnosticSections),
            forType: .string
        )
    }

    /// Export diagnostics to file
    public func exportDiagnostics() {
        guard let url = feedbackService.exportDiagnostics() else { return }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    /// Reset form for new submission
    public func reset() {
        cancelTransientTasks()
        feedbackType = .bug
        email = ""
        description = ""
        attachedImage = nil
        attachedImageData = nil
        resetDiagnosticSectionSelection()
        isSubmitting = false
        isExporting = false
        isSubmitted = false
        error = nil
        submissionStage = nil
        submissionProgress = 0
        submissionFailure = nil
        completionState = nil
        Task {
            await loadDiagnosticsWithRealStats(includeLogs: true)
        }
    }

    public func teardown() {
        cancelTransientTasks()
    }

    func clearSubmissionFailure() {
        submissionFailure = nil
    }

    private func beginSubmissionExperience(for type: FeedbackType) {
        cancelTransientTasks()

        let initialStage = FeedbackSubmissionProgress.initialStage(for: type)
        uploadStageStartedAt = nil
        uploadStageInitialProgress = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            submissionStage = initialStage
            submissionProgress = initialStage.minimumVisibleProgress
        }

        startSubmissionProgressTask()
        startSubmissionStageTask(for: type)
    }

    private func transitionSubmission(
        to stage: FeedbackSubmissionStage,
        cancelAutomaticStages: Bool = false
    ) {
        if cancelAutomaticStages {
            submissionStageTask?.cancel()
            submissionStageTask = nil
        }

        let minimumVisibleProgress = stage == .upload
            ? submissionProgress
            : stage.minimumVisibleProgress

        withAnimation(.easeInOut(duration: 0.28)) {
            submissionStage = stage
            submissionProgress = max(
                submissionProgress,
                minimumVisibleProgress
            )
        }

        if stage == .upload {
            uploadStageStartedAt = Date()
            uploadStageInitialProgress = submissionProgress
        } else if stage == .confirmation {
            uploadStageStartedAt = nil
        }
    }

    private func completeSubmissionExperience() async {
        cancelTransientTasks()

        withAnimation(.easeOut(duration: 0.24)) {
            submissionProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(260))
    }

    private func resetSubmissionExperience() {
        cancelTransientTasks()
        submissionStage = nil
        submissionProgress = 0
        uploadStageStartedAt = nil
        uploadStageInitialProgress = 0
    }

    private func cancelTransientTasks() {
        submissionProgressTask?.cancel()
        submissionProgressTask = nil
        submissionStageTask?.cancel()
        submissionStageTask = nil
    }

    private func startSubmissionProgressTask() {
        submissionProgressTask?.cancel()
        submissionProgressTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let stage = self.submissionStage ?? FeedbackSubmissionProgress.initialStage(for: self.feedbackType)
                if stage == .upload {
                    if let uploadStageStartedAt = self.uploadStageStartedAt {
                        let elapsed = Date().timeIntervalSince(uploadStageStartedAt)
                        let progressFraction = min(max(elapsed / self.uploadProgressRampSeconds, 0), 1)
                        let target = self.uploadStageInitialProgress +
                            ((stage.targetProgress - self.uploadStageInitialProgress) * progressFraction)

                        if target > self.submissionProgress {
                            withAnimation(.linear(duration: 0.1)) {
                                self.submissionProgress = min(stage.targetProgress, target)
                            }
                        }
                    }
                } else {
                    let target = stage.targetProgress

                    if self.submissionProgress < target {
                        let increment = max(0.008, (target - self.submissionProgress) * 0.2)
                        withAnimation(.linear(duration: 0.12)) {
                            self.submissionProgress = min(
                                target,
                                self.submissionProgress + increment
                            )
                        }
                    }
                }

                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private func startSubmissionStageTask(for type: FeedbackType) {
        let stages = FeedbackSubmissionProgress.automaticStages(for: type)
        guard !stages.isEmpty else { return }

        submissionStageTask?.cancel()
        submissionStageTask = Task { [weak self] in
            for stage in stages {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isSubmitting else { return }
                if self.submissionStage == .upload || self.submissionStage == .confirmation {
                    return
                }
                self.transitionSubmission(to: stage)
            }
        }
    }

    private func waitForMinimumUploadDisplay() async {
        guard let uploadStageStartedAt else { return }

        let elapsed = Date().timeIntervalSince(uploadStageStartedAt)
        let remainingMs = Int(max(0, (minimumUploadDisplaySeconds - elapsed) * 1000).rounded())
        guard remainingMs > 0 else { return }

        try? await Task.sleep(for: .milliseconds(remainingMs))
    }

    private func collectQuickDiagnosticsInBackground(
        includeLogs: Bool,
        stats: DiagnosticInfo.DatabaseStats
    ) async -> DiagnosticInfo {
        async let recentMetricEvents = loadRecentMetricEvents()

        if includeLogs {
            let diagnostics = await feedbackService.collectDiagnosticsQuickAsync(with: stats)
            return diagnostics.withRecentMetricEvents(await recentMetricEvents)
        }

        let diagnostics = feedbackService.collectDiagnosticsNoLogs(with: stats)
        return diagnostics.withRecentMetricEvents(await recentMetricEvents)
    }

    private func collectFullDiagnosticsInBackground(
        includeLogs: Bool,
        stats: DiagnosticInfo.DatabaseStats?
    ) async -> DiagnosticInfo {
        let fallbackStats = fallbackDatabaseStats
        async let recentMetricEvents = loadRecentMetricEvents()

        if let stats {
            if includeLogs {
                let diagnostics = await feedbackService.collectDiagnosticsAsync(with: stats)
                return diagnostics.withRecentMetricEvents(await recentMetricEvents)
            }

            let diagnostics = feedbackService.collectDiagnosticsNoLogs(with: stats)
            return diagnostics.withRecentMetricEvents(await recentMetricEvents)
        }

        if includeLogs {
            let diagnostics = await feedbackService.collectDiagnosticsAsync()
            return diagnostics.withRecentMetricEvents(await recentMetricEvents)
        }

        let diagnostics = feedbackService.collectDiagnosticsNoLogs(with: fallbackStats)
        return diagnostics.withRecentMetricEvents(await recentMetricEvents)
    }

    private func loadRecentMetricEvents() async -> [FeedbackRecentMetricEvent] {
        guard let coordinator = coordinatorWrapper?.coordinator else {
            return []
        }

        do {
            return try await coordinator.getRecentMetricEvents(limit: recentMetricEventLimit)
        } catch {
            Log.warning("[FeedbackViewModel] Failed to load recent metric events: \(error)", category: .ui)
            return []
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

    private func buildSubmission(forUpload: Bool = false) async throws -> FeedbackSubmission {
        let includeLogs = feedbackType == .bug
        let submissionDiagnostics: DiagnosticInfo
        if forUpload, includeLogs {
            async let stats = submissionDatabaseStats()
            async let recentMetricEvents = submissionRecentMetricEvents()
            let expandedDiagnostics = await feedbackService.collectSubmissionDiagnosticsAsync(with: stats)
            submissionDiagnostics = expandedDiagnostics.withRecentMetricEvents(await recentMetricEvents)
        } else {
            await loadDiagnosticsWithRealStats(includeLogs: includeLogs)

            guard let diagnostics else {
                throw FeedbackError.invalidData
            }

            submissionDiagnostics = diagnostics
        }

        return FeedbackSubmission(
            type: feedbackType,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description,
            diagnostics: submissionDiagnostics,
            includedDiagnosticSections: includedDiagnosticSections,
            includeScreenshot: attachedImageData != nil,
            screenshotData: attachedImageData
        )
    }

    private func submissionDatabaseStats() async -> DiagnosticInfo.DatabaseStats {
        if let diagnostics {
            return diagnostics.databaseStats
        }

        guard let wrapper = coordinatorWrapper else {
            return fallbackDatabaseStats
        }

        do {
            let quickStats = try await wrapper.coordinator.getDatabaseStatisticsQuick()

            let dbPath = NSString(string: AppPaths.databasePath).expandingTildeInPath
            let dbSizeMB: Double
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
               let size = attrs[.size] as? Int64 {
                dbSizeMB = Double(size) / (1024 * 1024)
            } else {
                dbSizeMB = 0
            }

            let stats = DiagnosticInfo.DatabaseStats(
                sessionCount: quickStats.sessionCount,
                frameCount: quickStats.frameCount,
                segmentCount: 0,
                databaseSizeMB: dbSizeMB
            )
            return stats
        } catch {
            Log.warning("[FeedbackViewModel] Failed to load submission stats: \(error)", category: .ui)
            return fallbackDatabaseStats
        }
    }

    private func submissionRecentMetricEvents() async -> [FeedbackRecentMetricEvent] {
        if let diagnostics {
            return diagnostics.recentMetricEvents
        }

        return await loadRecentMetricEvents()
    }

    private func chooseExportURL(defaultFileName: String) async throws -> URL? {
        let suggestedURL = try Self.downloadsExportURL(defaultFileName: defaultFileName)

        return await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.gzip]
            panel.canCreateDirectories = true
            panel.directoryURL = suggestedURL.deletingLastPathComponent()
            panel.nameFieldStringValue = suggestedURL.lastPathComponent
            panel.message = "Save the feedback report as a gzipped JSON file"
            panel.prompt = "Download"

            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    nonisolated static func downloadsExportURL(
        defaultFileName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw FeedbackExportDestinationError.downloadsUnavailable
        }
        return suggestedExportURL(
            defaultFileName: defaultFileName,
            directoryURL: downloadsURL
        )
    }

    nonisolated static func suggestedExportURL(
        defaultFileName: String,
        directoryURL: URL
    ) -> URL {
        directoryURL.appendingPathComponent(defaultFileName, isDirectory: false)
    }

    private func recordFeedbackExportMetric(outcome: String, exportedFileCount: Int) {
        guard let coordinator = coordinatorWrapper?.coordinator else { return }

        let metadata = Self.metricMetadata([
            "outcome": outcome,
            "source": launchSource?.rawValue ?? FeedbackLaunchContext.Source.manual.rawValue,
            "feedbackType": feedbackType.rawValue,
            "includeLogs": includesLogsInDiagnostics,
            "includeScreenshot": attachedImageData != nil,
            "includedDiagnosticSections": includedDiagnosticSectionIdentifiers,
            "excludedDiagnosticSections": excludedDiagnosticSectionIdentifiers,
            "exportedFileCount": exportedFileCount
        ])

        Task {
            try? await coordinator.recordMetricEvent(
                metricType: .feedbackReportExport,
                metadata: metadata
            )
        }
    }

    private static func metricMetadata(_ payload: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    static func makeSubmissionFailure(from error: Error) -> FeedbackSubmissionFailureState {
        if case FeedbackError.networkError = error {
            return FeedbackSubmissionFailureState(
                title: "No network connection",
                detail: "Retrace couldn't reach the internet from this Mac. If network access is blocked, go back and use Download .json.gz instead.",
                symbolName: "wifi.slash",
                isNetworkRelated: true
            )
        }

        return FeedbackSubmissionFailureState(
            title: "Feedback wasn't sent",
            detail: error.localizedDescription,
            symbolName: "exclamationmark.triangle.fill",
            isNetworkRelated: false
        )
    }

    private func resetDiagnosticSectionSelection() {
        includedDiagnosticSections = Self.defaultDiagnosticSections
    }

    private var orderedDiagnosticSectionIDs: [DiagnosticInfo.SectionID] {
        diagnosticSections.map(\.id)
    }

    private var includedDiagnosticSectionIdentifiers: [String] {
        orderedDiagnosticSectionIDs
            .filter { includedDiagnosticSections.contains($0) }
            .map(\.rawValue)
    }

    private var excludedDiagnosticSectionIdentifiers: [String] {
        orderedDiagnosticSectionIDs
            .filter { !includedDiagnosticSections.contains($0) }
            .map(\.rawValue)
    }
}
