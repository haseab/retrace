import XCTest
@testable import Search
import Shared

final class QueryParserTests: XCTestCase {
    private let parser = QueryParser()

    func testParseExcludedPhraseAndTerm() throws {
        let parsed = try parser.parse(rawQuery: #"swift -"machine learning" -java"#)

        XCTAssertEqual(parsed.searchTerms, ["swift"])
        XCTAssertEqual(parsed.phrases, [])
        XCTAssertEqual(parsed.excludedTerms, ["machine learning", "java"])
        XCTAssertEqual(parsed.toFTSQuery(), #"swift* NOT "machine learning" NOT java"#)
    }

    func testParseKeepsPositivePhraseAndExcludedPhraseDistinct() throws {
        let parsed = try parser.parse(rawQuery: #""memory leak" -"fix applied""#)

        XCTAssertEqual(parsed.phrases, ["memory leak"])
        XCTAssertEqual(parsed.excludedTerms, ["fix applied"])
        XCTAssertEqual(parsed.toFTSQuery(), #""memory leak" NOT "fix applied""#)
    }

    func testExclusionOnlyQueryIsRejected() throws {
        XCTAssertThrowsError(try parser.parse(rawQuery: #"-"machine learning""#)) { error in
            guard case let SearchError.invalidQuery(reason) = error else {
                XCTFail("Expected invalidQuery error, got \(error)")
                return
            }
            XCTAssertEqual(reason, "Exclusions require at least one search term")
        }
    }

    func testScopedQueryAppliesExclusionAcrossBothColumns() throws {
        let parsed = try parser.parse(rawQuery: #"haseab -wave"#)
        let scoped = SearchManager.buildScopedFTSQuery(for: parsed)

        XCTAssertTrue(scoped.contains("(text:(haseab*))"))
        XCTAssertTrue(scoped.contains("(otherText:(haseab*))"))
        XCTAssertTrue(scoped.contains("NOT ((text:(wave)) OR (otherText:(wave)))"))
    }

    func testParseIgnoresShellFlagsForCommandLikeQuery() throws {
        let parsed = try parser.parse(
            rawQuery: #"osascript -e 'tell application "Codex" to hide' -e 'delay 1'"#
        )

        XCTAssertTrue(parsed.excludedTerms.isEmpty)
        XCTAssertEqual(parsed.searchTerms, ["osascript"])
        XCTAssertEqual(parsed.phrases, [#"tell application "Codex" to hide"#, "delay 1"])
    }
}
