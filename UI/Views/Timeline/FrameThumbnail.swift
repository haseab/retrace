import SwiftUI
import Shared

/// Thumbnail preview of a captured frame in the timeline
public struct FrameThumbnail: View {

    // MARK: - Properties

    let frame: FrameReference
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnailImage: NSImage?
    @State private var isHovered = false
    @State private var isLoading = false

    private let size: CGFloat = .thumbnailSize

    // MARK: - Initialization

    public init(
        frame: FrameReference,
        isSelected: Bool = false,
        onTap: @escaping () -> Void = {}
    ) {
        self.frame = frame
        self.isSelected = isSelected
        self.onTap = onTap
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 4) {
            // Thumbnail image
            thumbnailView
                .frame(width: size, height: size * 0.75)
                .background(Color.retraceCard)
                .cornerRadius(.cornerRadiusM)
                .overlay(
                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                        .stroke(borderColor, lineWidth: borderWidth)
                )
                .shadow(
                    color: isSelected ? Color.retraceAccent.opacity(0.5) : .clear,
                    radius: 4,
                    x: 0,
                    y: 2
                )

            // Timestamp label
            Text(formatTime(frame.timestamp))
                .font(.retraceCaption2)
                .foregroundColor(isSelected ? .retraceAccent : .retraceSecondary)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
        }
        .onAppear {
            loadThumbnail()
        }
    }

    // MARK: - Thumbnail View

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = thumbnailImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size * 0.75)
                .clipped()
        } else if isLoading {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: size, height: size * 0.75)
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(Color.retraceCard)

            VStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(.retraceSecondary)

                if let appName = frame.metadata.appName {
                    Text(appName)
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary)
                }
            }
        }
    }

    // MARK: - Styling

    private var borderColor: Color {
        if isSelected {
            return .retraceAccent
        } else if isHovered {
            return .retraceBorder
        } else {
            return .clear
        }
    }

    private var borderWidth: CGFloat {
        if isSelected {
            return 2
        } else if isHovered {
            return 1
        } else {
            return 0
        }
    }

    // MARK: - Data Loading

    private func loadThumbnail() {
        // TODO: Load actual thumbnail from storage
        // For now, just show placeholder
        isLoading = false

        // Simulate loading delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // In real implementation, this would load from:
            // coordinator.getFrameImage(segmentID: frame.segmentID, frameIndex: frame.frameIndexInSegment)
            isLoading = false
        }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#if DEBUG
struct FrameThumbnail_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: .spacingM) {
            // Normal thumbnail
            FrameThumbnail(
                frame: FrameReference(
                    id: FrameID(value: UUID()),
                    timestamp: Date(),
                    segmentID: SegmentID(value: UUID()),
                    frameIndexInSegment: 0,
                    metadata: FrameMetadata(
                        appBundleID: "com.google.Chrome",
                        appName: "Chrome",
                        windowTitle: "GitHub",
                        browserURL: "https://github.com",
                        displayID: 0
                    ),
                    source: .native
                ),
                isSelected: false
            )

            // Selected thumbnail
            FrameThumbnail(
                frame: FrameReference(
                    id: FrameID(value: UUID()),
                    timestamp: Date().addingTimeInterval(300),
                    segmentID: SegmentID(value: UUID()),
                    frameIndexInSegment: 1,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.dt.Xcode",
                        appName: "Xcode",
                        windowTitle: nil,
                        browserURL: nil,
                        displayID: 0
                    ),
                    source: .native
                ),
                isSelected: true
            )

            // Loading thumbnail
            FrameThumbnail(
                frame: FrameReference(
                    id: FrameID(value: UUID()),
                    timestamp: Date().addingTimeInterval(600),
                    segmentID: SegmentID(value: UUID()),
                    frameIndexInSegment: 2,
                    metadata: FrameMetadata(
                        appBundleID: "com.tinyspeck.slackmacgap",
                        appName: "Slack",
                        windowTitle: nil,
                        browserURL: nil,
                        displayID: 0
                    ),
                    source: .native
                ),
                isSelected: false
            )
        }
        .padding()
        .background(Color.retraceBackground)
        .preferredColorScheme(.dark)
    }
}
#endif
