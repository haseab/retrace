import SwiftUI
import Shared
import App

/// Horizontal timeline bar for the full-screen overlay
/// Shows colored segments representing app sessions with scroll navigation
public struct FullscreenTimelineBar: View {

    // MARK: - Properties

    @ObservedObject var viewModel: LegacyTimelineViewModel
    let width: CGFloat

    @State private var isDragging = false
    @State private var dragStartPosition: CGFloat = 0
    @State private var currentScrollOffset: CGFloat = 0
    @State private var hoveredPosition: CGFloat? = nil

    private let barHeight: CGFloat = 60
    private let segmentHeight: CGFloat = 40
    private let playheadWidth: CGFloat = 3

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Time labels
            timeLabels

            // Main timeline bar
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color.black.opacity(0.8))

                // Session segments
                sessionsBar

                // Current position playhead
                playhead

                // Hover indicator
                if let hoverPos = hoveredPosition {
                    hoverIndicator(at: hoverPos)
                }
            }
            .frame(height: barHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDrag(value)
                    }
                    .onEnded { value in
                        handleDragEnd(value)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredPosition = location.x
                case .ended:
                    hoveredPosition = nil
                }
            }

            // Scroll hint
            scrollHint
        }
        .background(Color.black.opacity(0.9))
    }

    // MARK: - Time Labels

    private var timeLabels: some View {
        HStack(spacing: 0) {
            ForEach(Array(timeMarkers.enumerated()), id: \.offset) { index, marker in
                Text(formatTimeMarker(marker))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var timeMarkers: [Date] {
        guard !viewModel.frames.isEmpty else { return [] }

        let startDate = viewModel.frames.first?.timestamp ?? Date()
        let endDate = viewModel.frames.last?.timestamp ?? Date()
        let duration = endDate.timeIntervalSince(startDate)

        // Create 6 evenly spaced markers
        return (0..<6).map { i in
            startDate.addingTimeInterval(duration * Double(i) / 5.0)
        }
    }

    private func formatTimeMarker(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Sessions Bar

    private var sessionsBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.1))
                    .frame(height: segmentHeight)
                    .padding(.horizontal, .spacingM)

                // Colored segments for each session
                ForEach(viewModel.sessions) { session in
                    TimelineSegment(
                        session: session,
                        totalWidth: geometry.size.width - .spacingM * 2,
                        segmentHeight: segmentHeight,
                        timeRange: timeRange,
                        isSelected: viewModel.selectedSession?.id == session.id
                    )
                    .offset(x: segmentOffset(for: session, in: geometry.size.width - .spacingM * 2) + .spacingM)
                    .onTapGesture {
                        viewModel.selectSession(session)
                    }
                }
            }
            .frame(height: barHeight)
        }
    }

    private var timeRange: (start: Date, end: Date) {
        guard let first = viewModel.frames.first?.timestamp,
              let last = viewModel.frames.last?.timestamp else {
            return (Date(), Date())
        }
        return (first, last)
    }

    private func segmentOffset(for session: AppSession, in totalWidth: CGFloat) -> CGFloat {
        let (start, end) = timeRange
        let totalDuration = end.timeIntervalSince(start)
        guard totalDuration > 0 else { return 0 }

        let sessionStart = session.startTime.timeIntervalSince(start)
        return CGFloat(sessionStart / totalDuration) * totalWidth
    }

    // MARK: - Playhead

    private var playhead: some View {
        GeometryReader { geometry in
            ZStack {
                // Playhead line
                Rectangle()
                    .fill(Color.white)
                    .frame(width: playheadWidth, height: barHeight)
                    .position(x: playheadPosition(in: geometry.size.width), y: barHeight / 2)

                // Playhead handle (top)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(x: playheadPosition(in: geometry.size.width), y: 6)
            }
        }
    }

    private func playheadPosition(in totalWidth: CGFloat) -> CGFloat {
        guard let currentFrame = viewModel.currentFrame else {
            Log.debug("[TimelineBar] playheadPosition - no currentFrame", category: .app)
            return .spacingM
        }

        let (start, end) = timeRange
        let totalDuration = end.timeIntervalSince(start)
        guard totalDuration > 0 else {
            Log.debug("[TimelineBar] playheadPosition - zero duration", category: .app)
            return .spacingM
        }

        let currentOffset = currentFrame.timestamp.timeIntervalSince(start)
        let usableWidth = totalWidth - .spacingM * 2
        let position = CGFloat(currentOffset / totalDuration) * usableWidth + .spacingM
        Log.debug("[TimelineBar] playheadPosition - frame: \(currentFrame.timestamp), position: \(position)", category: .app)
        return position
    }

    // MARK: - Hover Indicator

    private func hoverIndicator(at x: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.3))
            .frame(width: 1, height: barHeight)
            .offset(x: x)
    }

    // MARK: - Scroll Hint

    private var scrollHint: some View {
        HStack(spacing: .spacingL) {
            HStack(spacing: .spacingS) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 10))
                Text("Scroll to go back")
                    .font(.system(size: 11))
            }
            .foregroundColor(.white.opacity(0.4))

            Spacer()

            // Current time display
            if let frame = viewModel.currentFrame {
                Text(formatCurrentTime(frame.timestamp))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            HStack(spacing: .spacingS) {
                Text("Scroll to go forward")
                    .font(.system(size: 11))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
            }
            .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, .spacingL)
        .padding(.vertical, .spacingS)
    }

    private func formatCurrentTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }

    // MARK: - Gesture Handling

    private func handleDrag(_ value: DragGesture.Value) {
        if !isDragging {
            isDragging = true
            dragStartPosition = value.location.x
        }

        // Calculate how far we've dragged and scrub the timeline
        let delta = value.location.x - dragStartPosition
        let scrubAmount = delta / width * 100 // Normalize to percentage

        Task {
            await viewModel.handleScrub(delta: -scrubAmount / 100000)
        }

        dragStartPosition = value.location.x
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        isDragging = false

        // If it was a tap (minimal movement), jump to that position
        if abs(value.translation.width) < 5 && abs(value.translation.height) < 5 {
            jumpToPosition(value.location.x)
        }
    }

    private func jumpToPosition(_ x: CGFloat) {
        let (start, end) = timeRange
        let totalDuration = end.timeIntervalSince(start)
        guard totalDuration > 0 else { return }

        let usableWidth = width - .spacingM * 2
        let normalizedX = (x - .spacingM) / usableWidth
        let targetTime = start.addingTimeInterval(totalDuration * Double(normalizedX))

        Task {
            await viewModel.jumpToTimestamp(targetTime)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FullscreenTimelineBar_Previews: PreviewProvider {
    static var previews: some View {
        FullscreenTimelineBar(
            viewModel: LegacyTimelineViewModel(coordinator: AppCoordinator()),
            width: 1200
        )
        .frame(width: 1200, height: 100)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
