import SwiftUI
import Shared

/// Detail sheet showing all sessions for a specific app with links to open in timeline
struct AppSessionsDetailView: View {
    let app: AppUsageData
    let onOpenInTimeline: (Date) -> Void
    let loadSessions: (Int, Int) async -> [AppSessionDetail]  // (offset, limit) -> sessions
    let subtitle: String?  // Optional subtitle (e.g., window name filter)
    let initialSessionCount: Int?  // Optional override for initial session count
    let onDismiss: (() -> Void)?  // Optional dismiss callback for overlay presentation

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AppSessionDetail] = []
    @State private var hoveredSessionID: Int64? = nil
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreToLoad = true
    @State private var totalSessionCount: Int

    private let pageSize = 10

    init(
        app: AppUsageData,
        onOpenInTimeline: @escaping (Date) -> Void,
        loadSessions: @escaping (Int, Int) async -> [AppSessionDetail],
        subtitle: String? = nil,
        initialSessionCount: Int? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.app = app
        self.onOpenInTimeline = onOpenInTimeline
        self.loadSessions = loadSessions
        self.subtitle = subtitle
        self.initialSessionCount = initialSessionCount
        self.onDismiss = onDismiss
        // When filtering (subtitle provided), start with 0 and update after loading
        // Otherwise use the provided count or app's count
        let startCount = initialSessionCount ?? (subtitle != nil ? 0 : app.uniqueItemCount)
        self._totalSessionCount = State(initialValue: startCount)
    }

    /// Dismisses the view using the provided callback or environment dismiss
    private func dismissView() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()
                .background(Color.white.opacity(0.08))

            // Sessions list
            if isLoading && sessions.isEmpty {
                loadingState
            } else if sessions.isEmpty {
                emptyState
            } else {
                sessionsList
            }
        }
        .frame(width: 680, height: 500)
        .background(Color.retraceBackground)
        .task {
            await loadInitialSessions()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // App icon
            AppIconView(bundleID: app.appBundleID, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(app.appName)
                        .font(.retraceTitle3)
                        .foregroundColor(.retracePrimary)

                    if let subtitle = subtitle {
                        Text("·")
                            .font(.retraceTitle3)
                            .foregroundColor(.retraceSecondary)
                        Text(subtitle)
                            .font(.retraceCalloutMedium)
                            .foregroundColor(.retraceSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                HStack(spacing: 12) {
                    if subtitle == nil {
                        Label(formatDuration(app.duration), systemImage: "clock")
                    }
                    Label("\(totalSessionCount) session\(totalSessionCount == 1 ? "" : "s")", systemImage: "rectangle.stack")
                }
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Button(action: { dismissView() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retraceSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .onAppear {
                            // Trigger load more when approaching the end
                            if session.id == sessions.last?.id {
                                Task {
                                    await loadMoreSessions()
                                }
                            }
                        }
                }

                // Loading indicator at bottom
                if isLoadingMore {
                    HStack {
                        SpinnerView(size: 16, lineWidth: 2)
                        Text("Loading more...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                // End of list indicator
                if !hasMoreToLoad && sessions.count > pageSize {
                    Text("All \(sessions.count) sessions loaded")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(16)
        }
    }

    private func sessionRow(_ session: AppSessionDetail) -> some View {
        let isHovered = hoveredSessionID == session.id
        let appColor = Color.segmentColor(for: session.appBundleID)

        return HStack(spacing: 14) {
            // Time indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(session.startDate))
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retracePrimary)

                Text(formatDate(session.startDate))
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
            }
            .frame(width: 80, alignment: .leading)

            // Duration pill
            HStack(spacing: 4) {
                Circle()
                    .fill(appColor)
                    .frame(width: 6, height: 6)

                Text(formatDuration(session.duration))
                    .font(.retraceCaption2Bold)
                    .foregroundColor(.retracePrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(appColor.opacity(0.15))
            .cornerRadius(12)

            // Window name (if available)
            if let windowName = session.windowName, !windowName.isEmpty {
                Text(windowName)
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            // Open in Timeline button
            Button(action: {
                onOpenInTimeline(session.startDate)
                dismissView()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.retraceCallout)
                    Text("View")
                        .font(.retraceCaption2Medium)
                }
                .foregroundColor(isHovered ? .retraceAccent : .retraceSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.retraceAccent.opacity(0.15) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isHovered ? Color.retraceAccent.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isHovered ? 0.1 : 0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredSessionID = hovering ? session.id : nil
            }
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 16) {
            SpinnerView(size: 24, lineWidth: 3)

            Text("Loading sessions...")
                .font(.retraceCalloutMedium)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.questionmark")
                .font(.retraceDisplay)
                .foregroundColor(.retraceSecondary.opacity(0.5))

            Text("No sessions found")
                .font(.retraceBodyMedium)
                .foregroundColor(.retraceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadInitialSessions() async {
        let loaded = await loadSessions(0, pageSize)

        await MainActor.run {
            sessions = loaded
            hasMoreToLoad = loaded.count >= pageSize
            isLoading = false
            // Update total count if we got more than expected
            if loaded.count > totalSessionCount {
                totalSessionCount = loaded.count
            }
        }
    }

    private func loadMoreSessions() async {
        guard !isLoadingMore && hasMoreToLoad else { return }

        isLoadingMore = true
        let offset = sessions.count
        let loaded = await loadSessions(offset, pageSize)

        await MainActor.run {
            // Filter out duplicates by ID
            let existingIDs = Set(sessions.map { $0.id })
            let newSessions = loaded.filter { !existingIDs.contains($0.id) }

            sessions.append(contentsOf: newSessions)
            hasMoreToLoad = loaded.count >= pageSize
            isLoadingMore = false

            // Update total count
            totalSessionCount = max(totalSessionCount, sessions.count)
        }
    }

    // MARK: - Formatting Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AppSessionsDetailView_Previews: PreviewProvider {
    static func mockLoadSessions(offset: Int, limit: Int) async -> [AppSessionDetail] {
        let totalMockSessions = 50
        let availableCount = max(0, totalMockSessions - offset)
        let count = min(limit, availableCount)

        return (0..<count).map { i in
            let index = offset + i
            return AppSessionDetail(
                id: Int64(index),
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                startDate: Date().addingTimeInterval(Double(-3600 * index)),
                endDate: Date().addingTimeInterval(Double(-3600 * index + 1800)),
                windowName: index % 3 == 0 ? nil : "Window Title \(index)"
            )
        }
    }

    static var previews: some View {
        AppSessionsDetailView(
            app: AppUsageData(
                appBundleID: "com.apple.Safari",
                appName: "Safari",
                duration: 7200,
                uniqueItemCount: 50,
                percentage: 0.35
            ),
            onOpenInTimeline: { _ in },
            loadSessions: mockLoadSessions
        )
        .preferredColorScheme(.dark)
    }
}
#endif
