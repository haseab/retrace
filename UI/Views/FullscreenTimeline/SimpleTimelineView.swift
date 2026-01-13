import SwiftUI
import AVKit
import Shared
import App

/// Redesigned fullscreen timeline view with scrolling tape and fixed playhead
/// The timeline tape moves left/right while the playhead stays fixed in center
public struct SimpleTimelineView: View {

    // MARK: - Properties

    @ObservedObject private var viewModel: SimpleTimelineViewModel
    @State private var hasInitialized = false

    let coordinator: AppCoordinator
    let onClose: () -> Void

    // MARK: - Initialization

    /// Initialize with an external view model (scroll events handled by TimelineWindowController)
    public init(coordinator: AppCoordinator, viewModel: SimpleTimelineViewModel, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.viewModel = viewModel
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Full screen frame display
                frameDisplay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Timeline tape overlay at bottom
                VStack {
                    Spacer()
                    TimelineTapeView(
                        viewModel: viewModel,
                        width: geometry.size.width
                    )
                }

                // Close button (top-right)
                VStack {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    Spacer()
                }
                .padding(.spacingL)

                // App info overlay (top-left) - timestamp now on playhead
                VStack {
                    HStack {
                        appInfoOverlay
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.spacingL)

                // Loading overlay
                if viewModel.isLoading {
                    loadingOverlay
                }

                // Error overlay
                if let error = viewModel.error {
                    errorOverlay(error)
                }
            }
            .background(Color.black)
            .ignoresSafeArea()
            .onAppear {
                if !hasInitialized {
                    hasInitialized = true
                    Task {
                        await viewModel.loadMostRecentFrame()
                    }
                }
            }
            // Note: Scroll events are now captured by TimelineWindowController
            // at the window level for more reliable event handling
        }
    }

    // MARK: - Frame Display

    @ViewBuilder
    private var frameDisplay: some View {
        let _ = print("[View] frameDisplay evaluated, currentIndex=\(viewModel.currentIndex)")
        if let videoInfo = viewModel.currentVideoInfo {
            // Video-based frame (Rewind)
            let _ = print("[View] Creating SimpleVideoFrameView with frameIndex=\(videoInfo.frameIndex)")
            SimpleVideoFrameView(videoInfo: videoInfo)
        } else if let image = viewModel.currentImage {
            // Static image (Retrace)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if !viewModel.isLoading {
            // Empty state
            VStack(spacing: .spacingM) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundColor(.white.opacity(0.3))
                Text("No frames recorded")
                    .font(.retraceBody)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Info Overlay

    private var appInfoOverlay: some View {
        Group {
            if let frame = viewModel.currentFrame, let appName = frame.metadata.appName {
                HStack(spacing: .spacingS) {
                    Circle()
                        .fill(Color.sessionColor(for: frame.metadata.appBundleID ?? ""))
                        .frame(width: 10, height: 10)
                    Text(appName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: .cornerRadiusM)
                        .fill(Color.black.opacity(0.5))
                )
            }
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        VStack(spacing: .spacingM) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: .spacingM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.retraceWarning)
            Text(message)
                .font(.retraceBody)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(.spacingL)
        .background(
            RoundedRectangle(cornerRadius: .cornerRadiusM)
                .fill(Color.black.opacity(0.8))
        )
    }
}

// MARK: - Simple Video Frame View

/// Simplified video frame view using AVPlayer
/// Optimized to only reload video when path changes, just seek when frame changes
struct SimpleVideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false

        // Create player immediately
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        playerView.player = player

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        guard let player = playerView.player else { return }

        let currentPath = context.coordinator.currentVideoPath
        let currentFrameIdx = context.coordinator.currentFrameIndex

        print("[VideoView] updateNSView: frameIndex=\(videoInfo.frameIndex), coordFrameIdx=\(currentFrameIdx ?? -1)")

        // If same video and same frame, nothing to do
        if currentPath == videoInfo.videoPath && currentFrameIdx == videoInfo.frameIndex {
            print("[VideoView] Same video and frame, skipping")
            return
        }

        // Update coordinator state
        context.coordinator.currentFrameIndex = videoInfo.frameIndex

        // If same video, just seek (fast path - no flickering)
        if currentPath == videoInfo.videoPath {
            print("[VideoView] Same video, SEEKING to frame \(videoInfo.frameIndex)")
            let time = CMTime(seconds: videoInfo.timeInSeconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }

        print("[VideoView] LOADING NEW VIDEO: \(videoInfo.videoPath.suffix(30))")

        // Different video - need to load new player item
        context.coordinator.currentVideoPath = videoInfo.videoPath

        // Check if file exists
        guard FileManager.default.fileExists(atPath: videoInfo.videoPath) else {
            Log.error("[SimpleVideoFrameView] Video file not found: \(videoInfo.videoPath)", category: .app)
            return
        }

        // Create symlink with .mp4 extension (Rewind videos don't have extensions)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = (videoInfo.videoPath as NSString).lastPathComponent
        let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

        // Only create symlink if it doesn't exist
        if !FileManager.default.fileExists(atPath: symlinkPath) {
            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: videoInfo.videoPath)
            } catch {
                Log.error("[SimpleVideoFrameView] Failed to create symlink: \(error)", category: .app)
                return
            }
        }

        // Load new video
        let url = URL(fileURLWithPath: symlinkPath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        // Clear old observers
        context.coordinator.observers.forEach { $0.invalidate() }
        context.coordinator.observers.removeAll()

        player.replaceCurrentItem(with: playerItem)

        // Seek to frame when ready
        let targetTime = videoInfo.timeInSeconds
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { item, _ in
            guard item.status == .readyToPlay else { return }

            let time = CMTime(seconds: targetTime, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.pause()
            }
        }

        context.coordinator.observers.append(observer)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var observers: [NSKeyValueObservation] = []
        var currentVideoPath: String?
        var currentFrameIndex: Int?

        deinit {
            observers.forEach { $0.invalidate() }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SimpleTimelineView_Previews: PreviewProvider {
    static var previews: some View {
        let coordinator = AppCoordinator()
        SimpleTimelineView(
            coordinator: coordinator,
            viewModel: SimpleTimelineViewModel(coordinator: coordinator),
            onClose: {}
        )
        .frame(width: 1920, height: 1080)
    }
}
#endif
