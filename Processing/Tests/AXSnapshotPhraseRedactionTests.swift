import CoreGraphics
import XCTest
import Shared
@testable import Processing

final class AXSnapshotPhraseRedactionTests: XCTestCase {

    private func snapshot(_ root: AXNodeSnapshot) -> AXTreeSnapshot {
        AXTreeSnapshot(bundleID: "com.example", processID: 1, root: root, nodeCount: 4, isTruncated: false, walkMilliseconds: 3)
    }

    func testProtectedPhraseIsRemovedFromEveryStringBeforeStorage() {
        let original = snapshot(
            AXNodeSnapshot(
                role: "AXWindow",
                title: "Inbox",
                children: [
                    AXNodeSnapshot(role: "AXStaticText", value: "Your api key is ready"),
                    AXNodeSnapshot(role: "AXImage", label: "api key"),
                    AXNodeSnapshot(role: "AXStaticText", value: "Weekly report")
                ]
            )
        )

        let scrubbed = FrameProcessingQueue.removingProtectedPhrases(from: original, phraseStrings: ["api key"])

        XCTAssertEqual(scrubbed.root.title, "Inbox")
        XCTAssertNil(scrubbed.root.children[0].value)
        XCTAssertNil(scrubbed.root.children[1].label)
        XCTAssertEqual(scrubbed.root.children[2].value, "Weekly report")
        XCTAssertEqual(scrubbed.root.children.count, 3)
    }

    func testSnapshotIsUnchangedWithoutProtectedPhrases() {
        let original = snapshot(AXNodeSnapshot(role: "AXStaticText", value: "api key"))

        XCTAssertEqual(FrameProcessingQueue.removingProtectedPhrases(from: original, phraseStrings: []), original)
        XCTAssertEqual(
            FrameProcessingQueue.removingProtectedPhrases(from: original, phraseStrings: ["calendar"]),
            original
        )
    }
}
