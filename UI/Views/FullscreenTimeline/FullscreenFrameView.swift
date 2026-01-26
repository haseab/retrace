import SwiftUI
import Shared

/// Full-screen frame display component
/// Shows the captured screenshot at maximum resolution with smooth transitions
/// Supports both static images and video-based frames
public struct FullscreenFrameView: View {

    // MARK: - Properties

    let image: NSImage?
    let videoInfo: FrameVideoInfo?
    let frame: FrameReference?
    let isLoading: Bool

    @State private var displayedImage: NSImage?
    @State private var displayedVideoInfo: FrameVideoInfo?
    @State private var imageOpacity: Double = 1.0

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black

                // Video frame (for Rewind data)
                if let videoInfo = displayedVideoInfo {
                    VideoFrameView(videoInfo: videoInfo)
                        .frame(
                            maxWidth: geometry.size.width,
                            maxHeight: geometry.size.height - 100
                        )
                        .opacity(imageOpacity)
                }
                // Static image (for Retrace data)
                else if let image = displayedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: geometry.size.width,
                            maxHeight: geometry.size.height - 100 // Leave room for timeline bar
                        )
                        .opacity(imageOpacity)
                } else if isLoading {
                    loadingView
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: videoInfo) { newVideoInfo in
            Log.debug("[FullscreenFrameView] videoInfo changed: \(newVideoInfo?.videoPath ?? "nil")", category: .app)
            withAnimation(.easeInOut(duration: 0.1)) {
                displayedVideoInfo = newVideoInfo
                if newVideoInfo != nil {
                    displayedImage = nil // Clear image when showing video
                    Log.debug("[FullscreenFrameView] Cleared displayedImage, set displayedVideoInfo", category: .app)
                }
            }
        }
        .onChange(of: image) { newImage in
            // Smooth transition between frames
            withAnimation(.easeInOut(duration: 0.1)) {
                displayedImage = newImage
                if newImage != nil {
                    displayedVideoInfo = nil // Clear video when showing image
                }
            }
        }
        .onAppear {
            Log.debug("[FullscreenFrameView] onAppear - image: \(image != nil), videoInfo: \(videoInfo?.videoPath ?? "nil")", category: .app)
            displayedImage = image
            displayedVideoInfo = videoInfo
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: .spacingL) {
            SpinnerView(size: 32, lineWidth: 3, color: .white)

            Text("Loading frame...")
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: .spacingL) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.retraceDisplay)
                .foregroundColor(.white.opacity(0.3))

            VStack(spacing: .spacingS) {
                Text("No frames recorded yet")
                    .font(.retraceTitle3)
                    .foregroundColor(.white.opacity(0.8))

                Text("Start recording to capture your screen")
                    .font(.retraceBody)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FullscreenFrameView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Loading state
            FullscreenFrameView(
                image: nil,
                videoInfo: nil,
                frame: nil,
                isLoading: true
            )
            .background(Color.black)
            .previewDisplayName("Loading")

            // Empty state
            FullscreenFrameView(
                image: nil,
                videoInfo: nil,
                frame: nil,
                isLoading: false
            )
            .background(Color.black)
            .previewDisplayName("Empty")
        }
        .frame(width: 800, height: 600)
        .preferredColorScheme(.dark)
    }
}
#endif
