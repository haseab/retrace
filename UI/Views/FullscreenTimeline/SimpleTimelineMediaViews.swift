import Foundation
import SwiftUI
import AVKit
import Shared

struct ResetZoomButton: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        Button(action: {
            viewModel.resetFrameZoom()
        }) {
            HStack(spacing: 10 * scale) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18 * scale, weight: .semibold))
                Text("Reset Zoom")
                    .font(.system(size: 17 * scale, weight: .medium))
            }
            .foregroundColor(isHovering ? .white : .white.opacity(0.8))
            .padding(.horizontal, 20 * scale)
            .padding(.vertical, 12 * scale)
            .background(
                Capsule()
                    .fill(Color.black.opacity(isHovering ? 0.7 : 0.5))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Reset zoom to \(TimelineZoomSettings.resetLabel) (Cmd+0)")
    }
}

struct PeekModeBanner: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel
    @State private var isHovering = false

    private var scale: CGFloat { TimelineScaleFactor.current }

    var body: some View {
        HStack(spacing: 12 * scale) {
            Image(systemName: "eye.fill")
                .font(.system(size: 16 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

            Text("Viewing full timeline")
                .font(.system(size: 15 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.9))

            Rectangle()
                .fill(Color.white.opacity(0.3))
                .frame(width: 1, height: 16 * scale)

            Button(action: {
                viewModel.exitPeek()
            }) {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13 * scale, weight: .semibold))
                    Text("Return to filtered view")
                        .font(.system(size: 14 * scale, weight: .medium))
                }
                .foregroundColor(isHovering ? .white : .white.opacity(0.85))
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 6 * scale)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isHovering ? 0.25 : 0.15))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            Text("Esc")
                .font(.system(size: 11 * scale, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 3 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 4 * scale)
                        .fill(Color.white.opacity(0.1))
                )
        }
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 10 * scale)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

struct VideoSeekDebugContext {
    let frameID: Int64
    let timestamp: Date
    let currentIndex: Int
    let frameBundleID: String?
    let hasActiveFilters: Bool
    let selectedApps: [String]
    let filteredFrameIndicesForVideo: Set<Int>

    var selectedAppsLabel: String {
        selectedApps.isEmpty ? "none" : selectedApps.joined(separator: ",")
    }

    func containsFilteredFrameIndex(_ frameIndex: Int) -> Bool {
        guard frameIndex >= 0 else { return false }
        return filteredFrameIndicesForVideo.contains(frameIndex)
    }

    func nearestFilteredFrameIndices(around frameIndex: Int, limit: Int = 6) -> String {
        guard !filteredFrameIndicesForVideo.isEmpty else { return "none" }
        let nearest = filteredFrameIndicesForVideo
            .sorted { lhs, rhs in
                abs(lhs - frameIndex) < abs(rhs - frameIndex)
            }
            .prefix(limit)
            .sorted()
        return nearest.map(String.init).joined(separator: ",")
    }
}

struct SimpleVideoFrameView: NSViewRepresentable {
    let videoInfo: FrameVideoInfo
    let debugContext: VideoSeekDebugContext?
    @Binding var forceReload: Bool
    var onLoadFailed: (() -> Void)?
    var onLoadSuccess: (() -> Void)?

    func makeNSView(context: Context) -> DoubleBufferedVideoView {
        let containerView = DoubleBufferedVideoView()
        containerView.onLoadFailed = onLoadFailed
        containerView.onLoadSuccess = onLoadSuccess
        return containerView
    }

