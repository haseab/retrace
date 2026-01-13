import SwiftUI
import Combine
import Shared
import App

/// Legacy ViewModel for the Timeline view (being replaced by SimpleTimelineViewModel)
/// Manages frame navigation, playback, and session filtering
@MainActor
public class LegacyTimelineViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var currentFrame: FrameReference?
    @Published public var currentFrameImage: NSImage?
    @Published public var currentFrameVideoInfo: FrameVideoInfo?
    @Published public var frames: [FrameReference] = []
    @Published public var sessions: [AppSession] = []
    @Published public var selectedSession: AppSession?
    @Published public var isLoading = false
    @Published public var error: String?

    // Timeline navigation
    @Published public var currentDate: Date = Date()
    @Published public var zoomLevel: ZoomLevel = .day
    @Published public var isPlaying = false

    // Filter state
    @Published public var filteredByApp: String?

    // Infinite scroll state
    @Published public var isLoadingMore = false
    private var hasMoreDataBackward = true  // Can load older frames
    private var oldestLoadedDate: Date?
    private var newestLoadedDate: Date?

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var playbackTimer: Timer?

    // MARK: - Constants

    private let frameLoadBatchSize = 500  // Increased for better performance with Rewind data

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        setupBindings()
    }

    // MARK: - Setup

    private func setupBindings() {
        // Auto-load frames when date changes
        $currentDate
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.loadFrames() }
            }
            .store(in: &cancellables)

        // Auto-load frames when filter changes
        $filteredByApp
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.loadFrames() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Loading

    public func loadFrames() async {
        isLoading = true
        error = nil

        do {
            let range = dateRange(for: currentDate, zoomLevel: zoomLevel)
            frames = try await coordinator.getFrames(
                from: range.start,
                to: range.end,
                limit: frameLoadBatchSize
            )

            // Track date boundaries for infinite scroll
            oldestLoadedDate = range.start
            newestLoadedDate = range.end

            // Check if we have more data
            hasMoreDataBackward = !frames.isEmpty

            // Load sessions
            sessions = try await loadSessions(in: range)

            // Set initial current frame if none selected
            if currentFrame == nil, let first = frames.first {
                await selectFrame(first)
            }

            isLoading = false
        } catch {
            self.error = "Failed to load frames: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func loadSessions(in range: DateRange) async throws -> [AppSession] {
        // Load real persisted sessions from database
        return try await coordinator.getSessions(from: range.start, to: range.end)
    }

    // MARK: - Infinite Scroll

    /// Load more frames when scrolling to the left (older data)
    /// This is where Rewind data will be fetched automatically
    public func loadMoreFramesBackward() async {
        guard !isLoadingMore, hasMoreDataBackward, let oldestDate = oldestLoadedDate else {
            return
        }

        isLoadingMore = true

        do {
            // Calculate new date range (going back in time)
            let newEndDate = oldestDate
            let newStartDate: Date
            switch zoomLevel {
            case .hour:
                newStartDate = Calendar.current.date(byAdding: .hour, value: -1, to: newEndDate)!
            case .day:
                newStartDate = Calendar.current.date(byAdding: .day, value: -1, to: newEndDate)!
            case .week:
                newStartDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: newEndDate)!
            }

            // Fetch older frames (this will automatically use Rewind if before Dec 19, 2025)
            let olderFrames = try await coordinator.getFrames(
                from: newStartDate,
                to: newEndDate,
                limit: frameLoadBatchSize
            )

            if olderFrames.isEmpty {
                hasMoreDataBackward = false
            } else {
                // Prepend older frames
                frames = olderFrames + frames
                oldestLoadedDate = newStartDate

                // Load sessions for the new range
                let newSessions = try await loadSessions(in: DateRange(start: newStartDate, end: newEndDate))
                sessions = newSessions + sessions
            }

            isLoadingMore = false
        } catch {
            self.error = "Failed to load more frames: \(error.localizedDescription)"
            isLoadingMore = false
        }
    }

    /// Check if we're near the left edge and should load more
    public func checkScrollPosition(scrollOffset: CGFloat, totalWidth: CGFloat) async {
        // If scrolled within 20% of the left edge, load more
        let threshold = totalWidth * 0.2
        if scrollOffset < threshold && !isLoadingMore {
            await loadMoreFramesBackward()
        }
    }

    // MARK: - Frame Navigation

    public func selectFrame(_ frame: FrameReference) async {
        Log.debug("[TimelineViewModel] selectFrame called - timestamp: \(frame.timestamp), source: \(frame.source)", category: .app)
        currentFrame = frame
        await loadFrameImage(frame)
    }

    public func nextFrame() async {
        guard let current = currentFrame,
              let index = frames.firstIndex(where: { $0.id == current.id }),
              index + 1 < frames.count else {
            return
        }

        await selectFrame(frames[index + 1])
    }

    public func previousFrame() async {
        guard let current = currentFrame,
              let index = frames.firstIndex(where: { $0.id == current.id }),
              index > 0 else {
            return
        }

        await selectFrame(frames[index - 1])
    }

    public func jumpToTimestamp(_ date: Date) async {
        currentDate = date

        // Find closest frame to this timestamp
        let closest = frames.min { frame1, frame2 in
            abs(frame1.timestamp.timeIntervalSince(date)) <
            abs(frame2.timestamp.timeIntervalSince(date))
        }

        if let closest = closest {
            await selectFrame(closest)
        } else {
            await loadFrames()
        }
    }

    public func jumpMinutes(_ minutes: Int) async {
        let newDate = currentDate.addingTimeInterval(TimeInterval(minutes * 60))
        await jumpToTimestamp(newDate)
    }

    public func jumpHours(_ hours: Int) async {
        let newDate = currentDate.addingTimeInterval(TimeInterval(hours * 3600))
        await jumpToTimestamp(newDate)
    }

    // MARK: - Fullscreen Timeline Support

    /// Load the most recent frame - used when opening fullscreen timeline
    /// Shows the last captured frame immediately
    /// If no frames in last hour, finds where data exists and loads an hour around that
    public func loadMostRecentFrame() async {
        isLoading = true
        error = nil

        do {
            let now = Date()
            let oneHourAgo = Calendar.current.date(byAdding: .hour, value: -1, to: now)!

            // First try: last hour
            var foundFrames = try await coordinator.getFrames(
                from: oneHourAgo,
                to: now,
                limit: 100
            )

            var rangeStart = oneHourAgo
            var rangeEnd = now

            // If no frames in last hour, find where data actually exists
            if foundFrames.isEmpty {
                if let latestTimestamp = try await coordinator.getMostRecentFrameTimestamp() {
                    // Load an hour of data ending at the most recent frame
                    rangeEnd = latestTimestamp
                    rangeStart = Calendar.current.date(byAdding: .hour, value: -1, to: latestTimestamp)!

                    foundFrames = try await coordinator.getFrames(
                        from: rangeStart,
                        to: rangeEnd,
                        limit: 100
                    )
                }
                // If still empty, latestTimestamp was nil - no data exists anywhere
            }

            frames = foundFrames

            // Set date range for infinite scroll
            oldestLoadedDate = rangeStart
            newestLoadedDate = rangeEnd
            hasMoreDataBackward = true

            // Load sessions for the searched range
            sessions = try await loadSessions(in: DateRange(start: rangeStart, end: rangeEnd))

            // Select the most recent frame (last in the array, sorted by timestamp)
            if let mostRecent = frames.last {
                await selectFrame(mostRecent)
                currentDate = mostRecent.timestamp
            }

            isLoading = false
        } catch {
            self.error = "Failed to load recent frames: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Handle scrubbing gesture from timeline bar
    /// - Parameter delta: Normalized delta (-1 to 1, negative = go back in time)
    public func handleScrub(delta: Double) async {
        guard !frames.isEmpty else { return }

        // Calculate time delta based on current zoom level
        // Trackpad sends many events per gesture (50+ events per swipe)
        // so keep this value low for smooth, controllable scrubbing
        let secondsPerUnit: Double
        switch zoomLevel {
        case .hour:
            secondsPerUnit = 0.0005 // 0.5 seconds per scroll event
        case .day:
            secondsPerUnit = 0.0005 // 0.5 seconds per scroll event
        case .week:
            secondsPerUnit = 0.0005 // 0.5 seconds per scroll event
        }

        let timeOffset = delta * secondsPerUnit
        let newDate = currentDate.addingTimeInterval(timeOffset)

        Log.debug("[TimelineViewModel] handleScrub - delta: \(delta), secondsPerUnit: \(secondsPerUnit), timeOffset: \(timeOffset)s", category: .app)

        // Always update currentDate to accumulate scroll position
        // This ensures subsequent scrolls build on each other
        currentDate = newDate

        // Find the closest frame
        let closest = frames.min { frame1, frame2 in
            abs(frame1.timestamp.timeIntervalSince(newDate)) <
            abs(frame2.timestamp.timeIntervalSince(newDate))
        }

        if let closest = closest, closest.id != currentFrame?.id {
            // Update current frame (this updates playhead and timestamp display)
            Log.debug("[TimelineViewModel] handleScrub - updating to frame at \(closest.timestamp)", category: .app)
            currentFrame = closest
            Log.debug("[TimelineViewModel] handleScrub - currentFrame updated", category: .app)
            // Load image in same task to ensure UI updates
            await loadFrameImage(closest)
        }

        // Check if we need to load more frames
        if let oldestFrame = frames.first,
           newDate < oldestFrame.timestamp {
            await loadMoreFramesBackward()
        }
    }

    // MARK: - Playback

    public func togglePlayback() {
        isPlaying.toggle()

        if isPlaying {
            startPlayback()
        } else {
            stopPlayback()
        }
    }

    private func startPlayback() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.nextFrame()
            }
        }
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: - Session Filtering

    public func selectSession(_ session: AppSession) {
        if selectedSession?.id == session.id {
            // Deselect
            selectedSession = nil
            filteredByApp = nil
        } else {
            selectedSession = session
            filteredByApp = session.appBundleID
        }
    }

    public func clearSessionFilter() {
        selectedSession = nil
        filteredByApp = nil
    }

    // MARK: - Zoom

    public func setZoomLevel(_ level: ZoomLevel) {
        zoomLevel = level
        Task { await loadFrames() }
    }

    // MARK: - Image Loading

    private func loadFrameImage(_ frame: FrameReference) async {
        Log.debug("[TimelineViewModel] loadFrameImage - frame source: \(frame.source), timestamp: \(frame.timestamp)", category: .app)
        do {
            // Try to get video info first (for Rewind frames)
            Log.debug("[TimelineViewModel] Attempting to get video info for frame", category: .app)
            if let videoInfo = try await coordinator.getFrameVideoInfo(
                segmentID: frame.segmentID,
                timestamp: frame.timestamp,
                source: frame.source
            ) {
                // Video-based frame (Rewind)
                Log.debug("[TimelineViewModel] Got video info: \(videoInfo.videoPath), frame \(videoInfo.frameIndex)", category: .app)
                currentFrameVideoInfo = videoInfo
                currentFrameImage = nil
                Log.debug("[TimelineViewModel] Set currentFrameVideoInfo, cleared currentFrameImage", category: .app)
            } else {
                // Image-based frame (Retrace)
                Log.debug("[TimelineViewModel] No video info, loading as image", category: .app)
                let imageData = try await coordinator.getFrameImage(
                    segmentID: frame.segmentID,
                    timestamp: frame.timestamp
                )

                if let image = NSImage(data: imageData) {
                    currentFrameImage = image
                    currentFrameVideoInfo = nil
                    Log.debug("[TimelineViewModel] Loaded image successfully", category: .app)
                } else {
                    error = "Failed to decode frame image"
                    Log.error("[TimelineViewModel] Failed to decode frame image", category: .app)
                }
            }
        } catch {
            self.error = "Failed to load frame: \(error.localizedDescription)"
            Log.error("[TimelineViewModel] Failed to load frame: \(error)", category: .app)
        }
    }

    // MARK: - Helpers

    private func dateRange(for date: Date, zoomLevel: ZoomLevel) -> DateRange {
        let calendar = Calendar.current

        switch zoomLevel {
        case .hour:
            let start = calendar.date(byAdding: .minute, value: -30, to: date)!
            let end = calendar.date(byAdding: .minute, value: 30, to: date)!
            return DateRange(start: start, end: end)

        case .day:
            let start = calendar.startOfDay(for: date)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return DateRange(start: start, end: end)

        case .week:
            let start = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
            return DateRange(start: start, end: end)
        }
    }

    // MARK: - Cleanup

    deinit {
        playbackTimer?.invalidate()
        cancellables.removeAll()
    }
}

// MARK: - Supporting Types

public enum ZoomLevel: String, CaseIterable {
    case hour = "Hour"
    case day = "Day"
    case week = "Week"

    public var framesPerView: Int {
        switch self {
        case .hour: return 20
        case .day: return 100
        case .week: return 500
        }
    }

    public var thumbnailInterval: Int {
        switch self {
        case .hour: return 1  // Every frame
        case .day: return 5   // Every 5th frame
        case .week: return 20 // Every 20th frame
        }
    }
}

public struct DateRange {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}
