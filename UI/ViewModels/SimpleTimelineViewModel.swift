import SwiftUI
import Combine
import AVFoundation
import Shared
import App

/// A frame paired with its preloaded video info for instant access
public struct TimelineFrame: Identifiable, Equatable {
    public let frame: FrameReference
    public let videoInfo: FrameVideoInfo?

    public var id: FrameID { frame.id }

    public static func == (lhs: TimelineFrame, rhs: TimelineFrame) -> Bool {
        lhs.frame.id == rhs.frame.id
    }
}

/// Represents a block of consecutive frames from the same app
public struct AppBlock: Identifiable {
    public let id = UUID()
    public let bundleID: String?
    public let appName: String?
    public let startIndex: Int
    public let endIndex: Int
    public let frameCount: Int

    public var width: CGFloat {
        CGFloat(frameCount) * 14.0 // 8px per frame
    }
}

/// Simple ViewModel for the redesigned fullscreen timeline view
/// All state derives from currentIndex - this is the SINGLE source of truth
@MainActor
public class SimpleTimelineViewModel: ObservableObject {

    // MARK: - Published State

    /// All loaded frames with their preloaded video info
    @Published public var frames: [TimelineFrame] = [] {
        didSet {
            // Clear cached blocks when frames change
            _cachedAppBlocks = nil
        }
    }

    /// Current index in the frames array - THE SINGLE SOURCE OF TRUTH
    /// Everything else (currentFrame, currentVideoInfo, currentTimestamp) derives from this
    @Published public var currentIndex: Int = 0 {
        didSet {
            if currentIndex != oldValue {
                print("[SimpleTimelineViewModel] currentIndex changed: \(oldValue) -> \(currentIndex)")
                if let frame = currentTimelineFrame {
                    print("[SimpleTimelineViewModel] New frame: timestamp=\(frame.frame.timestamp), frameIndex=\(frame.videoInfo?.frameIndex ?? -1)")
                }
            }
        }
    }

    /// Static image for displaying the current frame (for image-based sources like Retrace)
    @Published public var currentImage: NSImage?

    /// Loading state
    @Published public var isLoading = false

    /// Error message if something goes wrong
    @Published public var error: String?

    // MARK: - Derived Properties (computed from currentIndex)

    /// Current timeline frame (frame + video info) - derived from currentIndex
    public var currentTimelineFrame: TimelineFrame? {
        guard currentIndex >= 0 && currentIndex < frames.count else { return nil }
        return frames[currentIndex]
    }

    /// Current frame reference - derived from currentIndex
    public var currentFrame: FrameReference? {
        currentTimelineFrame?.frame
    }

    /// Video info for displaying the current frame - derived from currentIndex
    public var currentVideoInfo: FrameVideoInfo? {
        let info = currentTimelineFrame?.videoInfo
        // Log every time this is accessed to see what SwiftUI is getting
        print("[VM] currentVideoInfo accessed: index=\(currentIndex), videoFrameIndex=\(info?.frameIndex ?? -999), path=\(info?.videoPath.suffix(20) ?? "nil")")
        return info
    }

    /// Current timestamp - ALWAYS derived from the current frame
    public var currentTimestamp: Date? {
        currentTimelineFrame?.frame.timestamp
    }

    // MARK: - Computed Properties for Timeline Tape

    /// Cached app blocks - only recomputed when frames change
    private var _cachedAppBlocks: [AppBlock]?

    /// App blocks grouped by consecutive bundle IDs
    public var appBlocks: [AppBlock] {
        if let cached = _cachedAppBlocks {
            return cached
        }

        let blocks = groupFramesIntoBlocks()
        _cachedAppBlocks = blocks
        return blocks
    }

    // MARK: - Private State

    /// Scroll accumulator for smooth scrolling
    private var scrollAccumulator: CGFloat = 0

    /// Cache for Retrace images (loaded on demand since they're from disk)
    private var imageCache: [FrameID: NSImage] = [:]

    // MARK: - Dependencies

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Initial Load

    /// Load the most recent frame on startup
    public func loadMostRecentFrame() async {
        isLoading = true
        error = nil

        do {
            // Get the most recent frame timestamp from any source
            guard let mostRecentTimestamp = try await coordinator.getMostRecentFrameTimestamp() else {
                error = "No frames found in any database"
                isLoading = false
                return
            }

            // Load frames around the most recent timestamp
            let endDate = mostRecentTimestamp
            let startDate = Calendar.current.date(byAdding: .hour, value: -1, to: endDate)!

            let rawFrames = try await coordinator.getFrames(from: startDate, to: endDate, limit: 500)

            guard !rawFrames.isEmpty else {
                error = "No frames found in time range"
                isLoading = false
                return
            }

            // Preload video info for ALL frames upfront
            var timelineFrames: [TimelineFrame] = []
            for frame in rawFrames {
                let videoInfo = try? await coordinator.getFrameVideoInfo(
                    segmentID: frame.segmentID,
                    timestamp: frame.timestamp,
                    source: frame.source
                )
                timelineFrames.append(TimelineFrame(frame: frame, videoInfo: videoInfo))
            }

            frames = timelineFrames

            // Start at the most recent frame (last in array since sorted ascending)
            currentIndex = frames.count - 1

            // Load image if needed for current frame
            loadImageIfNeeded()

            isLoading = false

        } catch {
            self.error = "Failed to load frames: \(error.localizedDescription)"
            isLoading = false
        }
    }

