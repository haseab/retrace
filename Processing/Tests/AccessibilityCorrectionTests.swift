import XCTest
import Shared
@testable import Processing

final class AccessibilityCorrectionTests: XCTestCase {
    private let bounds = CGRect(x: 20, y: 20, width: 700, height: 20)

    private func repair(_ raw: String, reference: String, recognitionLanguages: [String] = ["en-US"], following: Bool = true) async -> String {
        // Original RXCASE059 lines provide actual outside text for the character
        // alignment regressions. Isolated-node abstention has its own regression.
        let before = "Renée Müller discussed the façade with José García at 14:35."
        let after = "Naïve comparisons must preserve the résumé and its accents."
        let regions = ([before, raw] + (following ? [after] : [])).enumerated().map { i, text in
            TextRegion(frameID: .init(value: 1), text: text, bounds: bounds.offsetBy(dx: 0, dy: CGFloat(i) * 35))
        }
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: ([before, reference] + (following ? [after] : [])).joined(separator: " "),
                  bounds: CGRect(x: 0, y: 0, width: 740, height: 140), precise: false)
        ])
        return await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot,
            recognitionLanguages: recognitionLanguages)[1].text
    }

    func testRecordedInflectionAndIdentifierErrorsRepairBetweenAnchors() async {
        // Actual small-print Vision errors: RXCASE020 and RXCASE015, 0.75 scale.
        let result = await repair(
            "Please review the reconciliation requiremants before confirming your resarvason.",
            reference: "Please review the reconciliation requirements before confirming your reservation.")
        XCTAssertEqual(result, "Please review the reconciliation requirements before confirming your reservation.")
        let identifier = await repair(
            "The reference isentier is AB10015 and the departure sme is 14:35.",
            reference: "The reference identifier is AB10015 and the departure time is 14:35.")
        XCTAssertEqual(identifier, "The reference identifier is AB10015 and the departure time is 14:35.")
    }

    func testAlignedWordEdgesAdoptAXWithoutAppendingUnobservedSuffix() async {
        // Actual RXCASE015 output: passage identity permits repairing the damaged prefix.
        let result = await repair(
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            reference: "Please review the maintenance requirements before confirming your reservation.")
        XCTAssertEqual(result, "Please review the maintenance requirements before confirming your reservation.")
        let missingSuffix = await repair(
            "Coordinator Morgan Ellis approved the subscription schedule for November",
            reference: "Coordinator Morgan Ellis approved the subscription schedule for November 5. AXONLY_MUST_NOT_BE_APPENDED",
            following: false)
        XCTAssertEqual(missingSuffix, "Coordinator Morgan Ellis approved the subscription schedule for November")
    }

    func testNeighborAnchorsBoundAnEntireDamagedLineWithReversedAXArrayOrder() async {
        let raw = ["Invoice 10015 covars 27 itema at a total of $1435.75.",
                   "The referenco isentier is AB10015 and iho departure sme is 14:35.",
                   "Coordinator Morgan Ellis approved the maintenance schedule for November 16."]
        let reference = ["Invoice 10015 covers 27 items at a total of $1435.75.",
                         "The reference identifier is AB10015 and the departure time is 14:35.",
                         "Coordinator Morgan Ellis approved the maintenance schedule for November 16."]
        let regions = raw.enumerated().map { i, text in
            TextRegion(frameID: .init(value: 1), text: text, bounds: bounds.offsetBy(dx: 0, dy: CGFloat(i) * 35))
        }
        let elements = reference.enumerated().map { i, text in
            AccessibilitySnapshot.Element(text: text, bounds: regions[i].bounds, precise: false)
        }
        let result = await AccessibilityOCRCorrector.correct(regions,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: elements.reversed()))
        XCTAssertEqual(result.map(\.text), reference)
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testRecordedSplitIdentifierRepairsWithoutDictionaryOrLanguageGate() async {
        let raw = "const invoice Total = 1465.75;"
        let expected = "const invoiceTotal = 1465.75;"
        let result = await repair(raw, reference: expected)
        XCTAssertEqual(result, expected)
        let resultOtherLanguage = await repair(raw, reference: expected, recognitionLanguages: ["fr-FR"])
        XCTAssertEqual(resultOtherLanguage, expected)
    }

    func testCompetingReferencesAndRepeatedPassagesAreRejected() async {
        let raw = "The invoice reference is 1O0 and the total remains unchanged."
        let region = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "The invoice reference is 100 and the total remains unchanged.", bounds: bounds, precise: false),
            .init(text: "The invoice reference is 110 and the total remains unchanged.", bounds: bounds, precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct(region, snapshot: snapshot)
        XCTAssertEqual(result, region)
        let repeated = await repair(raw,
            reference: "The invoice reference is 100 and the total remains unchanged. The invoice reference is 110 and the total remains unchanged.")
        XCTAssertEqual(repeated, raw)
    }

    func testAlignedPassageAdoptsIdentifiersAndNumbersWithoutLocalEditVeto() async {
        let raw = "Please review the maintenance requirements for ZXQVV9 before confirming your reservation."
        let result = await repair(raw,
            reference: "Please review the maintenance requirements for ABC123 before confirming your reservation.")
        XCTAssertEqual(result, "Please review the maintenance requirements for ABC123 before confirming your reservation.")
        let numeric = await repair("The invoice reference is 100 and the total remains unchanged.",
            reference: "The invoice reference is 110 and the total remains unchanged.")
        XCTAssertEqual(numeric, "The invoice reference is 110 and the total remains unchanged.")
    }

    func testIsolatedDistantReferenceIsRejectedAndAlignedPunctuationIsRetained() async {
        let region = TextRegion(frameID: .init(value: 1), text: "The reference isentier is AB10015 and the departure sme is 14:35.", bounds: bounds)
        let distant = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "The reference identifier is AB10015 and the departure time is 14:35.", bounds: bounds.offsetBy(dx: 0, dy: 100), precise: true)
        ])
        let result = await AccessibilityOCRCorrector.correct(region, snapshot: distant)
        XCTAssertEqual(result, region)
        XCTAssertEqual(result.bounds, region.bounds)
        let merged = "Your subscrlption renews tomorrow after the trial"
        let corrected = await repair(merged, reference: "Your subscription renews. Tomorrow after the trial")
        XCTAssertEqual(corrected, "Your subscription renews. Tomorrow after the trial")
    }

    func testClippedPrefixAndReorderedColumnsDoNotBorrowText() async {
        let left = TextRegion(frameID: .init(value: 1), text: "Please review the maintenance requiremants before confirming your reservation.", bounds: bounds)
        let right = TextRegion(frameID: .init(value: 1), text: "Please review the laboratory requiremants before confirming your reservation.", bounds: bounds.offsetBy(dx: 900, dy: 0))
        let leftBefore = TextRegion(frameID: .init(value: 1), text: "Renée Müller discussed the façade with José García at 14:35.", bounds: bounds.offsetBy(dx: 0, dy: -25))
        let leftAfter = TextRegion(frameID: .init(value: 1), text: "Naïve comparisons must preserve the résumé and its accents.", bounds: bounds.offsetBy(dx: 0, dy: 35))
        let rightBefore = TextRegion(frameID: .init(value: 1), text: "The reference identifier is AB10099 and the departure time is 14:35.", bounds: bounds.offsetBy(dx: 900, dy: -25))
        let rightAfter = TextRegion(frameID: .init(value: 1), text: "Coordinator Morgan Ellis approved the conference schedule for November 16.", bounds: bounds.offsetBy(dx: 900, dy: 35))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: rightBefore.text + " Please review the laboratory requirements before confirming your reservation. " + rightAfter.text,
                  bounds: CGRect(x: 900, y: -10, width: 740, height: 100), precise: false),
            .init(text: "HIDDEN_PREFIX " + leftBefore.text + " Please review the maintenance requirements before confirming your reservation. " + leftAfter.text,
                  bounds: CGRect(x: 0, y: -10, width: 740, height: 100), precise: false)
        ])
        let regions = [rightBefore, right, rightAfter, leftBefore, left, leftAfter]
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result[1].text, "Please review the laboratory requirements before confirming your reservation.")
        XCTAssertEqual(result[4].text, "Please review the maintenance requirements before confirming your reservation.")
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testRealNativeAXWordBoundariesDoNotSplitCorrectOCRWords() async {
        // Actual screenshot/native-AX replay exposed cross-word normalized matches.
        for (raw, reference) in [("Specifications", "Specification section and browser compatibility"),
            ("*A 59 languages v", "real-time translation of foreign-language signs on a smartphone")] {
            let region = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds)
            let result = await AccessibilityOCRCorrector.correct(region,
                snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                    .init(text: reference, bounds: .zero, precise: false)
                ]))
            XCTAssertEqual(result, region)
        }
    }

    func testTwoVisualBlocksCannotClaimTheSameAXSpan() async {
        let raw = "Please review the maintenance requiremants before confirming your reservation."
        let left = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds)
        let right = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds.offsetBy(dx: 900, dy: 0))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Please review the maintenance requirements before confirming your reservation.",
                bounds: CGRect(x: 0, y: 0, width: 1700, height: 100), precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct([left, right], snapshot: snapshot)
        XCTAssertEqual(result, [left, right])
    }

    func testAlignmentHandlesInsertionsDeletionsAndMissingWords() async {
        // RXCASE020 contains the actual Vision spelling "reconcliation".
        let missing = await repair("Please review the reconcliation requirements before confirming your reservation.",
            reference: "Please review the reconciliation requirements before confirming your reservation.")
        XCTAssertEqual(missing, "Please review the reconciliation requirements before confirming your reservation.")
        let extra = await repair("Please review the requiremments before confirming your reservation.",
            reference: "Please review the requirements before confirming your reservation.")
        XCTAssertEqual(extra, "Please review the requirements before confirming your reservation.")
        let omittedWord = "Please review the requirements before confirming your reservation."
        let corrected = await repair(omittedWord,
            reference: "Please review the revised requirements before confirming your reservation.")
        XCTAssertEqual(corrected, "Please review the revised requirements before confirming your reservation.")
    }

    func testRecordedPassageAdoptsSeverelyDamagedWordsWithoutLocalEditLimit() async {
        // Actual RXCASE011 OCR after the easier repairs, leaving a five-edit word.
        let approved = await repair(
            "Coordinator Morgan Ellis ancnovmi the reservation schedule for November 12",
            reference: "Coordinator Morgan Ellis approved the reservation schedule for November 12.")
        XCTAssertEqual(approved, "Coordinator Morgan Ellis approved the reservation schedule for November 12.")

        // Actual RXCASE015 0.75-scale Vision text, not generated typo substitutions.
        let raw = [
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            "Invoice 10015 covars 27 itema at a total of $1435.75.",
            "The referenco isentier is AB10015 and iho departure sme is 14:35.",
            "Coordinasee Moman Ella agoroved the maintenarne schedule for Novorber 16"
        ]
        let expected = [
            "Please review the maintenance requirements before confirming your reservation.",
            "Invoice 10015 covers 27 items at a total of $1435.75.",
            "The reference identifier is AB10015 and the departure time is 14:35.",
            "Coordinator Morgan Ellis approved the maintenance schedule for November 16."
        ]
        let regions = raw.enumerated().map { i, text in
            TextRegion(frameID: .init(value: 1), text: text, bounds: bounds.offsetBy(dx: 0, dy: CGFloat(i) * 35))
        }
        let elements = expected.enumerated().map { i, text in
            AccessibilitySnapshot.Element(text: text, bounds: regions[i].bounds, precise: false)
        }
        let result = await AccessibilityOCRCorrector.correct(regions,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: elements))
        XCTAssertEqual(result.map(\.text), expected)
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testMatchingFragmentsKeepSeparateOwnershipWithoutInventingAXOnlyText() async {
        let first = TextRegion(frameID: .init(value: 1), text: "Invoice 10024 covers", bounds: CGRect(x: 20, y: 20, width: 180, height: 20))
        let second = TextRegion(frameID: .init(value: 1), text: "36", bounds: CGRect(x: 210, y: 20, width: 30, height: 20))
        let third = TextRegion(frameID: .init(value: 1), text: "items at a total of $1444.75.", bounds: CGRect(x: 250, y: 20, width: 250, height: 20))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Invoice 10024 covers 36 items at a total of $1444.75. AXONLY_MUST_NOT_BE_APPENDED",
                  bounds: CGRect(x: 0, y: 0, width: 700, height: 60), precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct([first, third, second], snapshot: snapshot)
        XCTAssertEqual(result.map(\.text), [first.text, third.text, second.text])
        XCTAssertEqual(result.map(\.bounds), [first.bounds, third.bounds, second.bounds])
    }

    func testRecordedShortFragmentReservesItsAXSpanAgainstDuplicateInsertion() async {
        // RXCASE059 0.75-scale Vision output and its actual recorded rectangles.
        let raw: [(String, CGRect)] = [
            ("Please review the café menu before confirming your conference reservation.", CGRect(x: 22, y: 21.78, width: 605, height: 19.22)),
            ("Renée Müller discussed the façade with José García at 14:35.", CGRect(x: 19.25, y: 54, width: 495, height: 22.22)),
            ("$84.50;", CGRect(x: 177.94, y: 91.75, width: 58.12, height: 14.49)),
            ("Crème brûlée costs", CGRect(x: 24, y: 92, width: 152, height: 14)),
            ("10059 is payable tomorrow.", CGRect(x: 306, y: 92, width: 214, height: 14)),
            ("Naïve comparisons must preserve the résumé and its accents.", CGRect(x: 24, y: 128, width: 480, height: 14))
        ]
        let reference = "Please review the café menu before confirming your conference reservation. Renée Müller discussed the façade with José García at 14:35. Crème brûlée costs $84.50; invoice 10059 is payable tomorrow. Naïve comparisons must preserve the résumé and its accents."
        let regions = raw.map { TextRegion(frameID: .init(value: 1), text: $0.0, bounds: $0.1) }
        let result = await AccessibilityOCRCorrector.correct(regions,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                .init(text: reference, bounds: CGRect(x: 0, y: 0, width: 700, height: 180), precise: false)
            ]))
        XCTAssertEqual(result.map(\.text).joined(separator: " ").components(separatedBy: "10059").count - 1, 1)
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
        XCTAssertEqual([result[3].text, result[2].text, result[4].text].joined(separator: " "),
            "Crème brûlée costs $84.50; invoice 10059 is payable tomorrow.")
    }

    func testRecordedNodeSequenceRepairsEachOwnerAndSkipsUnmatchedBitmapNode() async {
        // RXCASE099 actual Vision strings and rectangles, in the returned order.
        let raw: [(String, CGRect)] = [
            ("Please review the conference requirements before confirming your reservation.", CGRect(x: 22.8, y: 22.72, width: 627, height: 20.28)),
            ("Involce 10099 covers 111I", CGRect(x: 24, y: 62, width: 200, height: 8)),
            ("at a total ot $1519.15.", CGRect(x: 272, y: 62, width: 190, height: 10)),
            ("and the departure time is 14:35.", CGRect(x: 312, y: 94, width: 264, height: 12)),
            ("is AB10099", CGRect(x: 224, y: 94, width: 86, height: 12)),
            ("Ine reterence ıdentıtıer", CGRect(x: 24, y: 96, width: 198, height: 8)),
            ("Coordinator Morgan Ellis approved the conference schedule for November 16.", CGRect(x: 19.95, y: 122, width: 607.05, height: 23)),
            ("Bitmap invoice 30099 was reconciled by Morgan Ellis.", CGRect(x: 24, y: 160, width: 424, height: 16))
        ]
        let reference = "Please review the conference requirements before confirming your reservation. Invoice 10099 covers 111 items at a total of $1519.75. The reference identifier is AB10099 and the departure time is 14:35. Coordinator Morgan Ellis approved the conference schedule for November 16."
        let regions = raw.enumerated().map { i, entry in
            TextRegion(id: Int64(37 + i), frameID: .init(value: 99), text: entry.0, bounds: entry.1)
        }
        let result = await AccessibilityOCRCorrector.correct(regions,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                .init(text: reference, bounds: CGRect(x: 0, y: 0, width: 700, height: 230), precise: false)
            ]))
        XCTAssertEqual([result[1].text, result[2].text].joined(separator: " "),
            "Invoice 10099 covers 111 items at a total of $1519.75.")
        XCTAssertEqual([result[5].text, result[4].text, result[3].text].joined(separator: " "),
            "The reference identifier is AB10099 and the departure time is 14:35.")
        XCTAssertEqual(result[7], regions[7])
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
        XCTAssertEqual(result.map(\.databaseID), regions.map(\.databaseID))
    }

    func testAmbiguousNodesDoNotBlockAnIndependentConfirmedNode() async {
        let raw = "Please review the maintenance requiremants before confirming your reservation."
        let left = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds)
        let right = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds.offsetBy(dx: 900, dy: 0))
        let before = TextRegion(frameID: .init(value: 1),
            text: "Renée Müller discussed the façade with José García at 14:35.", bounds: bounds.offsetBy(dx: 0, dy: 35))
        let below = TextRegion(frameID: .init(value: 1),
            text: "The reference isentier is AB10015 and the departure sme is 14:35.", bounds: bounds.offsetBy(dx: 0, dy: 70))
        let after = TextRegion(frameID: .init(value: 1),
            text: "Naïve comparisons must preserve the résumé and its accents.", bounds: bounds.offsetBy(dx: 0, dy: 105))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Please review the maintenance requirements before confirming your reservation. " + before.text
                + " The reference identifier is AB10015 and the departure time is 14:35. " + after.text,
                  bounds: CGRect(x: 0, y: 0, width: 1700, height: 160), precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct([left, right, before, below, after], snapshot: snapshot)
        XCTAssertEqual(result[0], left)
        XCTAssertEqual(result[1], right)
        XCTAssertEqual(result[3].text, "The reference identifier is AB10015 and the departure time is 14:35.")
    }

    func testNativeExactNodeAnchorCannotBeBorrowedByAnotherPassage() async {
        // Actual Wikipedia screenshot/native-AX replay: the hidden jump link
        // shares words with the visible attribution and the Contents heading.
        let contents = TextRegion(frameID: .init(value: 1), text: "Contents", bounds: bounds)
        let attribution = TextRegion(frameID: .init(value: 1), text: "From Wikipedia, the free encyclopedia",
            bounds: bounds.offsetBy(dx: 0, dy: 35))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "Jump to content Wikipedia The Free Encyclopedia", bounds: .zero, precise: false),
            .init(text: "From Wikipedia, the free encyclopedia", bounds: .zero, precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct([contents, attribution], snapshot: snapshot)
        XCTAssertEqual(result, [contents, attribution])
    }

    func testNativeCodeNodesKeepLineNumberNoiseOutOfNeighborOwnership() async {
        // Actual MDN screenshot OCR includes the rendered code gutter numbers.
        let comment = TextRegion(frameID: .init(value: 1), text: "3 // Pass a function to map",
            bounds: CGRect(x: 583.26, y: 586, width: 251.16, height: 17.19))
        let mapped = TextRegion(frameID: .init(value: 1),
            text: "4 const mapped = array.map((x)=> x *2);",
            bounds: CGRect(x: 583.26, y: 608.78, width: 376.74, height: 17.22))
        let console = TextRegion(frameID: .init(value: 1), text: "6 console.Log(mapped);",
            bounds: CGRect(x: 583.26, y: 653, width: 203.72, height: 20.01))
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "// Pass a function to map\nconst mapped = array.map((x) => x * 2);\nconsole.log(mapped);", bounds: .zero, precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct([comment, mapped, console], snapshot: snapshot)
        XCTAssertEqual(result.map(\.text), ["// Pass a function to map", "const mapped = array.map((x) => x * 2);", "console.log(mapped);"])
        XCTAssertEqual(result.map(\.bounds), [comment.bounds, mapped.bounds, console.bounds])
    }

    func testUnanchoredSidebarNodeCannotConsumeAnArticleFootnote() async {
        // Actual Wikipedia native replay: a sidebar References label shares the
        // vertical gap between two body nodes, but is outside their text column.
        let body = TextRegion(frameID: .init(value: 1),
            text: "producing a high degree of accuracy for most fonts are now common, and with support for a variety of image file format inputs.(?)",
            bounds: CGRect(x: 485.58, y: 667, width: 909.77, height: 23))
        let sidebar = TextRegion(frameID: .init(value: 1), text: "References",
            bounds: CGRect(x: 226.05, y: 703.72, width: 75.35, height: 13.96))
        let next = TextRegion(frameID: .init(value: 1), text: "Some systems are capable of reproducing formatted output that closely approximates the original page including images, columns,",
            bounds: CGRect(x: 482.79, y: 695, width: 929.30, height: 20))
        let reference = "producing a high degree of accuracy for most fonts are now common, and with support for a variety of image file format inputs. [2] Some systems are capable of reproducing formatted output that closely approximates the original page including images, columns,"
        let result = await AccessibilityOCRCorrector.correct([body, sidebar, next],
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [.init(text: reference, bounds: .zero, precise: false)]))
        XCTAssertEqual(result[1], sidebar)
    }

    func testRecordedInternalAnchorsCannotAuthorizeAnUnboundedWrongInvoiceRow() async {
        // RXCASE001 0.75-scale recorded Vision output was already correct.
        let text = [
            "Please review the reservation requirements before confirming your reservation.",
            "Invoice 10001 covers 13 items at a total of $1421.75.",
            "The reference identifier is AB10001 and the departure time is 14:35.",
            "Coordinator Morgan Ellis approved the reservation schedule for November 2."
        ]
        let regions = text.enumerated().map { i, value in
            TextRegion(frameID: .init(value: 1), text: value,
                bounds: CGRect(x: 22, y: 22 + i * 30, width: 424, height: 20))
        }
        let wrong = "Invoice 10002 covers 13 items at a total of $1491.75."
        for box in [CGRect(x: 0, y: 0, width: 700, height: 180), regions[1].bounds.offsetBy(dx: 0, dy: 300)] {
            let result = await AccessibilityOCRCorrector.correct(regions,
                snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                    .init(text: wrong, bounds: box, precise: false)
                ]))
            XCTAssertEqual(result, regions, "Internal similarity must not replace missing outside anchors")
        }
    }

    func testRecordedNodeNeedsBothAvailableOutsideAnchors() async {
        // Actual RXCASE015 OCR and reference; the AX decoy keeps a strong inner
        // match and the preceding passage but replaces the following context.
        let raw = [
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            "Invoice 10015 covars 27 itema at a total of $1435.75.",
            "The referenco isentier is AB10015 and iho departure sme is 14:35."
        ]
        let regions = raw.enumerated().map { i, value in
            TextRegion(frameID: .init(value: 1), text: value,
                bounds: CGRect(x: 22, y: 22 + i * 30, width: 600, height: 20))
        }
        let decoy = "Please review the maintenance requirements before confirming your reservation. "
            + "Invoice 10015 covers 27 items at a total of $1435.75. "
            + "Naïve comparisons must preserve the résumé and its accents."
        let result = await AccessibilityOCRCorrector.correct(regions,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                .init(text: decoy, bounds: CGRect(x: 0, y: 0, width: 700, height: 150), precise: false)
            ]))
        XCTAssertEqual(result[1], regions[1], "A preceding anchor cannot stand in for a missing following anchor")
    }

    func testRecordedOutsideAnchorsSelectThePassageDespiteSimilarInvoiceWording() async {
        let raw = [
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            "Invoice 10015 covars 27 itema at a total of $1435.75.",
            "The referenco isentier is AB10015 and iho departure sme is 14:35."
        ]
        let expected = [
            "Please review the maintenance requirements before confirming your reservation.",
            "Invoice 10015 covers 27 items at a total of $1435.75.",
            "The reference identifier is AB10015 and the departure time is 14:35."
        ]
        let regions = raw.enumerated().map { i, value in
            TextRegion(frameID: .init(value: 1), text: value,
                bounds: CGRect(x: 22, y: 22 + i * 30, width: 600, height: 20))
        }
        let decoy = "Renée Müller discussed the façade with José García at 14:35. "
            + "Invoice 10099 covers 27 items at a total of $1435.75. "
            + "Naïve comparisons must preserve the résumé and its accents."
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: decoy, bounds: CGRect(x: 0, y: 0, width: 700, height: 150), precise: false),
            .init(text: expected.joined(separator: " "), bounds: CGRect(x: 0, y: 0, width: 700, height: 150), precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result.map(\.text), expected)
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testAnIsolatedNodeCannotAuthorizeItsOwnAXCorrection() async {
        let raw = "Ploaso reviow the maintenanco requirements beforo confirmina your reservation."
        let region = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds)
        let result = await AccessibilityOCRCorrector.correct(region,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                .init(text: "Please review the maintenance requirements before confirming your reservation.",
                      bounds: bounds, precise: true)
            ]))
        XCTAssertEqual(result, region)
    }

    func testRepeatedOutsideContextCannotBeDisambiguatedByTheTargetItself() async {
        let raw = [
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            "Invoice 10015 covars 27 itema at a total of $1435.75.",
            "The referenco isentier is AB10015 and iho departure sme is 14:35."
        ]
        let before = "Please review the maintenance requirements before confirming your reservation. "
        let after = " The reference identifier is AB10015 and the departure time is 14:35."
        let regions = raw.enumerated().map { i, text in
            TextRegion(frameID: .init(value: 1), text: text, bounds: bounds.offsetBy(dx: 0, dy: CGFloat(i) * 35))
        }
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: before + "Invoice 10015 covers 27 items at a total of $1435.75." + after,
                  bounds: CGRect(x: 0, y: 0, width: 740, height: 140), precise: false),
            .init(text: before + "Invoice 10099 covers 27 items at a total of $1435.75." + after,
                  bounds: CGRect(x: 0, y: 0, width: 740, height: 140), precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result[1], regions[1], "The better internal number match cannot resolve identical outside anchors")
    }

    func testWindowOwnershipPreventsBorrowingAnotherWindowsContext() async {
        let raw = [
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            "Invoice 10015 covars 27 itema at a total of $1435.75.",
            "The referenco isentier is AB10015 and iho departure sme is 14:35."
        ]
        let reference = [
            "Please review the maintenance requirements before confirming your reservation.",
            "Invoice 10015 covers 27 items at a total of $1435.75.",
            "The reference identifier is AB10015 and the departure time is 14:35."
        ]
        let windows = [CGRect(x: 0, y: 0, width: 740, height: 140), CGRect(x: 900, y: 0, width: 740, height: 140)]
        var regions: [TextRegion] = []
        for window in windows {
            for (i, text) in raw.enumerated() {
                regions.append(TextRegion(frameID: .init(value: 1), text: text,
                    bounds: CGRect(x: window.minX + 20, y: CGFloat(20 + i * 35), width: 700, height: 20)))
            }
        }
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: reference.joined(separator: " "), bounds: windows[0], precise: false)
        ])
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot, windowRegions: windows)
        XCTAssertEqual(Array(result.prefix(3)).map(\.text), reference)
        XCTAssertEqual(Array(result.suffix(3)), Array(regions.suffix(3)))
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testNormalizedExactMatchStillNeedsOutsideEvidenceToChangeWordSpacing() async {
        let raw = "const invoice Total = 1465.75;"
        let region = TextRegion(frameID: .init(value: 1), text: raw, bounds: bounds)
        let result = await AccessibilityOCRCorrector.correct(region,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: [
                .init(text: "const invoiceTotal = 1465.75;", bounds: bounds, precise: true)
            ]))
        XCTAssertEqual(result, region)
    }

    private func recordedInvoiceNodes() -> [TextRegion] {
        // RXCASE001, scale 0.75: actual Vision text and screenshot rectangles.
        let lines: [(String, CGRect)] = [
            ("Please review the reservation requirements before confirming your reservation.",
             CGRect(x: 22.00000075, y: 21.99999975, width: 424, height: 20)),
            ("Invoice 10001 covers 13 items at a total of $1421.75.",
             CGRect(x: 22.000003475, y: 51.999999975, width: 278, height: 18)),
            ("The reference identifier is AB10001 and the departure time is 14:35.",
             CGRect(x: 22.000003017, y: 81.99999995, width: 362, height: 18)),
            ("Coordinator Morgan Ellis approved the reservation schedule for November 2.",
             CGRect(x: 22.00000412, y: 111.99999992, width: 412, height: 20))
        ]
        return lines.map { TextRegion(frameID: .init(value: 1), text: $0.0, bounds: $0.1) }
    }

    private func recordedMaintenanceNodes() -> ([TextRegion], [String]) {
        // RXCASE015, scale 0.75: original Vision observations, without joining nodes.
        let lines: [(String, CGRect)] = [
            ("Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
             CGRect(x: 24.0000273588, y: 29.9999999, width: 241.99996948, height: 6)),
            ("Invoice 10015 covars 27 itema at a total of $1435.75.",
             CGRect(x: 24.000002, y: 43.999999925, width: 160, height: 10)),
            ("The referenco isentier is AB10015 and iho departure sme is 14:35.",
             CGRect(x: 24.0000178294, y: 63.9999999, width: 203.99998474, height: 6)),
            ("Coordinasee Moman Ella agoroved the maintenarne schedule for Novorber 16",
             CGRect(x: 24.0000272588, y: 79.9999999, width: 239.99996948, height: 6))
        ]
        let reference = [
            "Please review the maintenance requirements before confirming your reservation.",
            "Invoice 10015 covers 27 items at a total of $1435.75.",
            "The reference identifier is AB10015 and the departure time is 14:35.",
            "Coordinator Morgan Ellis approved the maintenance schedule for November 16."
        ]
        return (lines.map { TextRegion(frameID: .init(value: 1), text: $0.0, bounds: $0.1) }, reference)
    }

    func testRecordedLastNodeAndNeighborsLocateAXBeyondOldElementLimit() async throws {
        let (regions, reference) = recordedMaintenanceNodes()
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        let unrelated = "Renée Müller discussed the façade with José García at 14:35."
        let texts = Array(repeating: unrelated, count: 140) + [reference.joined(separator: " ")]
        for candidates in [texts, Array(texts.reversed())] {
            let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: candidates.map {
                .init(text: $0, bounds: window, precise: false)
            })
            _ = try snapshot.encoded()
            let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot, windowRegions: [window])
            XCTAssertEqual(result.map(\.text), reference)
            XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
            XCTAssertEqual(result.map(\.databaseID), regions.map(\.databaseID))
        }
    }

    func testRecordedEndpointsBoundLongAXTextWithoutAppendingItsTail() async throws {
        let (regions, reference) = recordedMaintenanceNodes()
        let unrelated = String(repeating: "Naïve comparisons must preserve the résumé and its accents. ", count: 220)
        let text = unrelated + reference.joined(separator: " ") + " AXONLY_MUST_NOT_BE_APPENDED " + unrelated
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: text, bounds: CGRect(x: 0, y: 0, width: 740, height: 180), precise: false)
        ])
        _ = try snapshot.encoded()
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result.map(\.text), reference)
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testLastOCRTextAloneDoesNotWinWithoutItsPrecedingNodes() async throws {
        let (regions, reference) = recordedMaintenanceNodes()
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        let unrelated = "Renée Müller discussed the façade with José García at 14:35."
        let texts = [reference.last!] + Array(repeating: unrelated, count: 140) + [reference.joined(separator: " ")]
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: texts.map {
            .init(text: $0, bounds: window, precise: false)
        })
        _ = try snapshot.encoded()
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result.map(\.text), reference)
    }

    func testIncompleteEndpointDiscoveryDiscardsEarlierCorrectionCandidates() async throws {
        let (regions, reference) = recordedMaintenanceNodes()
        let paragraph = reference.joined(separator: " ")
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        // An early complete candidate is followed by enough relevant seed hits
        // to exhaust discovery. This still fits a real saved AX snapshot.
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: paragraph, bounds: window, precise: false),
            .init(text: Array(repeating: paragraph, count: 200).joined(separator: " "), bounds: window, precise: false)
        ])
        _ = try snapshot.encoded()
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result, regions, "Incomplete discovery cannot retain the earlier repair candidate")
    }

    func testRecordedSplitHeaderKeepsItsLocalAXContextDuringDiscovery() async {
        // HOLD007: real Vision split prefix and same-row tail. The next line
        // repeats Module, so the first AX line must remain a local candidate.
        let lines: [(String, CGRect)] = [
            ("{Module)/AGENTS.md", CGRect(x: 21.9576938797, y: 23.9999999, width: 125.7576923077, height: 16)),
            ("-Module-specific guidelines (e.g., Database/AGENTS.md)",
             CGRect(x: 157.6961579632, y: 23.999999925, width: 329.3653846154, height: 18)),
            ("(Module)/README.md-Implementation details for the module you're working on",
             CGRect(x: 21.9576969188, y: 53.9999999, width: 461.1115384615, height: 18))
        ]
        let regions = lines.map { TextRegion(frameID: .init(value: 1), text: $0.0, bounds: $0.1) }
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: "{Module}/AGENTS.md      ← Module-specific guidelines (e.g., Database/AGENTS.md)",
                  bounds: CGRect(x: 20, y: 21.13671875, width: 468.19140625, height: 19.40625), precise: true),
            .init(text: "{Module}/README.md      ← Implementation details for the module you're working on",
                  bounds: CGRect(x: 20, y: 51.13671875, width: 464.505859375, height: 19.40625), precise: true)
        ])
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result[0].text, "{Module}/AGENTS.md")
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

    func testDynamicBoundsKeepSplitAXReferencesInVisualOrder() async throws {
        let (regions, reference) = recordedMaintenanceNodes()
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        let unrelated = AccessibilitySnapshot.Element(
            text: "Renée Müller discussed the façade with José García at 14:35.", bounds: window, precise: false)
        let real = reference.enumerated().map { i, text in
            AccessibilitySnapshot.Element(text: text, bounds: regions[i].bounds, precise: true)
        }
        for elements in [Array(repeating: unrelated, count: 140) + real,
                         Array(real.reversed()) + Array(repeating: unrelated, count: 140)] {
            let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: elements)
            _ = try snapshot.encoded()
            let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot, windowRegions: [window])
            XCTAssertEqual(result.map(\.text), reference)
        }
    }

    func testRepeatedLastNodeRetainsCompetingOutsideCorrespondences() async throws {
        let (regions, reference) = recordedMaintenanceNodes()
        let correct = reference.joined(separator: " ")
        let competing = correct.replacingOccurrences(of: "Invoice 10015", with: "Invoice 10099")
        let unrelated = String(repeating: "Naïve comparisons must preserve the résumé and its accents. ", count: 220)
        // The final node and its preceding node are identical in both passages.
        // Finding the first endpoint must not discard the other invoice wording.
        for text in [correct + unrelated + competing, competing + unrelated + correct,
                     correct + " " + competing, competing + " " + correct] {
            let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
                .init(text: text, bounds: CGRect(x: 0, y: 0, width: 740, height: 180), precise: false)
            ])
            _ = try snapshot.encoded()
            let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
            XCTAssertEqual(result[1].text, regions[1].text)
            XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
        }
    }

    func testAXElementLimitCannotHideACompetingRecordedInvoicePassage() async throws {
        let regions = recordedInvoiceNodes()
        let correct = regions.map(\.text).joined(separator: " ")
        let wrong = correct.replacingOccurrences(of: "$1421.75", with: "$1491.75")
        let unrelated = "Renée Müller discussed the façade with José García at 14:35."
        let texts = [wrong] + Array(repeating: unrelated, count: 127) + [correct]
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        for references in [texts, Array(texts.reversed())] {
            let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: references.map {
                .init(text: $0, bounds: window, precise: false)
            })
            _ = try snapshot.encoded() // Fits the real saved-snapshot limit.
            let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot, windowRegions: [window])
            XCTAssertEqual(result, regions, "An unexamined competing passage must not authorize a wrong amount")
        }
    }

    func testTruncatedAXSnapshotCannotAuthorizeRecordedInvoiceChanges() async {
        let regions = recordedInvoiceNodes()
        let wrong = regions.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "$1421.75", with: "$1491.75")
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [
            .init(text: wrong, bounds: window, precise: false)
        ], truncated: true)
        for windows in [nil, [window]] as [[CGRect]?] {
            let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot, windowRegions: windows)
            XCTAssertEqual(result, regions, "Missing capture-time AX candidates cannot be treated as absent competitors")
        }
    }

    func testOversizedAXReferenceCannotBeSilentlySkipped() async throws {
        let regions = recordedInvoiceNodes()
        let correct = regions.map(\.text).joined(separator: " ")
        let wrong = correct.replacingOccurrences(of: "$1421.75", with: "$1491.75")
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        let longReference = String(repeating: "Naïve comparisons must preserve the résumé and its accents. ", count: 220) + correct
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: [wrong, longReference].map {
            .init(text: $0, bounds: window, precise: false)
        })
        _ = try snapshot.encoded()
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result, regions, "Skipping a long reference leaves the competing-candidate search incomplete")
    }

    func testUnrelatedAXTextDoesNotHideALateInvoiceCompetitor() async throws {
        let regions = recordedInvoiceNodes()
        let correct = regions.map(\.text).joined(separator: " ")
        let wrong = correct.replacingOccurrences(of: "$1421.75", with: "$1491.75")
        let window = CGRect(x: 0, y: 0, width: 740, height: 180)
        // Expansion used to exhaust detailed matching. Endpoint discovery must
        // scan past it and retain the late competitor instead of the first match.
        let unrelated = String(repeating: "Naïve comparisons must preserve the résumé and its accents. ", count: 170)
        let texts = [wrong] + Array(repeating: unrelated, count: 8) + [correct]
        let snapshot = AccessibilitySnapshot(capturedAt: Date(), elements: texts.map {
            .init(text: $0, bounds: window, precise: false)
        })
        _ = try snapshot.encoded()
        let result = await AccessibilityOCRCorrector.correct(regions, snapshot: snapshot)
        XCTAssertEqual(result, regions, "The late competing passage must remain eligible")
    }

    func testAnOversizedWindowDoesNotDisableAnotherWindowsCompleteCorrection() async {
        // Actual RXCASE015 wording errors, replayed in two separately owned windows.
        let raw = [
            "Ploaso reviow the maintenanco requirements beforo confirmina your reservation.",
            "Invoice 10015 covars 27 itema at a total of $1435.75.",
            "The referenco isentier is AB10015 and iho departure sme is 14:35."
        ]
        let reference = [
            "Please review the maintenance requirements before confirming your reservation.",
            "Invoice 10015 covers 27 items at a total of $1435.75.",
            "The reference identifier is AB10015 and the departure time is 14:35."
        ]
        let windows = [CGRect(x: 0, y: 0, width: 740, height: 140), CGRect(x: 900, y: 0, width: 740, height: 140)]
        let regions = windows.flatMap { window in
            raw.enumerated().map { i, text in
                TextRegion(frameID: .init(value: 1), text: text,
                    bounds: bounds.offsetBy(dx: window.minX, dy: CGFloat(i) * 35))
            }
        }
        let elements = [AccessibilitySnapshot.Element(text: reference.joined(separator: " "), bounds: windows[0], precise: false)]
            + Array(repeating: AccessibilitySnapshot.Element(text: reference.joined(separator: " "), bounds: windows[1], precise: false), count: 129)
        let result = await AccessibilityOCRCorrector.correct(regions,
            snapshot: AccessibilitySnapshot(capturedAt: Date(), elements: elements), windowRegions: windows)
        XCTAssertEqual(Array(result.prefix(3)).map(\.text), reference)
        XCTAssertEqual(Array(result.suffix(3)), Array(regions.suffix(3)))
        XCTAssertEqual(result.map(\.bounds), regions.map(\.bounds))
    }

}
