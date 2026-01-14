import SwiftUI
import Combine
import AVFoundation
import Shared
import App

/// Shared timeline configuration
public enum TimelineConfig {
    /// Base pixels per frame at 100% zoom (max detail)
    public static let basePixelsPerFrame: CGFloat = 75.0
    /// Minimum pixels per frame at 0% zoom (most zoomed out)
    public static let minPixelsPerFrame: CGFloat = 8.0
    /// Default zoom level (0.0 to 1.0, where 1.0 is max detail)
    public static let defaultZoomLevel: CGFloat = 0.6
}

/// Configuration for infinite scroll rolling window
private enum WindowConfig {
    static let maxFrames = 500           // Maximum frames in memory
    static let loadThreshold = 100       // Start loading when within N frames of edge
    static let loadBatchSize = 200       // Frames to load per batch
}

/// Memory tracking for debugging frame accumulation issues
private enum MemoryTracker {
    /// Log memory state for debugging
    static func logMemoryState(
        context: String,
        frameCount: Int,
        imageCacheCount: Int,
        oldestTimestamp: Date?,
        newestTimestamp: Date?
    ) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let oldest = oldestTimestamp.map { dateFormatter.string(from: $0) } ?? "nil"
        let newest = newestTimestamp.map { dateFormatter.string(from: $0) } ?? "nil"