    // MARK: - Frame Navigation

    /// Navigate to a specific index in the frames array
    public func navigateToFrame(_ index: Int) {
        // Clamp to valid range
        let clampedIndex = max(0, min(frames.count - 1, index))
        guard clampedIndex != currentIndex else { return }

        currentIndex = clampedIndex

        // Load image if this is an image-based frame
        loadImageIfNeeded()
    }

    /// Load image for image-based frames (Retrace) if needed
    private func loadImageIfNeeded() {
        guard let timelineFrame = currentTimelineFrame else { return }

        // Only load image if this is NOT a video-based frame
        guard timelineFrame.videoInfo == nil else {
            currentImage = nil
            return
        }

        let frame = timelineFrame.frame

        // Check cache first
        if let cached = imageCache[frame.id] {
            currentImage = cached
            return
        }

        // Load from disk
        Task {
            do {
                let imageData = try await coordinator.getFrameImage(
                    segmentID: frame.segmentID,
                    timestamp: frame.timestamp
                )
                if let image = NSImage(data: imageData) {
                    imageCache[frame.id] = image
                    // Only update if we're still on the same frame
                    if currentTimelineFrame?.frame.id == frame.id {
                        currentImage = image
                    }
                }
            } catch {
                Log.error("[SimpleTimelineViewModel] Failed to load image: \(error)", category: .app)
            }
        }
    }

    /// Handle scroll delta to navigate frames
    public func handleScroll(delta: CGFloat) async {
        guard !frames.isEmpty else {
            print("[SimpleTimelineViewModel] handleScroll: frames is empty, ignoring")
            return
        }

        // Accumulate scroll delta
        scrollAccumulator += delta

        // Convert to frame steps
        // With sensitivity 0.1: need ~10 units of scroll to move 1 frame
        let sensitivity: CGFloat = 0.05
        let frameStep = Int(scrollAccumulator * sensitivity)

        print("[SimpleTimelineViewModel] handleScroll: delta=\(delta), accumulator=\(scrollAccumulator), frameStep=\(frameStep)")

        guard frameStep != 0 else { return }

        // Reset accumulator after navigating
        scrollAccumulator = 0

        print("[SimpleTimelineViewModel] Navigating from \(currentIndex) to \(currentIndex + frameStep)")

        // Navigate
        navigateToFrame(currentIndex + frameStep)
    }

    // MARK: - Computed Properties

    /// Get the playhead position as a percentage (0.0 to 1.0)
    public var playheadPosition: CGFloat {
        guard frames.count > 1 else { return 0.5 }
        return CGFloat(currentIndex) / CGFloat(frames.count - 1)
    }

    /// Get formatted time string for current frame - derived from currentTimestamp
    public var currentTimeString: String {
        guard let timestamp = currentTimestamp else { return "--:--:--" }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Get formatted date string for current frame - derived from currentTimestamp
    public var currentDateString: String {
        guard let timestamp = currentTimestamp else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Total number of frames (for tape view)
    public var frameCount: Int {
        frames.count
    }

    // MARK: - Private Helpers

    /// Group consecutive frames by app bundle ID into blocks
    private func groupFramesIntoBlocks() -> [AppBlock] {
        guard !frames.isEmpty else { return [] }

        var blocks: [AppBlock] = []
        var currentBundleID: String? = nil
        var blockStartIndex = 0

        for (index, timelineFrame) in frames.enumerated() {
            let frameBundleID = timelineFrame.frame.metadata.appBundleID

            if frameBundleID != currentBundleID {
                // End previous block if exists
                if index > 0 {
                    blocks.append(AppBlock(
                        bundleID: currentBundleID,
                        appName: frames[blockStartIndex].frame.metadata.appName,
                        startIndex: blockStartIndex,
                        endIndex: index - 1,
                        frameCount: index - blockStartIndex
                    ))
                }

                // Start new block
                currentBundleID = frameBundleID
                blockStartIndex = index
            }
        }

        // Add final block
        blocks.append(AppBlock(
            bundleID: currentBundleID,
            appName: frames[blockStartIndex].frame.metadata.appName,
            startIndex: blockStartIndex,
            endIndex: frames.count - 1,
            frameCount: frames.count - blockStartIndex
        ))

        return blocks
    }
}
