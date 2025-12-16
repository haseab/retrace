import SwiftUI
import Shared

/// Horizontal scrollable timeline bar showing frames and sessions
public struct TimelineBar: View {

    // MARK: - Properties

    @ObservedObject var viewModel: TimelineViewModel
    let height: CGFloat = .timelineBarHeight

    @State private var scrollOffset: CGFloat = 0
    @State private var isDragging = false

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Time markers
            timeMarkers

            Divider()

            // Main timeline content
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        // Session indicators layer
                        sessionsLayer(width: geometry.size.width)

                        // Frame thumbnails layer
                        thumbnailsLayer(width: geometry.size.width)
                    }
                    .frame(minWidth: geometry.size.width)
                }
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            isDragging = true
                            scrollOffset = value.translation.width
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
            }
            .frame(height: height)
        }
        .background(Color.retraceSecondaryBackground)
    }

    // MARK: - Time Markers

    private var timeMarkers: some View {
        HStack {
            ForEach(timeLabels, id: \.self) { label in
                Text(label)
                    .font(.retraceCaption)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, .spacingM)
        .padding(.vertical, .spacingS)
    }

    private var timeLabels: [String] {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        switch viewModel.zoomLevel {
        case .hour:
            // Show 6 time markers across the hour
            return (0..<6).map { i in
                let offset = TimeInterval(i * 10 * 60) // Every 10 minutes
                return formatter.string(from: viewModel.currentDate.addingTimeInterval(offset - 1800))
            }

        case .day:
            // Show hourly markers
            return (0..<6).map { i in
                let offset = TimeInterval(i * 4 * 3600) // Every 4 hours
                return formatter.string(from: Calendar.current.startOfDay(for: viewModel.currentDate).addingTimeInterval(offset))
            }

        case .week:
            // Show daily markers
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return (0..<7).map { i in
                let calendar = Calendar.current
                let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: viewModel.currentDate))!
                return formatter.string(from: calendar.date(byAdding: .day, value: i, to: weekStart)!)
            }
        }
    }

    // MARK: - Sessions Layer

    private func sessionsLayer(width: CGFloat) -> some View {
        VStack(spacing: 2) {
            ForEach(viewModel.sessions) { session in
                SessionIndicator(
                    session: session,
                    width: sessionWidth(for: session, containerWidth: width),
                    isSelected: viewModel.selectedSession?.id == session.id
                ) {
                    viewModel.selectSession(session)
                }
                .offset(x: sessionOffset(for: session, containerWidth: width))
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Thumbnails Layer

    private func thumbnailsLayer(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(displayedFrames) { frame in
                FrameThumbnail(
                    frame: frame,
                    isSelected: viewModel.currentFrame?.id == frame.id
                ) {
                    Task {
                        await viewModel.selectFrame(frame)
                    }
                }
            }
        }
        .padding(.spacingS)
    }

    // MARK: - Frame Filtering

    private var displayedFrames: [FrameReference] {
        let interval = viewModel.zoomLevel.thumbnailInterval

        return viewModel.frames.enumerated().compactMap { index, frame in
            index % interval == 0 ? frame : nil
        }
    }

    // MARK: - Session Layout

    private func sessionWidth(for session: AppSession, containerWidth: CGFloat) -> CGFloat {
        let totalDuration = viewModel.frames.last?.timestamp.timeIntervalSince(
            viewModel.frames.first?.timestamp ?? Date()
        ) ?? 1

        let sessionDuration = (session.endTime ?? Date()).timeIntervalSince(session.startTime)
        let ratio = CGFloat(sessionDuration / totalDuration)

        return max(50, ratio * containerWidth)
    }

    private func sessionOffset(for session: AppSession, containerWidth: CGFloat) -> CGFloat {
        guard let firstFrame = viewModel.frames.first else { return 0 }

        let totalDuration = viewModel.frames.last?.timestamp.timeIntervalSince(firstFrame.timestamp) ?? 1
        let offsetDuration = session.startTime.timeIntervalSince(firstFrame.timestamp)
        let ratio = CGFloat(offsetDuration / totalDuration)

        return ratio * containerWidth
    }
}

// MARK: - Preview

#if DEBUG
struct TimelineBar_Previews: PreviewProvider {
    static var previews: some View {
        // Simplified preview - shows empty timeline bar
        // Full preview requires mock data injection which is complex
        Text("TimelineBar Preview")
            .frame(height: .timelineBarHeight + 40)
            .background(Color.retraceBackground)
            .preferredColorScheme(.dark)
    }
}
#endif
