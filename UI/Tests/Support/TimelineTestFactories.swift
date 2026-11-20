import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

enum TimelineTestFactories {
    static func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String = "test.app",
        appName: String = "Test App",
        processingStatus: Int = 2,
        source: FrameSource = .native
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: appName,
                displayID: 1
            ),
            source: source
        )
        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: processingStatus)
    }

    static func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String = "test.app",
        appName: String = "Test App",
        processingStatus: Int = 2,
        videoPath: String? = nil
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: appName,
                displayID: 1
            )
        )
        let videoInfo = FrameVideoInfo(
            videoPath: videoPath ?? "/tmp/test-(id).mp4",
            frameIndex: frameIndex,
            frameRate: 30,
            width: 1920,
            height: 1080,
            isVideoFinalized: true
        )
        return FrameWithVideoInfo(frame: frame, videoInfo: videoInfo, processingStatus: processingStatus)
    }
}
