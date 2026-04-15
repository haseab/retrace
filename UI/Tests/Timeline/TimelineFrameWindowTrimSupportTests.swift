import XCTest
import Shared
@testable import Retrace

final class TimelineFrameWindowTrimSupportTests: XCTestCase {
    func testMakeDeferredTrimDecisionUsesCurrentFrameWhenNewestTrimIsDeferred() {
        let base = Date(timeIntervalSince1970: 1_700_060_000)
        let frames = makeFrames(count: 6, start: base)

        let decision = TimelineFrameWindowTrimSupport.makeDeferredTrimDecision(
            frames: frames,
            preserveDirection: .newer,
            maxFrames: 4,
            allowDeferral: true,
            isActivelyScrolling: true,
            currentFrame: frames[4],
            anchorFrameID: nil,
            anchorTimestamp: nil
        )

        XCTAssertEqual(decision?.anchorFrameID?.value, 5)
        XCTAssertEqual(decision?.anchorTimestamp, base.addingTimeInterval(4))
    }

    func testMakeDeferredTrimDecisionReturnsNilWhenTrimShouldApplyImmediately() {
        let base = Date(timeIntervalSince1970: 1_700_060_000)
        let frames = makeFrames(count: 6, start: base)

        XCTAssertNil(
            TimelineFrameWindowTrimSupport.makeDeferredTrimDecision(
                frames: frames,
                preserveDirection: .older,
                maxFrames: 4,
                allowDeferral: true,
                isActivelyScrolling: true,
                currentFrame: frames[1],
                anchorFrameID: nil,
                anchorTimestamp: nil
            )
        )

        XCTAssertNil(
            TimelineFrameWindowTrimSupport.makeDeferredTrimDecision(
                frames: frames,
                preserveDirection: .newer,
                maxFrames: 4,
                allowDeferral: false,
                isActivelyScrolling: true,
                currentFrame: frames[4],
                anchorFrameID: nil,
                anchorTimestamp: nil
            )
        )
    }

    func testApplyTrimPreservingOlderDropsNewestFramesAndRefreshesBoundaries() {
        let base = Date(timeIntervalSince1970: 1_700_060_000)
        let frames = makeFrames(count: 6, start: base)

        let result = TimelineFrameWindowTrimSupport.applyTrim(
            frames: frames,
            preserveDirection: .older,
            currentIndex: 1,
            maxFrames: 4,
            currentFrame: frames[1],
            anchorFrameID: nil,
            anchorTimestamp: nil
        )

        XCTAssertEqual(result?.frames.map(\.frame.id.value), [1, 2, 3, 4])
        XCTAssertNil(result?.pendingCurrentIndexAfterFrameReplacement)
        XCTAssertEqual(result?.excessCount, 2)
        XCTAssertEqual(result?.oldestTimestamp, base)
        XCTAssertEqual(result?.newestTimestamp, base.addingTimeInterval(3))

        switch result?.boundaryToRestoreAfterTrim {
        case .newer?:
            break
        default:
            XCTFail("Expected trim preserving older frames to restore newer pagination")
        }
    }

    func testApplyTrimPreservingNewerAnchorsToCurrentFrameAndSetsReplacementIndex() {
        let base = Date(timeIntervalSince1970: 1_700_060_000)
        let frames = makeFrames(count: 6, start: base)

        let result = TimelineFrameWindowTrimSupport.applyTrim(
            frames: frames,
            preserveDirection: .newer,
            currentIndex: 5,
            maxFrames: 4,
            currentFrame: frames[3],
            anchorFrameID: nil,
            anchorTimestamp: nil
        )

        XCTAssertEqual(result?.frames.map(\.frame.id.value), [3, 4, 5, 6])
        XCTAssertEqual(result?.pendingCurrentIndexAfterFrameReplacement, 1)
        XCTAssertEqual(result?.excessCount, 2)
        XCTAssertEqual(result?.oldestTimestamp, base.addingTimeInterval(2))
        XCTAssertEqual(result?.newestTimestamp, base.addingTimeInterval(5))
        XCTAssertEqual(result?.resolvedAnchorFrameID?.value, 4)
        XCTAssertEqual(result?.resolvedAnchorTimestamp, base.addingTimeInterval(3))

        switch result?.boundaryToRestoreAfterTrim {
        case .older?:
            break
        default:
            XCTFail("Expected trim preserving newer frames to restore older pagination")
        }
    }

    private func makeFrames(count: Int, start: Date) -> [TimelineFrame] {
        (0..<count).map { offset in
            let id = Int64(offset + 1)
            return TimelineFrame(
                frame: FrameReference(
                    id: FrameID(value: id),
                    timestamp: start.addingTimeInterval(TimeInterval(offset)),
                    segmentID: AppSegmentID(value: id),
                    frameIndexInSegment: offset,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.Safari",
                        appName: "Safari",
                        displayID: 1
                    )
                ),
                videoInfo: nil,
                processingStatus: 2
            )
        }
    }
}
