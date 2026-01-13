import SwiftUI
import Shared
import App

/// Main full-screen timeline view - Rewind-style overlay experience
/// Shows the current frame image with timeline bar at bottom and floating search
public struct FullscreenTimelineView: View {

    // MARK: - Properties

    @StateObject private var viewModel: LegacyTimelineViewModel
    @State private var showSearch = false
    @State private var searchPosition: CGPoint = .zero
    @State private var isSearchDragging = false
    @State private var hasInitialized = false

    let coordinator: AppCoordinator
    let onClose: () -> Void

    // MARK: - Initialization

    public init(coordinator: AppCoordinator, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: LegacyTimelineViewModel(coordinator: coordinator))
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - semi-transparent black
                Color.black.opacity(0.95)
                    .ignoresSafeArea()

                // Main content
                VStack(spacing: 0) {
                    // Frame display area
                    FullscreenFrameView(
                        image: viewModel.currentFrameImage,
                        videoInfo: viewModel.currentFrameVideoInfo,
                        frame: viewModel.currentFrame,
                        isLoading: viewModel.isLoading
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        // Toggle search on tap
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearch.toggle()
                        }
                    }

                    // Timeline bar at bottom
                    FullscreenTimelineBar(
                        viewModel: viewModel,
                        width: geometry.size.width
                    )
                }

                // Floating search panel
                if showSearch {
                    FloatingSearchPanel(
                        coordinator: coordinator,
                        position: $searchPosition,
                        isDragging: $isSearchDragging,
                        onResultSelected: { result in
                            // Jump to selected frame
                            Task {
                                await viewModel.jumpToTimestamp(result.timestamp)
                            }
                        },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSearch = false
                            }
                        }
                    )
                    .position(
                        x: searchPosition.x == 0 ? geometry.size.width / 2 : searchPosition.x,
                        y: searchPosition.y == 0 ? geometry.size.height / 3 : searchPosition.y
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Close button (top-right corner)
                VStack {
                    HStack {
                        Spacer()

                        // 🐛 TEMPORARY DEBUG: Jump to Dec 16, 2025 6:05pm PST
                        Button(action: {
                            Task {
                                // Dec 16, 2025 at 6:05pm PST
                                var components = DateComponents()
                                components.year = 2025
                                components.month = 12
                                components.day = 16
                                components.hour = 18  // 6pm
                                components.minute = 5
                                components.timeZone = TimeZone(identifier: "America/Los_Angeles")

                                if let targetDate = Calendar.current.date(from: components) {
                                    await viewModel.jumpToTimestamp(targetDate)
                                }
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 20))
                                Text("Dec 16 2025\n6:05 PM")
                                    .font(.system(size: 10, weight: .medium))
                                    .multilineTextAlignment(.center)
                            }
                            .foregroundColor(.blue.opacity(0.8))
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue.opacity(0.2))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, .spacingM)

                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(.spacingL)
                    }
                    Spacer()
                }

                // Timestamp overlay (top-left)
                VStack {
                    HStack {
                        if let frame = viewModel.currentFrame {
                            timestampOverlay(frame: frame)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.spacingL)
            }
            .onAppear {
                // Initialize search position to center
                if searchPosition == .zero {
                    searchPosition = CGPoint(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 3
                    )
                }

                // Load initial frame (most recent)
                if !hasInitialized {
                    hasInitialized = true
                    Task {
                        await viewModel.loadMostRecentFrame()
                    }
                }
            }
            // Handle trackpad/mouse scroll for timeline navigation
            .overlay(
                ScrollCaptureView { delta in
                    print("[FullscreenTimelineView] ScrollCaptureView callback - raw delta: \(delta)")
                    Task {
                        // Delta from ScrollCaptureView:
                        // Negative = swipe left/down = go back in time
                        // Positive = swipe right/up = go forward in time
                        // High sensitivity - pass delta directly (will be multiplied by secondsPerUnit in handleScrub)
                        await viewModel.handleScrub(delta: delta)
                    }
                }
                .allowsHitTesting(false)  // Don't block clicks
            )
            // Drag gesture disabled - using ScrollCaptureView for timeline navigation instead
            // The DragGesture was using cumulative translation which caused erratic behavior
            // Keyboard events are handled by the TimelineWindowController
        }
    }

    // MARK: - Timestamp Overlay

    private func timestampOverlay(frame: FrameReference) -> some View {
        VStack(alignment: .leading, spacing: .spacingS) {
            // Timestamp
            Text(formatTimestamp(frame.timestamp))
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            // App info
            if let appName = frame.metadata.appName {
                HStack(spacing: .spacingS) {
                    // App color indicator
                    Circle()
                        .fill(Color.sessionColor(for: frame.metadata.appBundleID ?? ""))
                        .frame(width: 12, height: 12)

                    Text(appName)
                        .font(.retraceBody)
                        .foregroundColor(.white.opacity(0.8))

                    // Window title if available
                    if let windowTitle = frame.metadata.windowTitle, !windowTitle.isEmpty {
                        Text("- \(windowTitle)")
                            .font(.retraceBody)
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.spacingM)
        .background(
            RoundedRectangle(cornerRadius: .cornerRadiusM)
                .fill(Color.black.opacity(0.6))
        )
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy  h:mm:ss a"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#if DEBUG
struct FullscreenTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        FullscreenTimelineView(
            coordinator: AppCoordinator(),
            onClose: {}
        )
        .frame(width: 1920, height: 1080)
        .preferredColorScheme(.dark)
    }
}
#endif
