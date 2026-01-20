import SwiftUI
import AVKit
import Shared

/// Displays a single frame from a video file using AVPlayer
/// Seeks to the exact frame and pauses - no extraction needed
struct VideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo

    func makeNSView(context: Context) -> AVPlayerView {
        Log.debug("[VideoFrameView] makeNSView called", category: .app)
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        Log.debug("[VideoFrameView] updateNSView - path: \(videoInfo.videoPath), frame: \(videoInfo.frameIndex), time: \(videoInfo.timeInSeconds)s", category: .app)

        // Create or reuse player
        let player: AVPlayer
        if let existingPlayer = playerView.player {
            Log.debug("[VideoFrameView] Reusing existing player", category: .app)
            player = existingPlayer
        } else {
            Log.debug("[VideoFrameView] Creating new player", category: .app)
            player = AVPlayer()
            player.actionAtItemEnd = .pause
            playerView.player = player
        }

        // Load video file
        Log.debug("[VideoFrameView] Loading video from: \(videoInfo.videoPath)", category: .app)

        // Check if file exists (try both with and without .mp4 extension)
        var actualVideoPath = videoInfo.videoPath
        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                Log.error("[VideoFrameView] Video file does not exist: \(videoInfo.videoPath)", category: .app)
                return
            }
        }

        // Determine the URL to use - if file already has .mp4 extension, use directly
        // Otherwise create symlink with .mp4 extension for AVFoundation
        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            // Rewind stores video files without extensions - AVPlayer requires .mp4 extension
            // Create a symlink with .mp4 extension in temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = (actualVideoPath as NSString).lastPathComponent
            let symlinkPath = tempDir.appendingPathComponent("\(fileName).mp4").path

            // Remove old symlink if it exists
            if FileManager.default.fileExists(atPath: symlinkPath) {
                try? FileManager.default.removeItem(atPath: symlinkPath)
            }

            // Create symlink
            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                Log.debug("[VideoFrameView] Created symlink: \(symlinkPath)", category: .app)
            } catch {
                Log.error("[VideoFrameView] Failed to create symlink: \(error)", category: .app)
                return
            }
            url = URL(fileURLWithPath: symlinkPath)
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)

        // Replace current item
        player.replaceCurrentItem(with: playerItem)
        Log.debug("[VideoFrameView] Replaced player item", category: .app)

        // Wait for item to be ready, then seek to frame
        let observer = playerItem.observe(\.status, options: [.new, .initial]) { item, change in
            Log.debug("[VideoFrameView] Player item status changed: \(item.status.rawValue) (0=unknown, 1=ready, 2=failed)", category: .app)

            if item.status == .failed {
                if let error = item.error {
                    Log.error("[VideoFrameView] Player item failed: \(error.localizedDescription)", category: .app)
                } else {
                    Log.error("[VideoFrameView] Player item failed with unknown error", category: .app)
                }
                return
            }

            guard item.status == .readyToPlay else { return }

            Log.debug("[VideoFrameView] Player ready, seeking to frame \(videoInfo.frameIndex)", category: .app)

            // Seek to exact frame using integer arithmetic to avoid floating point precision issues
            let time = videoInfo.frameTimeCMTime
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Log.debug("[VideoFrameView] Seek completed, finished: \(finished)", category: .app)
                // Pause at this frame
                player.pause()
                Log.debug("[VideoFrameView] Player paused at frame \(videoInfo.frameIndex)", category: .app)
            }
        }

        // Store observer to prevent deallocation
        context.coordinator.observers.append(observer)
        Log.debug("[VideoFrameView] Observer added, total observers: \(context.coordinator.observers.count)", category: .app)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var observers: [NSKeyValueObservation] = []

        deinit {
            observers.forEach { $0.invalidate() }
            Log.debug("[VideoFrameView.Coordinator] Deinit, invalidating \(observers.count) observers", category: .app)
        }
    }
}
