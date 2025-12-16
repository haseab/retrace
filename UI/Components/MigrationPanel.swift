import SwiftUI
import Shared

/// Migration panel for importing data from other apps
public struct MigrationPanel: View {

    // MARK: - Properties

    let sources: [MigrationSource]
    let importProgress: MigrationProgress?
    let isImporting: Bool
    let onStartImport: (MigrationSource) -> Void
    let onPauseImport: () -> Void
    let onCancelImport: () -> Void
    let onScanSources: () -> Void

    @State private var selectedSource: MigrationSource?

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: .spacingL) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import from Third-Party Apps")
                        .font(.retraceTitle3)
                        .foregroundColor(.retracePrimary)

                    Text("Import your screen history from other apps")
                        .font(.retraceBody)
                        .foregroundColor(.retraceSecondary)
                }

                Spacer()

                Button("Scan for Data") {
                    onScanSources()
                }
                .buttonStyle(RetraceSecondaryButtonStyle())
            }

            Divider()

            // Available sources
            VStack(alignment: .leading, spacing: .spacingM) {
                Text("Available Sources")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                ForEach(sources) { source in
                    sourceRow(source: source)
                }
            }

            // Import progress (if importing)
            if isImporting, let progress = importProgress {
                Divider()
                importProgressView(progress: progress)
            }
        }
        .padding(.spacingL)
        .background(Color.retraceCard)
        .cornerRadius(.cornerRadiusL)
        .retraceShadowMedium()
    }

    // MARK: - Source Row

    private func sourceRow(source: MigrationSource) -> some View {
        HStack(spacing: .spacingM) {
            // Checkbox
            Image(systemName: source.isInstalled ? "checkmark.square.fill" : "square")
                .foregroundColor(source.isInstalled ? .retraceSuccess : .retraceSecondary)
                .font(.system(size: 20))

            // Source info
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.retraceBody)
                    .foregroundColor(.retracePrimary)

                if source.isInstalled, let size = source.estimatedSize {
                    Text("\(formatBytes(size)) found")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                } else {
                    Text("Not installed")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()

            // Import button
            if source.isInstalled {
                Button(isImporting && selectedSource?.id == source.id ? "Importing..." : "Import") {
                    selectedSource = source
                    onStartImport(source)
                }
                .buttonStyle(RetracePrimaryButtonStyle())
                .disabled(isImporting)
            }
        }
        .padding(.spacingM)
        .background(source.isInstalled ? Color.retraceSecondaryBackground : Color.clear)
        .cornerRadius(.cornerRadiusM)
    }

    // MARK: - Import Progress

    private func importProgressView(progress: MigrationProgress) -> some View {
        VStack(alignment: .leading, spacing: .spacingM) {
            Text("Importing from \(selectedSource?.name ?? "source")...")
                .font(.retraceHeadline)
                .foregroundColor(.retracePrimary)

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Rectangle()
                        .fill(Color.retraceSecondaryBackground)
                        .frame(height: 8)
                        .cornerRadius(4)

                    // Progress
                    Rectangle()
                        .fill(Color.retraceAccent)
                        .frame(
                            width: geometry.size.width * CGFloat(progress.percentComplete),
                            height: 8
                        )
                        .cornerRadius(4)
                }
            }
            .frame(height: 8)

            // Stats
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(progress.percentComplete * 100))% complete")
                        .font(.retraceBody)
                        .foregroundColor(.retracePrimary)

                    HStack(spacing: 4) {
                        Text("\(formatNumber(progress.videosProcessed)) videos processed")
                        Text("•")
                        Text("\(formatNumber(progress.framesImported)) frames imported")
                    }
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
                }

                Spacer()

                if let estimatedTime = progress.estimatedSecondsRemaining {
                    Text("Est. \(formatDuration(estimatedTime)) remaining")
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary)
                }
            }

            // Actions
            HStack(spacing: .spacingM) {
                Button("Pause Import") {
                    onPauseImport()
                }
                .buttonStyle(RetraceSecondaryButtonStyle())

                Button("Cancel") {
                    onCancelImport()
                }
                .buttonStyle(RetraceDangerButtonStyle())
            }
        }
        .padding(.spacingM)
        .background(Color.retraceAccent.opacity(0.1))
        .cornerRadius(.cornerRadiusM)
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) / 60 % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes) minutes"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MigrationPanel_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: .spacingL) {
            // Without import
            MigrationPanel(
                sources: [
                    MigrationSource(
                        id: "rewind",
                        name: "Rewind AI",
                        isInstalled: true,
                        dataPath: "/path/to/rewind",
                        estimatedSize: 46_170_898_432 // 43 GB
                    ),
                    MigrationSource(
                        id: "screenmemory",
                        name: "ScreenMemory",
                        isInstalled: false,
                        dataPath: nil,
                        estimatedSize: nil
                    ),
                    MigrationSource(
                        id: "timescroll",
                        name: "TimeScroll",
                        isInstalled: false,
                        dataPath: nil,
                        estimatedSize: nil
                    )
                ],
                importProgress: nil,
                isImporting: false,
                onStartImport: { _ in },
                onPauseImport: {},
                onCancelImport: {},
                onScanSources: {}
            )

            // With import in progress
            MigrationPanel(
                sources: [
                    MigrationSource(
                        id: "rewind",
                        name: "Rewind AI",
                        isInstalled: true,
                        dataPath: "/path/to/rewind",
                        estimatedSize: 46_170_898_432
                    )
                ],
                importProgress: MigrationProgress(
                    state: .importing,
                    source: .rewind,
                    totalVideos: 6324,
                    videosProcessed: 2847,
                    totalFrames: 1_550_000,
                    framesImported: 1_200_000,
                    framesDeduplicated: 350_000,
                    currentVideoPath: "/path/to/video.mov",
                    bytesProcessed: 30_000_000_000,
                    totalBytes: 46_170_898_432,
                    startTime: Date().addingTimeInterval(-7200),
                    estimatedSecondsRemaining: 11520
                ),
                isImporting: true,
                onStartImport: { _ in },
                onPauseImport: {},
                onCancelImport: {},
                onScanSources: {}
            )
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
