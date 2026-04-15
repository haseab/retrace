import Shared

extension SimpleTimelineViewModel {
    // MARK: - Timeline Context Actions

    public func requestDeleteFromTimelineMenu() {
        guard let index = timelineContextMenuSegmentIndex else {
            dismissTimelineContextMenu()
            return
        }

        selectedFrameIndex = index
        dismissTimelineContextMenu()
        showDeleteConfirmation = true
    }

    public func toggleQuickAppFilterForSelectedTimelineSegment() {
        guard let index = timelineContextMenuSegmentIndex,
              index >= 0,
              index < frames.count else {
            dismissTimelineContextMenu()
            return
        }

        dismissTimelineContextMenu()

        let bundleID = frames[index].frame.metadata.appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundleID.isEmpty else { return }

        if isSingleAppOnlyIncludeFilter(filterCriteria, matching: bundleID) {
            clearAllFilters()
            return
        }

        var criteria = FilterCriteria()
        criteria.selectedApps = Set([bundleID])
        criteria.appFilterMode = .include
        replacePendingFilterCriteria(criteria)
        applyFilters()
    }

    func isSingleAppOnlyIncludeFilter(_ criteria: FilterCriteria, matching bundleID: String) -> Bool {
        guard criteria.appFilterMode == .include,
              let selectedApps = criteria.selectedApps,
              selectedApps.count == 1,
              selectedApps.contains(bundleID) else {
            return false
        }

        let hasNoSources = criteria.selectedSources == nil || criteria.selectedSources?.isEmpty == true
        let hasNoTags = criteria.selectedTags == nil || criteria.selectedTags?.isEmpty == true
        let hasNoWindowFilter = criteria.windowNameFilter?.isEmpty ?? true
        let hasNoBrowserFilter = criteria.browserUrlFilter?.isEmpty ?? true

        return hasNoSources &&
            criteria.hiddenFilter == .hide &&
            criteria.commentFilter == .allFrames &&
            hasNoTags &&
            criteria.tagFilterMode == .include &&
            hasNoWindowFilter &&
            hasNoBrowserFilter &&
            criteria.effectiveDateRanges.isEmpty
    }

    public func isFrameHidden(at index: Int) -> Bool {
        guard index >= 0 && index < frames.count else { return false }
        let segmentId = SegmentID(value: frames[index].frame.segmentID.value)
        return hiddenSegmentIds.contains(segmentId)
    }
}
