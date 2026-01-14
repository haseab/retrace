import SwiftUI
import Combine
import AVFoundation
import Shared
import App

/// Shared timeline configuration
public enum TimelineConfig {
    public static let pixelsPerFrame: CGFloat = 45.0
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

    public var width: CGFloat {
        CGFloat(frameCount) * TimelineConfig.pixelsPerFrame
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
            // Get the most recent frames directly (no need for timestamp + window query)
            let rawFrames = try await coordinator.getMostRecentFrames(limit: 500)

            guard !rawFrames.isEmpty else {
                error = "No frames found in any database"
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

            // Reverse so oldest is first (index 0), newest is last
            // This matches the timeline UI which displays left-to-right as past-to-future
            frames = timelineFrames.reversed()

            // Log the first and last few frames to verify ordering
            print("[SimpleTimelineViewModel] Loaded \(frames.count) frames")
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
            // print("[SimpleTimelineViewModel] handleScroll: frames is empty, ignoring")
            return
        }

        // Accumulate scroll delta
        scrollAccumulator += delta

        // Convert to frame steps
        // With sensitivity 0.1: need ~10 units of scroll to move 1 frame
        let sensitivity: CGFloat = 0.05
        let frameStep = Int(scrollAccumulator * sensitivity)

        // print("[SimpleTimelineViewModel] handleScroll: delta=\(delta), accumulator=\(scrollAccumulator), frameStep=\(frameStep)")

        guard frameStep != 0 else { return }

        // Reset accumulator after navigating
        scrollAccumulator = 0

        // print("[SimpleTimelineViewModel] Navigating from \(currentIndex) to \(currentIndex + frameStep)")

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
            let rawFrames = try await coordinator.getFrames(from: startDate, to: endDate, limit: 1000)
            print("[DateSearch] Got \(rawFrames.count) frames")

            guard !rawFrames.isEmpty else {
                error = "No frames found around \(targetDate)"
                isLoading = false
                return
            }

            // Preload video info for all frames
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

            // Find the frame closest to the target date in our centered set
            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex

            // Load image if needed
            loadImageIfNeeded()

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
}
