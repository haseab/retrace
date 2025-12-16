import SwiftUI
import Combine
import Shared
import App

/// ViewModel for the Timeline view
/// Manages frame navigation, playback, and session filtering
@MainActor
public class TimelineViewModel: ObservableObject {

    // MARK: - Published State

    @Published public var currentFrame: FrameReference?
    @Published public var currentFrameImage: NSImage?
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

    // MARK: - Dependencies

    private let coordinator: AppCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var playbackTimer: Timer?

    // MARK: - Constants

    private let frameLoadBatchSize = 100

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

    // MARK: - Frame Navigation

    public func selectFrame(_ frame: FrameReference) async {
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
        do {
            let imageData = try await coordinator.getFrameImage(
                segmentID: frame.segmentID,
                timestamp: frame.timestamp
            )

            if let image = NSImage(data: imageData) {
                currentFrameImage = image
            } else {
                error = "Failed to decode frame image"
            }
        } catch {
            self.error = "Failed to load frame image: \(error.localizedDescription)"
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