        Log.debug(
            "[Memory] \(context) | frames=\(frameCount)/\(WindowConfig.maxFrames) | imageCache=\(imageCacheCount) | window=[\(oldest) → \(newest)]",
            category: .ui
        )
    }
}

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

    /// Calculate width based on current pixels per frame
    public func width(pixelsPerFrame: CGFloat) -> CGFloat {
        CGFloat(frameCount) * pixelsPerFrame
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

    /// Whether the date search input is shown
    @Published public var isDateSearchActive = false

    /// Date search text input
    @Published public var dateSearchText = ""

    /// Zoom level (0.0 to 1.0, where 1.0 is max detail/zoomed in)
    @Published public var zoomLevel: CGFloat = TimelineConfig.defaultZoomLevel

    /// Whether the zoom slider is expanded/visible
    @Published public var isZoomSliderExpanded = false

    /// Currently selected frame index (for deletion, etc.) - nil means no selection
    @Published public var selectedFrameIndex: Int? = nil

    /// Whether the delete confirmation dialog is shown
    @Published public var showDeleteConfirmation = false

    /// Whether we're deleting a single frame or an entire segment
    @Published public var isDeleteSegmentMode = false

    /// Frames that have been "deleted" (optimistically removed from UI)
    @Published public var deletedFrameIDs: Set<FrameID> = []

    // MARK: - Zoom Computed Properties

    /// Current pixels per frame based on zoom level
    public var pixelsPerFrame: CGFloat {
        let range = TimelineConfig.basePixelsPerFrame - TimelineConfig.minPixelsPerFrame
        return TimelineConfig.minPixelsPerFrame + (range * zoomLevel)
    }

    /// Frame skip factor - how many frames to skip when displaying
    /// At 50%+ zoom, show all frames (skip = 1)
    /// Below 50%, progressively skip more frames
    public var frameSkipFactor: Int {
        if zoomLevel >= 0.5 {
            return 1 // Show all frames
        }
        // Below 50% zoom, calculate skip factor
        // At 0% zoom: skip factor of ~5
        // At 25% zoom: skip factor of ~3
        // At 50% zoom: skip factor of 1
        let skipRange = zoomLevel / 0.5 // 0.0 to 1.0 within the 0-50% range
        let maxSkip = 5
        let skip = Int(round(CGFloat(maxSkip) - (skipRange * CGFloat(maxSkip - 1))))
        return max(1, skip)
    }

    /// Visible frames accounting for skip factor
    public var visibleFrameIndices: [Int] {
        let skip = frameSkipFactor
        if skip == 1 {
            return Array(0..<frames.count)
        }
        // Return every Nth frame index
        return stride(from: 0, to: frames.count, by: skip).map { $0 }
    }

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
    private var imageCache: [FrameID: NSImage] = [:] {
        didSet {
            let oldCount = oldValue.count
            let newCount = imageCache.count
            if oldCount != newCount {
                Log.debug("[Memory] imageCache changed: \(oldCount) → \(newCount) images", category: .ui)
            }
        }
    }

    /// Maximum images to keep in cache (prevents unbounded memory growth)
    private static let maxImageCacheSize = 50

    // MARK: - Infinite Scroll Window State

    /// Timestamp of the oldest loaded frame (for loading older frames)
    private var oldestLoadedTimestamp: Date?

    /// Timestamp of the newest loaded frame (for loading newer frames)
    private var newestLoadedTimestamp: Date?

    /// Flag to prevent concurrent loads in the "older" direction
    private var isLoadingOlder = false

    /// Flag to prevent concurrent loads in the "newer" direction
    private var isLoadingNewer = false

    /// Whether there's more data available in the older direction
    private var hasMoreOlder = true

    /// Whether there's more data available in the newer direction
    private var hasMoreNewer = true

    /// Counter for periodic memory logging (log every N navigations)
    private var navigationCounter: Int = 0
    private static let memoryLogInterval = 50  // Log memory state every 50 navigations

    // MARK: - Position Cache (for restoring position on reopen)

    /// Key for storing cached position timestamp in UserDefaults
    private static let cachedPositionTimestampKey = "timeline.cachedPositionTimestamp"
    /// Key for storing when the cache was saved
    private static let cachedPositionSavedAtKey = "timeline.cachedPositionSavedAt"
    /// Key for storing the cached current index
    private static let cachedCurrentIndexKey = "timeline.cachedCurrentIndex"
    /// How long the cached position remains valid (2 minutes)
    private static let cacheExpirationSeconds: TimeInterval = 120

    /// File path for cached frames data
    private static nonisolated var cachedFramesPath: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("timeline_frames_cache.json")
    }

    // MARK: - Dependencies

    private let coordinator: AppCoordinator

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - Frame Selection & Deletion

    /// Select a frame at the given index and move the playhead there
    public func selectFrame(at index: Int) {
        guard index >= 0 && index < frames.count else { return }

        // Move playhead to the selected frame
        navigateToFrame(index)

        // Set selection
        selectedFrameIndex = index
    }

    /// Clear the current selection
    public func clearSelection() {
        selectedFrameIndex = nil
    }

    /// Request deletion of the selected frame (shows confirmation dialog)
    public func requestDeleteSelectedFrame() {
        guard selectedFrameIndex != nil else { return }
        showDeleteConfirmation = true
    }

    /// Perform optimistic deletion of the selected frame and persist to database
    public func confirmDeleteSelectedFrame() {
        guard let index = selectedFrameIndex, index >= 0 && index < frames.count else {
            showDeleteConfirmation = false
            return
        }

        let frameToDelete = frames[index]
        let frameID = frameToDelete.frame.id
        let frameRef = frameToDelete.frame

        // Add to deleted set for potential undo
        deletedFrameIDs.insert(frameID)

        // Remove from frames array (optimistic deletion)
        frames.remove(at: index)

        // Clear cached blocks since frames changed
        _cachedAppBlocks = nil

        // Adjust current index if needed
        if currentIndex >= frames.count {
            currentIndex = max(0, frames.count - 1)
        } else if currentIndex > index {
            currentIndex -= 1
        }

        // Clear selection
        selectedFrameIndex = nil
        showDeleteConfirmation = false

        // Load image if needed for new current frame
        loadImageIfNeeded()

        print("[Delete] Frame \(frameID) removed from UI (optimistic deletion)")

        // Persist deletion to database in background
        Task {
            do {
                try await coordinator.deleteFrame(
                    frameID: frameRef.id,
                    timestamp: frameRef.timestamp,
                    source: frameRef.source
                )
                print("[Delete] Frame \(frameID) deleted from database")
            } catch {
                // Log error but don't restore UI - user already saw it deleted
                Log.error("[Delete] Failed to delete frame from database: \(error)", category: .app)
                print("[Delete] ERROR: Failed to delete frame from database: \(error)")
            }
        }
    }

    /// Cancel deletion
    public func cancelDelete() {
        showDeleteConfirmation = false
        isDeleteSegmentMode = false
    }

    /// Get the selected frame (if any)
    public var selectedFrame: TimelineFrame? {
        guard let index = selectedFrameIndex, index >= 0 && index < frames.count else { return nil }
        return frames[index]
    }

    /// Get the app block containing the selected frame
    public var selectedBlock: AppBlock? {
        guard let index = selectedFrameIndex else { return nil }
        return appBlocks.first { index >= $0.startIndex && index <= $0.endIndex }
    }

    /// Get the number of frames in the selected segment
    public var selectedSegmentFrameCount: Int {
        selectedBlock?.frameCount ?? 0
    }

    /// Perform optimistic deletion of the entire segment containing the selected frame and persist to database
    public func confirmDeleteSegment() {
        guard let block = selectedBlock else {
            showDeleteConfirmation = false
            isDeleteSegmentMode = false
            return
        }

        // Collect all frames to delete (need full FrameReference for database deletion)
        var framesToDelete: [FrameReference] = []
        for index in block.startIndex...block.endIndex {
            if index < frames.count {
                let frameRef = frames[index].frame
                deletedFrameIDs.insert(frameRef.id)
                framesToDelete.append(frameRef)
            }
        }

        let deleteCount = block.frameCount
        let startIndex = block.startIndex

        // Remove frames from array (in reverse to maintain indices)
        frames.removeSubrange(block.startIndex...min(block.endIndex, frames.count - 1))

        // Clear cached blocks since frames changed
        _cachedAppBlocks = nil

        // Adjust current index
        if currentIndex >= startIndex + deleteCount {
            // Current was after deleted segment
            currentIndex -= deleteCount
        } else if currentIndex >= startIndex {
            // Current was within deleted segment - move to start of where segment was
            currentIndex = max(0, min(startIndex, frames.count - 1))
        }

        // Clear selection
        selectedFrameIndex = nil
        showDeleteConfirmation = false
        isDeleteSegmentMode = false

        // Load image if needed for new current frame
        loadImageIfNeeded()

        print("[Delete] Segment with \(deleteCount) frames removed from UI (optimistic deletion)")

        // Persist deletion to database in background
        Task {
            do {
                try await coordinator.deleteFrames(framesToDelete)
                print("[Delete] Segment with \(deleteCount) frames deleted from database")
            } catch {
                // Log error but don't restore UI - user already saw it deleted
                Log.error("[Delete] Failed to delete segment from database: \(error)", category: .app)
                print("[Delete] ERROR: Failed to delete segment from database: \(error)")
            }
        }
    }

    // MARK: - Position Cache Methods

    /// Save the current playhead position AND frames to cache for instant restore
    public func savePosition() {
        guard let timestamp = currentTimestamp else { return }
        guard !frames.isEmpty else { return }

        // Save timestamp and index to UserDefaults
        UserDefaults.standard.set(timestamp.timeIntervalSince1970, forKey: Self.cachedPositionTimestampKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cachedPositionSavedAtKey)
        UserDefaults.standard.set(currentIndex, forKey: Self.cachedCurrentIndexKey)

        // Save frames to disk (JSON file) - do this async to not block the main thread
        Task.detached(priority: .utility) { [frames] in
            do {
                // Convert TimelineFrame to FrameWithVideoInfo for encoding
                let framesWithVideoInfo = frames.map { FrameWithVideoInfo(frame: $0.frame, videoInfo: $0.videoInfo) }
                let data = try JSONEncoder().encode(framesWithVideoInfo)
                try data.write(to: Self.cachedFramesPath)
                print("[PositionCache] Saved \(frames.count) frames to cache (\(data.count / 1024)KB)")
            } catch {
                print("[PositionCache] Failed to save frames: \(error)")
            }
        }

        print("[PositionCache] Saved position: \(timestamp), index: \(currentIndex)")
    }

    /// Get the cached frames if they exist and haven't expired
    private func getCachedFrames() -> (frames: [TimelineFrame], currentIndex: Int)? {
        let savedAt = UserDefaults.standard.double(forKey: Self.cachedPositionSavedAtKey)
        guard savedAt > 0 else { return nil }

        let savedAtDate = Date(timeIntervalSince1970: savedAt)
        let elapsed = Date().timeIntervalSince(savedAtDate)

        // Check if cache has expired
        if elapsed > Self.cacheExpirationSeconds {
            print("[PositionCache] Cache expired (elapsed: \(Int(elapsed))s)")
            clearCachedPosition()
            return nil
        }

        // Load cached current index
        let cachedIndex = UserDefaults.standard.integer(forKey: Self.cachedCurrentIndexKey)

        // Load cached frames from disk
        do {
            let data = try Data(contentsOf: Self.cachedFramesPath)
            let framesWithVideoInfo = try JSONDecoder().decode([FrameWithVideoInfo].self, from: data)

            guard !framesWithVideoInfo.isEmpty else { return nil }

            let timelineFrames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo) }
            let validIndex = max(0, min(cachedIndex, timelineFrames.count - 1))

            print("[PositionCache] Loaded \(timelineFrames.count) cached frames (saved \(Int(elapsed))s ago)")
            return (frames: timelineFrames, currentIndex: validIndex)
        } catch {
            print("[PositionCache] Failed to load cached frames: \(error)")
            return nil
        }
    }

    /// Get the cached position (timestamp only) if it exists and hasn't expired
    /// This is the fallback if frame cache is not available
    private func getCachedPosition() -> Date? {
        let savedAt = UserDefaults.standard.double(forKey: Self.cachedPositionSavedAtKey)
        guard savedAt > 0 else { return nil }

        let savedAtDate = Date(timeIntervalSince1970: savedAt)
        let elapsed = Date().timeIntervalSince(savedAtDate)

        // Check if cache has expired
        if elapsed > Self.cacheExpirationSeconds {
            print("[PositionCache] Cache expired (elapsed: \(Int(elapsed))s)")
            clearCachedPosition()
            return nil
        }

        let cachedTimestamp = UserDefaults.standard.double(forKey: Self.cachedPositionTimestampKey)
        guard cachedTimestamp > 0 else { return nil }

        let position = Date(timeIntervalSince1970: cachedTimestamp)
        print("[PositionCache] Found valid cached position: \(position) (saved \(Int(elapsed))s ago)")
        return position
    }

    /// Clear the cached position and frames
    private func clearCachedPosition() {
        UserDefaults.standard.removeObject(forKey: Self.cachedPositionTimestampKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedPositionSavedAtKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedCurrentIndexKey)

        // Remove cached frames file
        try? FileManager.default.removeItem(at: Self.cachedFramesPath)
    }

    // MARK: - Initial Load

    /// Load the most recent frame on startup, or restore to cached position if available
    public func loadMostRecentFrame() async {
        isLoading = true
        error = nil

        // FIRST: Try to restore from cached frames (instant restore - no database query!)
        if let cached = getCachedFrames() {
            print("[PositionCache] INSTANT RESTORE: Using \(cached.frames.count) cached frames, index: \(cached.currentIndex)")

            frames = cached.frames
            currentIndex = cached.currentIndex

            // Initialize window boundary timestamps for infinite scroll
            updateWindowBoundaries()
            hasMoreOlder = true
            hasMoreNewer = true

            // Clear the cache after restoring
            clearCachedPosition()

            // Load image if needed for current frame
            loadImageIfNeeded()

            isLoading = false
            return
        }

        do {
            // SECOND: Try cached position (timestamp only) - requires database query
            if let cachedPosition = getCachedPosition() {
                print("[PositionCache] Found cached position: \(cachedPosition), loading frames around it")

                // Load frames around the cached position (±10 minutes window, like date search)
                // Uses optimized query that JOINs on video table - no N+1 queries!
                let calendar = Calendar.current
                let startDate = calendar.date(byAdding: .minute, value: -10, to: cachedPosition) ?? cachedPosition
                let endDate = calendar.date(byAdding: .minute, value: 10, to: cachedPosition) ?? cachedPosition

                let framesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(from: startDate, to: endDate, limit: 1000)

                if !framesWithVideoInfo.isEmpty {
                    // Convert to TimelineFrame - video info is already included from the JOIN
                    frames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo) }

                    // Initialize window boundary timestamps for infinite scroll
                    updateWindowBoundaries()
                    hasMoreOlder = true
                    hasMoreNewer = true

                    // Find the frame closest to the cached position
                    let closestIndex = findClosestFrameIndex(to: cachedPosition)
                    currentIndex = closestIndex
                    print("[PositionCache] Restored to cached position, index: \(closestIndex), frame count: \(frames.count)")

                    // Clear the cache after restoring
                    clearCachedPosition()

                    // Load image if needed for current frame
                    loadImageIfNeeded()

                    isLoading = false
                    return
                } else {
                    print("[PositionCache] No frames found around cached position, falling back to most recent")
                    clearCachedPosition()
                }
            }

            // No cached position (or cache was empty) - load most recent frames
            // Uses optimized query that JOINs on video table - no N+1 queries!
            let framesWithVideoInfo = try await coordinator.getMostRecentFramesWithVideoInfo(limit: 500)

            guard !framesWithVideoInfo.isEmpty else {
                error = "No frames found in any database"
                isLoading = false
                return
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            // Reverse so oldest is first (index 0), newest is last
            // This matches the timeline UI which displays left-to-right as past-to-future
            frames = framesWithVideoInfo.reversed().map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo) }

            // Initialize window boundary timestamps for infinite scroll
            updateWindowBoundaries()

            // Log the first and last few frames to verify ordering
            print("[SimpleTimelineViewModel] Loaded \(frames.count) frames")

            // Log initial memory state
            MemoryTracker.logMemoryState(
                context: "INITIAL LOAD",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )
            if frames.count > 0 {
                print("[SimpleTimelineViewModel] First 3 frames (should be oldest):")
                for i in 0..<min(3, frames.count) {
                    let f = frames[i].frame
                    print("  [\(i)] \(f.timestamp) - \(f.metadata.appBundleID ?? "nil")")
                }
                print("[SimpleTimelineViewModel] Last 3 frames (should be newest):")
                for i in max(0, frames.count - 3)..<frames.count {
                    let f = frames[i].frame
                    print("  [\(i)] \(f.timestamp) - \(f.metadata.appBundleID ?? "nil")")
                }
            }

            // Start at the most recent frame (last in array since sorted ascending, oldest first)
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

        // Check if we need to load more frames (infinite scroll)
        checkAndLoadMoreFrames()

        // Periodic memory state logging
        navigationCounter += 1
        if navigationCounter % Self.memoryLogInterval == 0 {
            MemoryTracker.logMemoryState(
                context: "PERIODIC (nav #\(navigationCounter))",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )
        }
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
                    // Prune cache if it's getting too large
                    pruneImageCacheIfNeeded()

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

    /// Prune image cache if it exceeds maximum size
    private func pruneImageCacheIfNeeded() {
        guard imageCache.count >= Self.maxImageCacheSize else { return }

        // Get valid frame IDs (frames currently in the window)
        let validFrameIDs = Set(frames.map { $0.frame.id })

        // Remove images for frames that are no longer in the window
        let oldCount = imageCache.count
        imageCache = imageCache.filter { validFrameIDs.contains($0.key) }

        let removedCount = oldCount - imageCache.count
        if removedCount > 0 {
            Log.info("[Memory] Pruned \(removedCount) images from cache (frames no longer in window)", category: .ui)
        }

        // If still too large, remove oldest entries (keep half)
        if imageCache.count >= Self.maxImageCacheSize {
            let toRemove = imageCache.count - (Self.maxImageCacheSize / 2)
            let keysToRemove = Array(imageCache.keys.prefix(toRemove))
            keysToRemove.forEach { imageCache.removeValue(forKey: $0) }
            Log.info("[Memory] Force-pruned \(toRemove) images from cache (cache overflow)", category: .ui)
        }
    }

    /// Handle scroll delta to navigate frames
    public func handleScroll(delta: CGFloat) async {
        guard !frames.isEmpty else {
            // print("[SimpleTimelineViewModel] handleScroll: frames is empty, ignoring")
            return
        }

        // Accumulate scroll delta
        scrollAccumulator += delta

        // Convert to frame steps
        // Base sensitivity at default zoom level (60%)
        // Scale sensitivity inversely with pixelsPerFrame to maintain consistent visual scroll speed
        // When zoomed out (fewer pixels per frame), we need to move more frames per scroll unit
        // When zoomed in (more pixels per frame), we need to move fewer frames per scroll unit
        let baseSensitivity: CGFloat = 0.05
        let referencePixelsPerFrame: CGFloat = TimelineConfig.basePixelsPerFrame * TimelineConfig.defaultZoomLevel + TimelineConfig.minPixelsPerFrame * (1 - TimelineConfig.defaultZoomLevel)
        let zoomAdjustedSensitivity = baseSensitivity * (referencePixelsPerFrame / pixelsPerFrame)

        let frameStep = Int(scrollAccumulator * zoomAdjustedSensitivity)

        guard frameStep != 0 else { return }

        // Reset accumulator after navigating
        scrollAccumulator = 0

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
        formatter.dateFormat = "MMM d"
        formatter.timeZone = .current
        return formatter.string(from: timestamp)
    }

    /// Total number of frames (for tape view)
    public var frameCount: Int {
        frames.count
    }

    // MARK: - Date Search

    /// Search for frames around a natural language date string
    public func searchForDate(_ searchText: String) async {
        guard !searchText.isEmpty else { return }

        isLoading = true
        error = nil

        do {
            // Parse natural language date
            guard let targetDate = parseNaturalLanguageDate(searchText) else {
                error = "Could not understand date: \(searchText)"
                isLoading = false
                return
            }

            // Load frames around the target date (±10 minutes window)
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            // Debug logging
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            df.timeZone = .current
            print("[DateSearch] Input: '\(searchText)'")
            print("[DateSearch] Parsed targetDate (local): \(df.string(from: targetDate))")
            df.timeZone = TimeZone(identifier: "UTC")
            print("[DateSearch] Parsed targetDate (UTC): \(df.string(from: targetDate))")
            df.timeZone = .current
            print("[DateSearch] Query range: \(df.string(from: startDate)) to \(df.string(from: endDate))")

            // Fetch all frames in the 20-minute window
            // Uses optimized query that JOINs on video table - no N+1 queries!
            let framesWithVideoInfo = try await coordinator.getFramesWithVideoInfo(from: startDate, to: endDate, limit: 1000)
            print("[DateSearch] Got \(framesWithVideoInfo.count) frames")

            guard !framesWithVideoInfo.isEmpty else {
                error = "No frames found around \(targetDate)"
                isLoading = false
                return
            }

            // Clear old image cache since we're jumping to a new time window
            let oldCacheCount = imageCache.count
            imageCache.removeAll()
            if oldCacheCount > 0 {
                Log.info("[Memory] Cleared image cache on date search (\(oldCacheCount) images removed)", category: .ui)
            }

            // Convert to TimelineFrame - video info is already included from the JOIN
            frames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo) }

            // Reset infinite scroll state for new window
            updateWindowBoundaries()
            hasMoreOlder = true
            hasMoreNewer = true

            // Find the frame closest to the target date in our centered set
            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex

            // Load image if needed
            loadImageIfNeeded()

            // Log memory state after date search
            MemoryTracker.logMemoryState(
                context: "DATE SEARCH COMPLETE",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            isLoading = false
            isDateSearchActive = false
            dateSearchText = ""

        } catch {
            self.error = "Failed to search for date: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Parse natural language date strings
    private func parseNaturalLanguageDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        let now = Date()

        // === RELATIVE DATES ===

        if trimmed == "now" || trimmed == "today" {
            return now
        }
        if trimmed == "yesterday" {
            return calendar.date(byAdding: .day, value: -1, to: now)
        }
        if trimmed == "last week" {
            return calendar.date(byAdding: .day, value: -7, to: now)
        }
        if trimmed == "last month" {
            return calendar.date(byAdding: .month, value: -1, to: now)
        }

        // "X hours ago", "X hour ago", "an hour ago"
        if trimmed.contains("hour") {
            if let hours = extractNumber(from: trimmed) {
                return calendar.date(byAdding: .hour, value: -hours, to: now)
            }
            return calendar.date(byAdding: .hour, value: -1, to: now)
        }

        // "X minutes ago", "X min ago", "30 min ago"
        if trimmed.contains("minute") || trimmed.contains("min") {
            if let minutes = extractNumber(from: trimmed) {
                return calendar.date(byAdding: .minute, value: -minutes, to: now)
            }
            return calendar.date(byAdding: .minute, value: -1, to: now)
        }

        // "X days ago"
        if trimmed.contains("day") && trimmed.contains("ago") {
            if let days = extractNumber(from: trimmed) {
                return calendar.date(byAdding: .day, value: -days, to: now)
            }
        }

        // "X weeks ago"
        if trimmed.contains("week") {
            if let weeks = extractNumber(from: trimmed) {
                return calendar.date(byAdding: .day, value: -weeks * 7, to: now)
            }
            return calendar.date(byAdding: .day, value: -7, to: now)
        }

        // === ABSOLUTE DATES ===

        // Try macOS's built-in natural language date parser (handles "dec 15 3pm", "tomorrow at 5", etc.)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let detector = detector {
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, options: [], range: range),
               let date = match.date {
                return date
            }
        }

        // Try various explicit date formatters as fallback
        let formatStrings = [
            "MMM d yyyy h:mm a",      // "Dec 16 2024 6:05 PM"
            "MMM d yyyy h:mma",       // "Dec 16 2024 6:05PM"
            "MMM d yyyy ha",          // "Dec 16 2024 6PM"
            "MMM d h:mm a",           // "Dec 16 6:05 PM"
            "MMM d h:mma",            // "Dec 16 6:05PM"
            "MMM d ha",               // "Dec 16 6PM"
            "MMM d h a",              // "Dec 16 6 PM"
            "MM/dd/yyyy h:mm a",      // "12/16/2024 6:05 PM"
            "MM/dd h:mm a",           // "12/16 6:05 PM"
            "yyyy-MM-dd HH:mm",       // "2024-12-16 18:05"
            "yyyy-MM-dd'T'HH:mm:ss",  // ISO 8601
            "MMM d",                  // "Dec 16" (assumes current year, noon)
            "MMMM d",                 // "December 16"
        ]

        for formatString in formatStrings {
            let df = DateFormatter()
            df.dateFormat = formatString
            df.timeZone = .current
            df.defaultDate = now  // Use current date for missing components

            // Try original text first
            if let date = df.date(from: text) {
                return date
            }
            // Try lowercased
            if let date = df.date(from: trimmed) {
                return date
            }
            // Try with first letter capitalized (for month names)
            let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            if let date = df.date(from: capitalized) {
                return date
            }
        }

        return nil
    }

    /// Extract first number from a string
    private func extractNumber(from text: String) -> Int? {
        let pattern = "\\d+"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return Int(text[range])
        }
        return nil
    }

    /// Find the frame index closest to a target date
    private func findClosestFrameIndex(to targetDate: Date) -> Int {
        guard !frames.isEmpty else { return 0 }

        var closestIndex = 0
        var smallestDiff = abs(frames[0].frame.timestamp.timeIntervalSince(targetDate))

        for (index, timelineFrame) in frames.enumerated() {
            let diff = abs(timelineFrame.frame.timestamp.timeIntervalSince(targetDate))
            if diff < smallestDiff {
                smallestDiff = diff
                closestIndex = index
            }
        }

        return closestIndex
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

    // MARK: - Infinite Scroll

    /// Update window boundary timestamps from current frames
    private func updateWindowBoundaries() {
        oldestLoadedTimestamp = frames.first?.frame.timestamp
        newestLoadedTimestamp = frames.last?.frame.timestamp

        if let oldest = oldestLoadedTimestamp, let newest = newestLoadedTimestamp {
            print("[InfiniteScroll] Window boundaries: \(oldest) to \(newest)")
        }
    }

    /// Check if we need to load more frames based on current position
    private func checkAndLoadMoreFrames() {
        // Check if approaching the older end (left side of timeline)
        if currentIndex < WindowConfig.loadThreshold && hasMoreOlder && !isLoadingOlder {
            Task {
                await loadOlderFrames()
            }
        }

        // Check if approaching the newer end (right side of timeline)
        if currentIndex > frames.count - WindowConfig.loadThreshold && hasMoreNewer && !isLoadingNewer {
            Task {
                await loadNewerFrames()
            }
        }
    }

    /// Load older frames (before the oldest loaded timestamp)
    private func loadOlderFrames() async {
        guard let oldestTimestamp = oldestLoadedTimestamp else { return }
        guard !isLoadingOlder else { return }

        isLoadingOlder = true
        print("[InfiniteScroll] Loading older frames before \(oldestTimestamp)...")

        do {
            // Query frames before the oldest timestamp
            // Uses optimized query that JOINs on video table - no N+1 queries!
            let framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoBefore(
                timestamp: oldestTimestamp,
                limit: WindowConfig.loadBatchSize
            )

            guard !framesWithVideoInfo.isEmpty else {
                print("[InfiniteScroll] No more older frames available")
                hasMoreOlder = false
                isLoadingOlder = false
                return
            }

            print("[InfiniteScroll] Got \(framesWithVideoInfo.count) older frames")

            // Convert to TimelineFrame - video info is already included from the JOIN
            // framesWithVideoInfo are returned DESC (newest first), reverse to get ASC (oldest first)
            let newTimelineFrames = framesWithVideoInfo.reversed().map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo) }

            // Prepend to existing frames
            let beforeCount = frames.count
            frames = newTimelineFrames + frames

            // Adjust currentIndex to maintain position
            currentIndex += newTimelineFrames.count

            Log.info("[Memory] LOADED OLDER: +\(newTimelineFrames.count) frames (\(beforeCount)→\(frames.count)), index adjusted to \(currentIndex)", category: .ui)
            MemoryTracker.logMemoryState(
                context: "AFTER LOAD OLDER",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            // Update window boundaries
            updateWindowBoundaries()

            // Trim if we've exceeded max frames
            trimWindowIfNeeded(preserveDirection: .older)

            isLoadingOlder = false

        } catch {
            print("[InfiniteScroll] Error loading older frames: \(error)")
            isLoadingOlder = false
        }
    }

    /// Load newer frames (after the newest loaded timestamp)
    private func loadNewerFrames() async {
        guard let newestTimestamp = newestLoadedTimestamp else { return }
        guard !isLoadingNewer else { return }

        isLoadingNewer = true
        print("[InfiniteScroll] Loading newer frames after \(newestTimestamp)...")

        do {
            // Query frames after the newest timestamp
            // Uses optimized query that JOINs on video table - no N+1 queries!
            let framesWithVideoInfo = try await coordinator.getFramesWithVideoInfoAfter(
                timestamp: newestTimestamp,
                limit: WindowConfig.loadBatchSize
            )

            guard !framesWithVideoInfo.isEmpty else {
                print("[InfiniteScroll] No more newer frames available")
                hasMoreNewer = false
                isLoadingNewer = false
                return
            }

            print("[InfiniteScroll] Got \(framesWithVideoInfo.count) newer frames")

            // Convert to TimelineFrame - video info is already included from the JOIN
            // framesWithVideoInfo are returned ASC (oldest first), which is correct for appending
            let newTimelineFrames = framesWithVideoInfo.map { TimelineFrame(frame: $0.frame, videoInfo: $0.videoInfo) }

            // Append to existing frames
            let beforeCount = frames.count
            frames = frames + newTimelineFrames

            Log.info("[Memory] LOADED NEWER: +\(newTimelineFrames.count) frames (\(beforeCount)→\(frames.count))", category: .ui)
            MemoryTracker.logMemoryState(
                context: "AFTER LOAD NEWER",
                frameCount: frames.count,
                imageCacheCount: imageCache.count,
                oldestTimestamp: oldestLoadedTimestamp,
                newestTimestamp: newestLoadedTimestamp
            )

            // Update window boundaries
            updateWindowBoundaries()

            // Trim if we've exceeded max frames
            trimWindowIfNeeded(preserveDirection: .newer)

            isLoadingNewer = false

        } catch {
            print("[InfiniteScroll] Error loading newer frames: \(error)")
            isLoadingNewer = false
        }
    }

    /// Direction to preserve when trimming
    private enum TrimDirection {
        case older  // Preserve older frames, trim newer
        case newer  // Preserve newer frames, trim older
    }

    /// Trim the window if it exceeds max frames
    private func trimWindowIfNeeded(preserveDirection: TrimDirection) {
        guard frames.count > WindowConfig.maxFrames else { return }

        let excessCount = frames.count - WindowConfig.maxFrames
        let beforeCount = frames.count

        switch preserveDirection {
        case .older:
            // User is scrolling toward older, trim newer frames from end
            Log.info("[Memory] TRIMMING \(excessCount) newer frames from END (preserving older)", category: .ui)
            frames = Array(frames.dropLast(excessCount))
            // Mark that there might be more newer frames now
            hasMoreNewer = true

        case .newer:
            // User is scrolling toward newer, trim older frames from start
            Log.info("[Memory] TRIMMING \(excessCount) older frames from START (preserving newer)", category: .ui)
            frames = Array(frames.dropFirst(excessCount))
            // Adjust currentIndex
            currentIndex = max(0, currentIndex - excessCount)
            // Mark that there might be more older frames now
            hasMoreOlder = true
        }

        // Update boundaries after trimming
        updateWindowBoundaries()

        // Log the memory state after trimming
        MemoryTracker.logMemoryState(
            context: "AFTER TRIM (\(beforeCount)→\(frames.count))",
            frameCount: frames.count,
            imageCacheCount: imageCache.count,
            oldestTimestamp: oldestLoadedTimestamp,
            newestTimestamp: newestLoadedTimestamp
        )
    }
}
