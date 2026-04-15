#if DEBUG
import AppKit
import Shared
import App
import Database
import Processing

struct TimelineRefreshProcessingStatusesTestHooks {
    var getFrameProcessingStatuses: (([Int64]) async throws -> [Int64: Int])?
    var getFrameWithVideoInfoByID: ((FrameID) async throws -> FrameWithVideoInfo?)?
}

struct TimelineRefreshFrameDataTestHooks {
    var getMostRecentFramesWithVideoInfo: ((Int, FilterCriteria) async throws -> [FrameWithVideoInfo])?
    var now: (() -> Date)?
}

struct TimelineWindowFetchTestHooks {
    var getFramesWithVideoInfo: ((Date, Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo])?
    var getFramesWithVideoInfoBefore: ((Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo])?
    var getFramesWithVideoInfoAfter: ((Date, Int, FilterCriteria, String) async throws -> [FrameWithVideoInfo])?
}

struct TimelineForegroundFrameLoadTestHooks {
    var loadFrameData: ((TimelineFrame) async throws -> Data)?
}

struct TimelineFrameLookupTestHooks {
    var getFrameWithVideoInfoByID: ((FrameID) async throws -> FrameWithVideoInfo?)?
}

struct TimelineFrameOverlayLoadTestHooks {
    var getURLBoundingBox: ((Date, FrameSource) async throws -> URLBoundingBox?)?
    var getOCRStatus: ((FrameID) async throws -> OCRProcessingStatus)?
    var getAllOCRNodes: ((FrameID, FrameSource) async throws -> [OCRNodeWithText])?
}

struct TimelineDragStartStillOCRTestHooks {
    var recognizeTextFromCGImage: ((CGImage) async throws -> [TextRegion])?
}

struct TimelineBlockCommentsTestHooks {
    var getCommentsForSegments: (([SegmentID]) async throws -> [TimelineLinkedSegmentComment])?
    var createCommentForSegments: ((
        _ body: String,
        _ segmentIDs: [SegmentID],
        _ attachments: [SegmentCommentAttachment],
        _ frameID: FrameID?,
        _ author: String?
    ) async throws -> AppCoordinator.SegmentCommentCreateResult)?
}

struct TimelineTapeIndicatorRefreshTestHooks {
    var fetchIndicatorData: (() async throws -> (
        tags: [Tag],
        segmentTagsMap: [Int64: Set<Int64>],
        segmentCommentCountsMap: [Int64: Int]
    ))?
}

struct TimelineAvailableAppsForFilterTestHooks {
    var getInstalledApps: (() -> [AppInfo])?
    var getDistinctAppBundleIDs: ((FrameSource?) async throws -> [String])?
    var resolveAllBundleIDs: (([String]) -> [AppInfo])?
    var skipSupportingPanelDataLoad = false
}
#endif
