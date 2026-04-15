import App
import AppKit
import Foundation
import Shared
import SwiftyChrono
import SwiftUI

extension SimpleTimelineViewModel {
    private static let minimumFrameIDSearchValue: Int64 = 10_000

    public var enableFrameIDSearch: Bool {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: "enableFrameIDSearch")
    }

    // MARK: - Calendar Picker

    public func closeCalendarPicker() {
        isCalendarPickerVisible = false
        hoursWithFrames = []
        selectedCalendarDate = nil
        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
    }

    public func focusCalendarDateGrid() {
        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
    }

    public func handleCalendarPickerArrowKey(_ keyCode: UInt16) -> Bool {
        switch calendarKeyboardFocus {
        case .dateGrid:
            let dayOffset: Int
            switch keyCode {
            case 123: dayOffset = -1
            case 124: dayOffset = 1
            case 125: dayOffset = 7
            case 126: dayOffset = -7
            default: return false
            }

            moveCalendarDateSelection(byDayOffset: dayOffset)
            return true

        case .timeGrid:
            let hourStep: Int
            switch keyCode {
            case 123: hourStep = -1
            case 124: hourStep = 1
            case 125: hourStep = 3
            case 126: hourStep = -3
            default: return false
            }

            moveCalendarHourSelection(byHourOffset: hourStep)
            return true
        }
    }

    public func handleCalendarPickerEnterKey() -> Bool {
        switch calendarKeyboardFocus {
        case .dateGrid:
            guard let selectedDay = selectedCalendarDate else { return true }
            let normalizedDay = Calendar.current.startOfDay(for: selectedDay)

            if hoursWithFrames.isEmpty {
                Task {
                    await loadHoursForDate(normalizedDay)
                    await MainActor.run {
                        focusFirstAvailableCalendarHour()
                    }
                }
            } else {
                focusFirstAvailableCalendarHour()
            }
            return true

        case .timeGrid:
            guard let selectedHour = selectedCalendarHour,
                  let timestamp = firstFrameTimestamp(forHour: selectedHour) else {
                return true
            }

            Task {
                await navigateToHour(timestamp)
            }
            return true
        }
    }

    public func loadDatesWithFrames() async {
        do {
            let dates = try await coordinator.getDistinctDates(filters: filterCriteria)
            await MainActor.run {
                self.datesWithFrames = Set(dates)
            }

            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())

            if dates.contains(today) {
                await loadHoursForDate(today)
            } else if let mostRecent = dates.first {
                await loadHoursForDate(mostRecent)
            }
        } catch {
            Log.error("Failed to load dates with frames: \(error)", category: .ui)
        }
    }

    public func loadHoursForDate(_ date: Date) async {
        do {
            let hours = try await coordinator.getDistinctHoursForDate(date, filters: filterCriteria)
            await MainActor.run {
                self.selectedCalendarDate = date
                self.hoursWithFrames = hours
                if self.calendarKeyboardFocus == .timeGrid {
                    let validHours = self.availableCalendarHoursSorted()
                    if let selected = self.selectedCalendarHour, validHours.contains(selected) {
                    } else {
                        self.selectedCalendarHour = validHours.first
                    }
                } else {
                    self.selectedCalendarHour = nil
                }
            }
        } catch {
            Log.error("Failed to load hours for date: \(error)", category: .ui)
        }
    }

    public func navigateToHour(_ hour: Date) async {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isCalendarPickerVisible = false
            isDateSearchActive = false
        }
        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
        await navigateToDate(hour)
    }

    private func moveCalendarDateSelection(byDayOffset offset: Int) {
        guard let targetDate = nextCalendarDate(byDayOffset: offset) else { return }

        calendarKeyboardFocus = .dateGrid
        selectedCalendarHour = nil
        selectedCalendarDate = targetDate
        hoursWithFrames = []

        Task {
            await loadHoursForDate(targetDate)
        }
    }

    private func moveCalendarHourSelection(byHourOffset offset: Int) {
        let validHours = Set(availableCalendarHoursSorted())
        guard !validHours.isEmpty else { return }

        if selectedCalendarHour == nil {
            selectedCalendarHour = availableCalendarHoursSorted().first
            return
        }

        guard let currentHour = selectedCalendarHour else { return }

        var candidate = currentHour + offset
        while (0...23).contains(candidate) {
            if validHours.contains(candidate) {
                selectedCalendarHour = candidate
                return
            }
            candidate += offset
        }
    }

    private func nextCalendarDate(byDayOffset offset: Int) -> Date? {
        let sortedDates = availableCalendarDatesSorted()
        guard !sortedDates.isEmpty else { return nil }

        let calendar = Calendar.current
        let baseDate = calendar.startOfDay(for: selectedCalendarDate ?? sortedDates.last!)
        guard let rawTarget = calendar.date(byAdding: .day, value: offset, to: baseDate) else {
            return baseDate
        }
        let targetDate = calendar.startOfDay(for: rawTarget)

        if offset > 0 {
            return sortedDates.first(where: { $0 >= targetDate }) ?? sortedDates.last
        } else {
            return sortedDates.last(where: { $0 <= targetDate }) ?? sortedDates.first
        }
    }

    private func focusFirstAvailableCalendarHour() {
        guard let firstHour = availableCalendarHoursSorted().first else { return }
        calendarKeyboardFocus = .timeGrid
        selectedCalendarHour = firstHour
    }

    private func firstFrameTimestamp(forHour hour: Int) -> Date? {
        let calendar = Calendar.current
        return hoursWithFrames.sorted().first { date in
            calendar.component(.hour, from: date) == hour
        }
    }

    private func availableCalendarDatesSorted() -> [Date] {
        datesWithFrames.sorted()
    }

    private func availableCalendarHoursSorted() -> [Int] {
        let calendar = Calendar.current
        let uniqueHours = Set(hoursWithFrames.map { calendar.component(.hour, from: $0) })
        return uniqueHours.sorted()
    }

    private func navigateToDate(_ targetDate: Date) async {
        setLoadingState(true, reason: "navigateToDate")
        clearError()
        frameWindowStore.cancelBoundaryLoadTasks(reason: "navigateToDate")
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "navigateToDate.source")

        if isInLiveMode {
            setLivePresentationState(isActive: false, screenshot: nil)
            isTapeHidden = false
        }

        do {
            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "navigateToDate"
            )

            guard !framesWithVideoInfo.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(formatLocalDateForError(targetDate))")
                setLoadingState(false, reason: "navigateToDate.noFrames")
                return
            }

            applyNavigationFrameWindow(
                framesWithVideoInfo,
                clearDiskBufferReason: "calendar navigation",
                memoryLogContext: "calendar navigation"
            )
            clearPositionRecoveryHintForSupersedingNavigation()

            let closestIndex = findClosestFrameIndex(to: targetDate)
            currentIndex = closestIndex
            _ = recordCurrentPositionImmediatelyForUndo(reason: "navigateToDate.destination")

            refreshCurrentFramePresentation()
            _ = checkAndLoadMoreFrames(reason: "navigateToDate")
            setLoadingState(false, reason: "navigateToDate.success")
        } catch {
            self.setPresentationError("Failed to navigate: \(error.localizedDescription)")
            setLoadingState(false, reason: "navigateToDate.error")
        }
    }

    public func searchForDate(_ searchText: String, source: String = "timeline_date_search") async {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return }
        let normalizedPlayheadDaySearchText = TimelineDateSearchSupport.normalizedPlayheadDayReferenceInput(trimmedSearchText)
        let numericFrameID = Int64(trimmedSearchText)
        let qualifiesForFrameIDSearch = numericFrameID.map { $0 >= Self.minimumFrameIDSearchValue } ?? false
        var frameIDLookupAttempted = false

        DashboardViewModel.recordDateSearchSubmitted(
            coordinator: coordinator,
            source: source,
            query: trimmedSearchText,
            queryLength: trimmedSearchText.count,
            frameIDSearchEnabled: enableFrameIDSearch,
            lookedLikeFrameID: qualifiesForFrameIDSearch
        )

        setLoadingState(true, reason: "searchForDate")
        clearError()
        frameWindowStore.cancelBoundaryLoadTasks(reason: "searchForDate")
        dateJumpTraceID += 1
        let jumpTraceID = dateJumpTraceID
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForDate.source")

        if isInLiveMode {
            setLivePresentationState(isActive: false, screenshot: nil)
            isTapeHidden = false
        }

        do {
            if enableFrameIDSearch,
               qualifiesForFrameIDSearch,
               let frameID = numericFrameID {
                frameIDLookupAttempted = true
                if await searchForFrameID(frameID, showFailureUI: false) {
                    DashboardViewModel.recordDateSearchOutcome(
                        coordinator: coordinator,
                        source: source,
                        query: trimmedSearchText,
                        outcome: "frame_id_success",
                        queryLength: trimmedSearchText.count,
                        frameIDLookupAttempted: frameIDLookupAttempted
                    )
                    return
                }
            }

            let targetDate: Date
            if let playheadRelativeDate = parsePlayheadRelativeDateIfNeeded(normalizedPlayheadDaySearchText) {
                targetDate = playheadRelativeDate
            } else if let playheadDayReferenceDate = parsePlayheadDayReferenceIfNeeded(trimmedSearchText) {
                targetDate = playheadDayReferenceDate
            } else {
                guard let parsedDate = parseNaturalLanguageDate(normalizedPlayheadDaySearchText) else {
                    let parseFailedReason: String
                    let outcome: String
                    if frameIDLookupAttempted, let frameID = numericFrameID {
                        showErrorWithAutoDismiss("Frame #\(frameID) not found")
                        parseFailedReason = "searchForDate.frameIDNotFoundAfterParseFailed"
                        outcome = "frame_id_not_found"
                    } else {
                        showErrorWithAutoDismiss("Could not understand: \(searchText)")
                        parseFailedReason = "searchForDate.parseFailed"
                        outcome = "parse_failed"
                    }
                    setLoadingState(false, reason: parseFailedReason)
                    DashboardViewModel.recordDateSearchOutcome(
                        coordinator: coordinator,
                        source: source,
                        query: trimmedSearchText,
                        outcome: outcome,
                        queryLength: trimmedSearchText.count,
                        frameIDLookupAttempted: frameIDLookupAttempted
                    )
                    return
                }
                targetDate = parsedDate
            }

            let anchoredTargetDate = try await resolveDateSearchAnchorDate(
                parsedDate: targetDate,
                input: normalizedPlayheadDaySearchText
            )

            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: anchoredTargetDate) ?? anchoredTargetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: anchoredTargetDate) ?? anchoredTargetDate

            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: filterCriteria,
                reason: "searchForDate"
            )

            guard !framesWithVideoInfo.isEmpty else {
                showErrorWithAutoDismiss("No frames found around \(formatLocalDateForError(targetDate))")
                setLoadingState(false, reason: "searchForDate.noFrames")
                DashboardViewModel.recordDateSearchOutcome(
                    coordinator: coordinator,
                    source: source,
                    query: trimmedSearchText,
                    outcome: "no_frames",
                    queryLength: trimmedSearchText.count,
                    frameIDLookupAttempted: frameIDLookupAttempted
                )
                return
            }

            applyNavigationFrameWindow(
                framesWithVideoInfo,
                clearDiskBufferReason: "date search",
                memoryLogContext: "date search"
            )
            clearPositionRecoveryHintForSupersedingNavigation()

            let closestIndex = findClosestFrameIndex(to: anchoredTargetDate)
            currentIndex = closestIndex
            _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForDate.destination")
            logFrameWindowSummary(context: "POST searchForDate", traceID: jumpTraceID)

            refreshCurrentFramePresentation()
            _ = checkAndLoadMoreFrames(reason: "searchForDate")

            MemoryTracker.logMemoryState(
                context: "DATE SEARCH COMPLETE",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferFrameCount,
                oldestTimestamp: frameWindowStore.oldestLoadedTimestamp,
                newestTimestamp: frameWindowStore.newestLoadedTimestamp
            )

            setLoadingState(false, reason: "searchForDate.success")
            DashboardViewModel.recordDateSearchOutcome(
                coordinator: coordinator,
                source: source,
                query: trimmedSearchText,
                outcome: "success",
                queryLength: trimmedSearchText.count,
                frameIDLookupAttempted: frameIDLookupAttempted,
                frameCount: framesWithVideoInfo.count
            )
            closeDateSearch()

        } catch {
            self.setPresentationError("Failed to search for date: \(error.localizedDescription)")
            Log.error("[DateJump:\(jumpTraceID)] FAILED: \(error)", category: .ui)
            setLoadingState(false, reason: "searchForDate.error")
            DashboardViewModel.recordDateSearchOutcome(
                coordinator: coordinator,
                source: source,
                query: trimmedSearchText,
                outcome: "error",
                queryLength: trimmedSearchText.count,
                frameIDLookupAttempted: frameIDLookupAttempted
            )
        }
    }

    func searchForFrameID(
        _ frameID: Int64,
        includeHiddenSegments: Bool = false,
        showFailureUI: Bool = true
    ) async -> Bool {
        frameWindowStore.cancelBoundaryLoadTasks(reason: "searchForFrameID")
        cancelPendingStoppedPositionRecording()
        _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForFrameID.source")

        do {
            guard let frameWithVideo = try await fetchFrameWithVideoInfoByIDForLookup(id: FrameID(value: frameID)) else {
                if showFailureUI {
                    setPresentationError("Frame #\(frameID) not found")
                    setLoadingState(false, reason: "searchForFrameID.notFound")
                }
                return false
            }

            let targetFrame = frameWithVideo.frame
            let targetDate = targetFrame.timestamp

            let calendar = Calendar.current
            let startDate = calendar.date(byAdding: .minute, value: -10, to: targetDate) ?? targetDate
            let endDate = calendar.date(byAdding: .minute, value: 10, to: targetDate) ?? targetDate

            var jumpFilters = filterCriteria
            if includeHiddenSegments {
                jumpFilters.hiddenFilter = .showAll
            }
            let framesWithVideoInfo = try await fetchFramesWithVideoInfoLogged(
                from: startDate,
                to: endDate,
                limit: 1000,
                filters: jumpFilters,
                reason: "searchForFrameID"
            )

            guard !framesWithVideoInfo.isEmpty else {
                if showFailureUI {
                    showErrorWithAutoDismiss("No frames found around frame #\(frameID)")
                    setLoadingState(false, reason: "searchForFrameID.noFramesInWindow")
                }
                return false
            }

            applyNavigationFrameWindow(
                framesWithVideoInfo,
                clearDiskBufferReason: "frame ID search",
                memoryLogContext: "frame ID search"
            )
            clearPositionRecoveryHintForSupersedingNavigation()

            if let exactIndex = frames.firstIndex(where: { $0.frame.id.value == frameID }) {
                currentIndex = exactIndex
            } else {
                let closestIndex = findClosestFrameIndex(to: targetDate)
                currentIndex = closestIndex
            }
            _ = recordCurrentPositionImmediatelyForUndo(reason: "searchForFrameID.destination")

            timelineContextMenuSegmentIndex = currentIndex
            selectedFrameIndex = currentIndex

            refreshCurrentFramePresentation()
            _ = checkAndLoadMoreFrames(reason: "searchForFrameID")

            MemoryTracker.logMemoryState(
                context: "FRAME ID SEARCH COMPLETE",
                frameCount: frames.count,
                frameBufferCount: diskFrameBufferFrameCount,
                oldestTimestamp: frameWindowStore.oldestLoadedTimestamp,
                newestTimestamp: frameWindowStore.newestLoadedTimestamp
            )

            setLoadingState(false, reason: "searchForFrameID.success")
            closeDateSearch()

            return true

        } catch {
            Log.error("[FrameIDSearch] Error: \(error)", category: .ui)
            return false
        }
    }

    private func fetchFrameWithVideoInfoByIDForLookup(id: FrameID) async throws -> FrameWithVideoInfo? {
#if DEBUG
        if let override = test_frameLookupHooks.getFrameWithVideoInfoByID {
            return try await override(id)
        }
#endif
        return try await coordinator.getFrameWithVideoInfoByID(id: id)
    }

    private func parsePlayheadRelativeDateIfNeeded(_ text: String) -> Date? {
        let baseTimestamp: Date
        if let currentTimestamp {
            baseTimestamp = currentTimestamp
        } else {
            baseTimestamp = Date()
            Log.warning("[DateSearch] Relative '\(text)' had no playhead timestamp; falling back to now", category: .ui)
        }

        return TimelineDateSearchSupport.parsePlayheadRelativeDateIfNeeded(
            text,
            relativeTo: baseTimestamp
        )
    }

    private func parsePlayheadRelativeDate(_ normalizedText: String, relativeTo baseTimestamp: Date) -> Date? {
        TimelineDateSearchSupport.parsePlayheadRelativeDate(
            normalizedText,
            relativeTo: baseTimestamp
        )
    }

    private func parsePlayheadDayReferenceIfNeeded(_ text: String) -> Date? {
        guard TimelineDateSearchSupport.hasPlayheadDayReference(text) else {
            return nil
        }

        let normalizedInput = TimelineDateSearchSupport.normalizedPlayheadDayReferenceInput(text)
        let baseTimestamp: Date
        if let currentTimestamp {
            baseTimestamp = currentTimestamp
        } else {
            baseTimestamp = Date()
            Log.warning("[DateSearch] Same-day reference '\(normalizedInput)' had no playhead timestamp; falling back to now", category: .ui)
        }

        return TimelineDateSearchSupport.parsePlayheadDayReferenceIfNeeded(
            text,
            relativeTo: baseTimestamp
        )
    }

    private func parseNaturalLanguageDate(_ text: String, now: Date = Date()) -> Date? {
        TimelineDateSearchSupport.parseNaturalLanguageDate(text, now: now)
    }

