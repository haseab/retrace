import XCTest
import Shared
@testable import Processing

final class AccessibilityCorrectionTests: XCTestCase {
    func testCapturedVisionErrorsAndNumbersCorrectWithoutAddingSentences() {
        let bounds = CGRect(x: 10, y: 20, width: 500, height: 20)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Please review the accommodation requirements before confirming your reservation.", bounds: bounds, precise: true),
            .init(text: "Invoice 100", bounds: CGRect(x: 10,y: 70,width: 100,height: 20), precise: true)
        ])
        let source = TextRegion(frameID: .init(value: 1), text: "Ploaso reviow the accommodation requirements before confirming your reservation.", bounds: bounds)
        let result = AccessibilityOCRCorrector.correct(source, snapshot: snapshot)
        XCTAssertEqual(result.text, snapshot.elements[0].text)
        XCTAssertEqual(result.bounds, bounds)
        let invoice = TextRegion(frameID: .init(value: 1), text: "Invoice 1O0", bounds: snapshot.elements[1].bounds)
        XCTAssertEqual(AccessibilityOCRCorrector.correct(invoice, snapshot: snapshot).text, "Invoice 100")
    }
    func testAmbiguousAndDistantReferencesLeaveOCRUnchanged() {
        let bounds = CGRect(x: 0,y: 0,width: 200,height: 20)
        let source = TextRegion(frameID: .init(value: 1), text: "Invoice 1O0", bounds: bounds)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Invoice 100", bounds: bounds, precise: true),
            .init(text: "Invoice 110", bounds: bounds, precise: true)
        ])
        XCTAssertEqual(AccessibilityOCRCorrector.correct(source, snapshot: snapshot), source)
        let distant = AccessibilitySnapshot(capturedAt: Date(), elements: [.init(text: "Invoice 100", bounds: bounds.offsetBy(dx: 0, dy: 100), precise: true)])
        XCTAssertEqual(AccessibilityOCRCorrector.correct(source, snapshot: distant), source)
    }
    func testSentenceBoundaryMismatchDoesNotRepairMergedOCR() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 30)
        let region = TextRegion(frameID: .init(value: 1), text: "Your subscrlption renews tomorrow after the trial", bounds: bounds)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Your subscription renews. Tomorrow after the trial", bounds: bounds, precise: false)
        ])
        XCTAssertEqual(AccessibilityOCRCorrector.correct(region, snapshot: snapshot), region)
    }
}