    func updateNSView(_ containerView: DoubleBufferedVideoView, context: Context) {
        containerView.onLoadFailed = onLoadFailed
        containerView.onLoadSuccess = onLoadSuccess

        if let debugContext, debugContext.hasActiveFilters {
            Log.debug(
                "[FILTER-VIDEO] renderRequest frameID=\(debugContext.frameID) idx=\(debugContext.currentIndex) ts=\(debugContext.timestamp) bundle=\(debugContext.frameBundleID ?? "nil") selectedApps=[\(debugContext.selectedAppsLabel)] targetVideoFrame=\(videoInfo.frameIndex) videoPathSuffix=\(videoInfo.videoPath.suffix(40))",
                category: .ui
            )
        }

        let isWindowVisible = containerView.window?.isVisible ?? false
        let needsForceReload = forceReload

        if needsForceReload {
            context.coordinator.currentVideoPath = nil
            context.coordinator.currentFrameIndex = nil
            DispatchQueue.main.async {
                self.forceReload = false
            }
        }

        let effectivePath = context.coordinator.currentVideoPath
        let effectiveFrameIdx = context.coordinator.currentFrameIndex

        if effectivePath == videoInfo.videoPath && effectiveFrameIdx == videoInfo.frameIndex {
            DispatchQueue.main.async {
                self.onLoadSuccess?()
            }
            return
        }

        if isWindowVisible {
            context.coordinator.currentFrameIndex = videoInfo.frameIndex
        }

        if effectivePath == videoInfo.videoPath {
            let time = videoInfo.frameTimeCMTime
            containerView.seekActivePlayer(
                to: time,
                expectedFrameIndex: videoInfo.frameIndex,
                frameRate: videoInfo.frameRate,
                debugContext: debugContext
            )
            return
        }

        context.coordinator.currentVideoPath = videoInfo.videoPath

        var actualVideoPath = videoInfo.videoPath

        if !FileManager.default.fileExists(atPath: actualVideoPath) {
            let pathWithExtension = actualVideoPath + ".mp4"
            if FileManager.default.fileExists(atPath: pathWithExtension) {
                actualVideoPath = pathWithExtension
            } else {
                return
            }
        }

        let url: URL
        if actualVideoPath.hasSuffix(".mp4") {
            url = URL(fileURLWithPath: actualVideoPath)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            let symlinkPath = tempDir.appendingPathComponent("\(UUID().uuidString).mp4").path

            do {
                try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: actualVideoPath)
                context.coordinator.trackSymlink(symlinkPath)
            } catch {
                Log.error("[SimpleVideoFrameView] Failed to create symlink: \(error)", category: .app)
                return
            }
            url = URL(fileURLWithPath: symlinkPath)
        }

        let targetTime = videoInfo.frameTimeCMTime
        let targetFrameIndex = videoInfo.frameIndex
        containerView.loadVideoIntoBuffer(
            url: url,
            seekTime: targetTime,
            frameIndex: targetFrameIndex,
            frameRate: videoInfo.frameRate,
            debugContext: debugContext
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: DoubleBufferedVideoView, coordinator: Coordinator) {
        nsView.releaseDecoderResources(reason: "SimpleVideoFrameView dismantled")
        coordinator.cleanupSymlinks()
    }

    class Coordinator {
        var currentVideoPath: String?
        var currentFrameIndex: Int?
        private var symlinkPaths: Set<String> = []

        func trackSymlink(_ path: String) {
            symlinkPaths.insert(path)
        }

        func cleanupSymlinks() {
            for path in symlinkPaths {
                try? FileManager.default.removeItem(atPath: path)
            }
            symlinkPaths.removeAll()
        }
    }
}

class DoubleBufferedVideoView: NSView {
    private var playerViewA: AVPlayerView!
    private var playerViewB: AVPlayerView!
    private var playerA: AVPlayer!
    private var playerB: AVPlayer!

    private var isPlayerAActive = true

    private var observerA: NSKeyValueObservation?
    private var observerB: NSKeyValueObservation?

    private var loadGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0

    private static let isFilteredSeekDiagnosticsEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return (UserDefaults(suiteName: "io.retrace.app") ?? .standard)
            .bool(forKey: "retrace.debug.filteredSeekDiagnostics")
        #endif
    }()

    var onLoadFailed: (() -> Void)?
    var onLoadSuccess: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupPlayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayers()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            releaseDecoderResources(reason: "view removed from window")
        }
    }

    private func setupPlayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerViewA = createPlayerView()
        playerA = AVPlayer()
        playerA.actionAtItemEnd = .pause
        playerA.automaticallyWaitsToMinimizeStalling = false
        playerViewA.player = playerA

        playerViewB = createPlayerView()
        playerB = AVPlayer()
        playerB.actionAtItemEnd = .pause
        playerB.automaticallyWaitsToMinimizeStalling = false
        playerViewB.player = playerB

        addSubview(playerViewA)
        addSubview(playerViewB)

        playerViewA.isHidden = false
        playerViewB.isHidden = true

        setupConstraints(for: playerViewA)
        setupConstraints(for: playerViewB)
    }

    private func createPlayerView() -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFrameSteppingButtons = false
        playerView.showsSharingServiceButton = false
        playerView.showsFullScreenToggleButton = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        if #available(macOS 13.0, *) {
            playerView.allowsVideoFrameAnalysis = false
        }

        return playerView
    }

    private func setupConstraints(for playerView: AVPlayerView) {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func ensurePlayersReady() {
        if playerViewA == nil || playerViewB == nil {
            setupPlayers()
            return
        }

        if playerA == nil {
            let player = AVPlayer()
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            playerA = player
            playerViewA.player = player
        } else if playerViewA.player == nil {
            playerViewA.player = playerA
        }

        if playerB == nil {
            let player = AVPlayer()
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            playerB = player
            playerViewB.player = player
        } else if playerViewB.player == nil {
            playerViewB.player = playerB
        }

        playerViewA.isHidden = !isPlayerAActive
        playerViewB.isHidden = isPlayerAActive
    }

    func seekActivePlayer(
        to time: CMTime,
        expectedFrameIndex: Int,
        frameRate: Double,
        debugContext: VideoSeekDebugContext?
    ) {
        ensurePlayersReady()
        seekGeneration &+= 1
        let currentSeekGeneration = seekGeneration
        let tolerance = seekTolerance(for: frameRate)
        let toleranceFrames = configuredSeekToleranceFrames()
        let activePlayer = isPlayerAActive ? playerA : playerB

        activePlayer?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak activePlayer] finished in
            guard let self = self else { return }

            guard finished else {
                if self.shouldLogSeekDiagnostics(for: debugContext) {
                    Log.debug(
                        "[FILTER-VIDEO] seekCancelled path=same-video expectedFrame=\(expectedFrameIndex) toleranceFrames=\(toleranceFrames)",
                        category: .ui
                    )
                }
                return
            }

            guard currentSeekGeneration == self.seekGeneration else {
                if self.shouldLogSeekDiagnostics(for: debugContext) {
                    Log.debug(
                        "[FILTER-VIDEO] seekStale path=same-video expectedFrame=\(expectedFrameIndex) finishedGeneration=\(currentSeekGeneration) currentGeneration=\(self.seekGeneration)",
                        category: .ui
                    )
                }
                return
            }

            let actualTime = activePlayer?.currentTime() ?? .zero
            let actualFrameIndex = Self.frameIndex(for: actualTime, frameRate: frameRate)
            self.logSeekResult(
                phase: "same-video",
                expectedFrameIndex: expectedFrameIndex,
                actualFrameIndex: actualFrameIndex,
                frameRate: frameRate,
                toleranceFrames: toleranceFrames,
                debugContext: debugContext
            )

            DispatchQueue.main.async {
                self.onLoadSuccess?()
            }
        }
    }

    func loadVideoIntoBuffer(
        url: URL,
        seekTime: CMTime,
        frameIndex: Int,
        frameRate: Double,
        debugContext: VideoSeekDebugContext?
    ) {
        ensurePlayersReady()

        loadGeneration &+= 1
        let currentGeneration = loadGeneration

        let bufferPlayer = isPlayerAActive ? playerB : playerA
        let bufferObserver = isPlayerAActive ? observerB : observerA
        let expectedActiveAfterSwap = !isPlayerAActive

        bufferObserver?.invalidate()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0

        clearCurrentItem(for: bufferPlayer)
        bufferPlayer?.replaceCurrentItem(with: playerItem)
        let tolerance = seekTolerance(for: frameRate)
        let toleranceFrames = configuredSeekToleranceFrames()

        let observer = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self = self else { return }

            guard currentGeneration == self.loadGeneration else {
                Log.debug("[VideoView] Ignoring stale status callback gen=\(currentGeneration), current=\(self.loadGeneration)", category: .ui)
                return
            }

            if item.status == .failed {
                if self.shouldLogSeekDiagnostics(for: debugContext) {
                    Log.warning(
                        "[FILTER-VIDEO] bufferLoadFailed expectedFrame=\(frameIndex) toleranceFrames=\(toleranceFrames)",
                        category: .ui
                    )
                }
                DispatchQueue.main.async {
                    self.onLoadFailed?()
                }
                return
            }

            guard item.status == .readyToPlay else { return }

            bufferPlayer?.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                guard let self = self else { return }

                guard finished else {
                    if self.shouldLogSeekDiagnostics(for: debugContext) {
                        Log.debug(
                            "[FILTER-VIDEO] seekCancelled path=buffer expectedFrame=\(frameIndex) toleranceFrames=\(toleranceFrames)",
                            category: .ui
                        )
                    }
                    return
                }

                guard currentGeneration == self.loadGeneration else { return }

                let actualTime = bufferPlayer?.currentTime() ?? .zero
                let actualFrameIndex = Self.frameIndex(for: actualTime, frameRate: frameRate)
                self.logSeekResult(
                    phase: "buffer",
                    expectedFrameIndex: frameIndex,
                    actualFrameIndex: actualFrameIndex,
                    frameRate: frameRate,
                    toleranceFrames: toleranceFrames,
                    debugContext: debugContext
                )

                DispatchQueue.main.async {
                    guard currentGeneration == self.loadGeneration else { return }
                    guard self.isPlayerAActive != expectedActiveAfterSwap else { return }

                    bufferPlayer?.pause()
                    self.swapPlayers()
                    self.onLoadSuccess?()
                }
            }
        }

        if isPlayerAActive {
            observerB = observer
        } else {
            observerA = observer
        }
    }

    func releaseDecoderResources(reason: String) {
        loadGeneration &+= 1
        seekGeneration &+= 1

        observerA?.invalidate()
        observerA = nil
        observerB?.invalidate()
        observerB = nil

        release(player: playerA, playerView: playerViewA)
        release(player: playerB, playerView: playerViewB)
        playerA = nil
        playerB = nil

        isPlayerAActive = true
        playerViewA?.isHidden = false
        playerViewB?.isHidden = true
    }

    private func release(player: AVPlayer?, playerView: AVPlayerView?) {
        guard let player else {
            playerView?.player = nil
            return
        }

        clearCurrentItem(for: player)
        playerView?.player = nil
    }

    private func clearCurrentItem(for player: AVPlayer?) {
        guard let player else { return }
        player.pause()
        player.cancelPendingPrerolls()
        if let item = player.currentItem {
            item.cancelPendingSeeks()
            item.asset.cancelLoading()
        }
        player.replaceCurrentItem(with: nil)
    }

    private func configuredSeekToleranceFrames() -> Int {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if let value = defaults.object(forKey: "retrace.debug.timelineSeekToleranceFrames") as? NSNumber {
            return max(0, value.intValue)
        }
        return 1
    }

    private func seekTolerance(for frameRate: Double) -> CMTime {
        let toleranceFrames = configuredSeekToleranceFrames()
        guard toleranceFrames > 0 else { return .zero }
        let fps = frameRate > 0 ? frameRate : 30.0
        return CMTime(seconds: Double(toleranceFrames) / fps, preferredTimescale: 600)
    }

    private static func frameIndex(for time: CMTime, frameRate: Double) -> Int {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return -1 }
        let fps = frameRate > 0 ? frameRate : 30.0
        return Int((seconds * fps).rounded())
    }

    private func shouldLogSeekDiagnostics(for debugContext: VideoSeekDebugContext?) -> Bool {
        Self.isFilteredSeekDiagnosticsEnabled && (debugContext?.hasActiveFilters ?? false)
    }

    private func logSeekResult(
        phase: String,
        expectedFrameIndex: Int,
        actualFrameIndex: Int,
        frameRate: Double,
        toleranceFrames: Int,
        debugContext: VideoSeekDebugContext?
    ) {
        guard shouldLogSeekDiagnostics(for: debugContext), let debugContext else { return }

        let expectedInFilteredSet = debugContext.containsFilteredFrameIndex(expectedFrameIndex)
        let actualInFilteredSet = debugContext.containsFilteredFrameIndex(actualFrameIndex)
        let mismatch = actualFrameIndex != expectedFrameIndex
        let unexpectedFilteredFrame = !actualInFilteredSet
        let nearestFiltered = debugContext.nearestFilteredFrameIndices(around: actualFrameIndex)
        let level = (mismatch || unexpectedFilteredFrame) ? "warning" : "debug"

        let message =
            "[FILTER-VIDEO] seekResult phase=\(phase) level=\(level) frameID=\(debugContext.frameID) idx=\(debugContext.currentIndex) ts=\(debugContext.timestamp) " +
            "bundle=\(debugContext.frameBundleID ?? "nil") selectedApps=[\(debugContext.selectedAppsLabel)] " +
            "expectedFrame=\(expectedFrameIndex) actualFrame=\(actualFrameIndex) expectedInFilteredSet=\(expectedInFilteredSet) actualInFilteredSet=\(actualInFilteredSet) " +
            "nearestFiltered=[\(nearestFiltered)] frameRate=\(String(format: "%.3f", frameRate)) toleranceFrames=\(toleranceFrames)"

        if mismatch || unexpectedFilteredFrame {
            Log.warning(message, category: .ui)
        } else {
            Log.debug(message, category: .ui)
        }
    }

    private func swapPlayers() {
        let activePlayerView = isPlayerAActive ? playerViewA : playerViewB
        let bufferPlayerView = isPlayerAActive ? playerViewB : playerViewA
        let oldActivePlayer = isPlayerAActive ? playerA : playerB

        bufferPlayerView?.isHidden = false
        activePlayerView?.isHidden = true
        clearCurrentItem(for: oldActivePlayer)
        isPlayerAActive.toggle()
    }

    deinit {
        releaseDecoderResources(reason: "DoubleBufferedVideoView deinit")
    }
}