#if DEBUG
    func test_parseNaturalLanguageDateForDateSearch(_ text: String, now: Date) -> Date? {
        parseNaturalLanguageDate(text, now: now)
    }

    func test_parsePlayheadRelativeDateForDateSearch(_ text: String, baseTimestamp: Date) -> Date? {
        TimelineDateSearchSupport.parsePlayheadRelativeDateIfNeeded(
            text,
            relativeTo: baseTimestamp
        )
    }

    func test_setBoundaryPaginationState(hasMoreOlder: Bool, hasMoreNewer: Bool) {
        frameWindowStore.setBoundaryPaginationState(
            hasMoreOlder: hasMoreOlder,
            hasMoreNewer: hasMoreNewer
        )
    }

    func test_loadOlderFrames(reason: String = "test") async {
        await loadOlderFrames(reason: reason, cmdFTrace: nil)
    }

    func test_loadNewerFrames(reason: String = "test") async {
        await loadNewerFrames(reason: reason, cmdFTrace: nil)
    }

    func test_boundaryPaginationState() -> (
        hasMoreOlder: Bool,
        hasMoreNewer: Bool,
        hasReachedAbsoluteStart: Bool,
        hasReachedAbsoluteEnd: Bool
    ) {
        frameWindowStore.boundaryPaginationState()
    }

    func test_updateWindowBoundaries() {
        frameWindowStore.updateWindowBoundaries(frames: frames)
    }
