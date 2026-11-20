import Foundation

enum FeedbackSubmissionStage: String, CaseIterable, Sendable {
    case preparing
    case crashReports
    case recentLogs
    case deviceSnapshot
    case packaging
    case upload
    case confirmation

    var targetProgress: Double {
        switch self {
        case .preparing:
            return 0.16
        case .crashReports:
            return 0.20
        case .recentLogs:
            return 0.38
        case .deviceSnapshot:
            return 0.58
        case .packaging:
            return 0.76
        case .upload:
            return 0.92
        case .confirmation:
            return 0.98
        }
    }

    var minimumVisibleProgress: Double {
        switch self {
        case .preparing:
            return 0.08
        case .crashReports:
            return 0.10
        case .recentLogs:
            return 0.24
        case .deviceSnapshot:
            return 0.42
        case .packaging:
            return 0.62
        case .upload:
            return 0.84
        case .confirmation:
            return 0.96
        }
    }
}

struct FeedbackSubmissionStep: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case pending
        case active
        case complete
    }

    let id: FeedbackSubmissionStage
    let title: String
    let detail: String
    let status: Status
}

enum FeedbackSubmissionProgress {
    static func stages(for type: FeedbackType) -> [FeedbackSubmissionStage] {
        switch type {
        case .bug:
            return [.crashReports, .recentLogs, .deviceSnapshot, .packaging, .upload, .confirmation]
        case .feature, .question:
            return [.preparing, .deviceSnapshot, .packaging, .upload, .confirmation]
        }
    }

    static func initialStage(for type: FeedbackType) -> FeedbackSubmissionStage {
        stages(for: type).first ?? .packaging
    }

    static func automaticStages(for type: FeedbackType) -> [FeedbackSubmissionStage] {
        let initialStage = initialStage(for: type)
        return stages(for: type).filter { stage in
            stage != initialStage &&
            stage != .upload &&
            stage != .confirmation
        }
    }

    static func copy(
        for type: FeedbackType,
        stage: FeedbackSubmissionStage?
    ) -> (title: String, detail: String) {
        descriptor(for: stage ?? initialStage(for: type), type: type)
    }

    static func steps(
        for type: FeedbackType,
        currentStage: FeedbackSubmissionStage?
    ) -> [FeedbackSubmissionStep] {
        let stages = stages(for: type)
        let activeStage = currentStage ?? initialStage(for: type)
        let activeIndex = stages.firstIndex(of: activeStage) ?? 0

        return stages.enumerated().map { index, stage in
            let status: FeedbackSubmissionStep.Status
            if index < activeIndex {
                status = .complete
            } else if index == activeIndex {
                status = .active
            } else {
                status = .pending
            }

            let descriptor = descriptor(for: stage, type: type)
            return FeedbackSubmissionStep(
                id: stage,
                title: descriptor.title,
                detail: descriptor.detail,
                status: status
            )
        }
    }

    private static func descriptor(
        for stage: FeedbackSubmissionStage,
        type: FeedbackType
    ) -> (title: String, detail: String) {
        switch (type, stage) {
        case (.bug, .preparing):
            return (
                "Preparing bug report",
                "Getting the submission ready before diagnostics are attached."
            )
        case (.bug, .crashReports):
            return (
                "Compiling crash reports",
                "Checking emergency snapshots and recent crash artifacts."
            )
        case (.bug, .recentLogs):
            return (
                "Getting recent logs",
                "Pulling the latest Retrace activity for context."
            )
        case (.bug, .deviceSnapshot):
            return (
                "Collecting device snapshot",
                "Gathering version, hardware, storage, and capture state."
            )
        case (.bug, .packaging):
            return (
                "Bundling diagnostics",
                "Packing your note, screenshots, and debug details together."
            )
        case (.bug, .upload):
            return (
                "Sending feedback",
                "Uploading the report securely to Retrace."
            )
        case (.bug, .confirmation):
            return (
                "Verifying delivery",
                "Waiting for the server to confirm everything arrived."
            )

        case (.feature, .preparing):
            return (
                "Preparing your request",
                "Formatting your note so it is easy to review."
            )
        case (.question, .preparing):
            return (
                "Preparing your question",
                "Formatting your note so the reply has enough context."
            )
        case (.feature, .deviceSnapshot), (.question, .deviceSnapshot):
            return (
                "Collecting app snapshot",
                "Adding version, device, and settings context."
            )
        case (.feature, .packaging), (.question, .packaging):
            return (
                "Bundling attachments",
                "Packing your note and any screenshots together."
            )
        case (.feature, .upload), (.question, .upload):
            return (
                "Sending feedback",
                "Uploading the message securely to Retrace."
            )
        case (.feature, .confirmation), (.question, .confirmation):
            return (
                "Verifying delivery",
                "Waiting for the server to confirm everything arrived."
            )

        case (.feature, .crashReports),
             (.feature, .recentLogs),
             (.question, .crashReports),
             (.question, .recentLogs):
            return (
                "Preparing your note",
                "Getting the submission ready to send."
            )
        }
    }
}