#endif

    private typealias DateSearchAnchorMode = TimelineDateSearchSupport.DateSearchAnchorMode
    private typealias RelativeLookbackRange = TimelineDateSearchSupport.RelativeLookbackRange

    private func resolveDateSearchAnchorDate(parsedDate: Date, input: String) async throws -> Date {
        if let lookbackRange = relativeLookbackRangeIfNeeded(parsedDate: parsedDate, input: input) {
            let anchorReason: String
            let modeLabel: String
            switch lookbackRange.anchorEdge {
            case .first:
                anchorReason = "searchForDate.anchor.firstFrameInRelativeLookback"
                modeLabel = "firstFrameInRelativeLookback"
            case .last:
                anchorReason = "searchForDate.anchor.lastFrameInRelativeLookback"
                modeLabel = "lastFrameInRelativeLookback"
            }

            Log.info(
                "[DateSearchAnchor] mode=\(modeLabel) parsed=\(Log.timestamp(from: parsedDate)) bucket=\(Log.timestamp(from: lookbackRange.start))->\(Log.timestamp(from: lookbackRange.end))",
                category: .ui
            )

            switch lookbackRange.anchorEdge {
            case .first:
                let firstFrame = try await fetchFramesWithVideoInfoLogged(
                    from: lookbackRange.start,
                    to: lookbackRange.end,
                    limit: 1,
                    filters: filterCriteria,
                    reason: anchorReason
                ).first
                if let anchoredTimestamp = firstFrame?.frame.timestamp {
                    return anchoredTimestamp
                }
            case .last:
                let boundedEndTimestamp = lookbackRange.end.addingTimeInterval(Self.boundedLoadBoundaryEpsilonSeconds)
                let lastFrameCandidate = try await fetchFramesWithVideoInfoBeforeLogged(
                    timestamp: boundedEndTimestamp,
                    limit: 1,
                    filters: filterCriteria,
                    reason: anchorReason
                ).first
                if let anchoredTimestamp = lastFrameCandidate?.frame.timestamp,
                   anchoredTimestamp >= lookbackRange.start,
                   anchoredTimestamp <= lookbackRange.end {
                    return anchoredTimestamp
                }
            }

            return parsedDate
        }

        let mode = inferDateSearchAnchorMode(for: input)
        guard mode != .exact else { return parsedDate }
        guard let bucket = bucketRange(for: parsedDate, mode: mode) else { return parsedDate }
        Log.info(
            "[DateSearchAnchor] mode=\(mode.rawValue) parsed=\(Log.timestamp(from: parsedDate)) bucket=\(Log.timestamp(from: bucket.start))->\(Log.timestamp(from: bucket.end))",
            category: .ui
        )

        let firstFrame = try await fetchFramesWithVideoInfoLogged(
            from: bucket.start,
            to: bucket.end,
            limit: 1,
            filters: filterCriteria,
            reason: "searchForDate.anchor.\(mode.rawValue)"
        ).first

        guard let anchoredTimestamp = firstFrame?.frame.timestamp else {
            return parsedDate
        }

        return anchoredTimestamp
    }

    private func relativeLookbackRangeIfNeeded(parsedDate: Date, input: String) -> RelativeLookbackRange? {
        TimelineDateSearchSupport.relativeLookbackRangeIfNeeded(
            parsedDate: parsedDate,
            input: input
        )
    }

    private func inferDateSearchAnchorMode(for input: String) -> DateSearchAnchorMode {
        TimelineDateSearchSupport.inferDateSearchAnchorMode(for: input)
    }

    private func bucketRange(for date: Date, mode: DateSearchAnchorMode) -> (start: Date, end: Date)? {
        TimelineDateSearchSupport.bucketRange(for: date, mode: mode)
    }

    private func findClosestFrameIndex(to targetDate: Date) -> Int {
        Self.findClosestFrameIndex(in: frames, to: targetDate)
    }

    static func findClosestFrameIndex(in timelineFrames: [TimelineFrame], to targetDate: Date) -> Int {
        guard !timelineFrames.isEmpty else { return 0 }

        var closestIndex = 0
        var smallestDiff = abs(timelineFrames[0].frame.timestamp.timeIntervalSince(targetDate))

        for (index, timelineFrame) in timelineFrames.enumerated() {
            let diff = abs(timelineFrame.frame.timestamp.timeIntervalSince(targetDate))
            if diff < smallestDiff {
                smallestDiff = diff
                closestIndex = index
            }
        }

        return closestIndex
    }

    private static let boundedLoadBoundaryEpsilonSeconds = TimelineDateSearchSupport.boundedLoadBoundaryEpsilonSeconds
}
