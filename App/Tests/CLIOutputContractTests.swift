import XCTest
@testable import App
import Shared

final class CLIOutputContractTests: XCTestCase {
    func testOpenOutputEncodesStableTimelineKeys() throws {
        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)

        let output = CLIOpenOutput(
            url: "retrace://timeline?state=abc",
            opened: true,
            route: "timeline",
            timeline: CLIDeeplinkTimelineState(
                timestamp: Date(timeIntervalSince1970: 1_704_067_200.123),
                frameID: 123_456
            )
        )

        let json = try jsonObject(from: encoder.encode(output))

        XCTAssertEqual(json["url"] as? String, "retrace://timeline?state=abc")
        XCTAssertEqual(json["opened"] as? Bool, true)
        XCTAssertEqual(json["route"] as? String, "timeline")

        let timeline = try XCTUnwrap(json["timeline"] as? [String: Any])
        XCTAssertEqual((timeline["frameID"] as? NSNumber)?.int64Value, 123_456)
        XCTAssertNotNil(timeline["timestamp"] as? String)
        XCTAssertNil(json["search"])
    }

    func testAppsListOutputEncodesStableKeys() throws {
        let output = CLIAppsListOutput(
            count: 1,
            apps: [
                CLIAppsListEntryOutput(
                    bundleID: "com.google.Chrome",
                    appName: "Google Chrome",
                    bundleSuffix: "Chrome",
                    installed: true
                )
            ]
        )

        let json = try jsonObject(from: JSONEncoder().encode(output))

        XCTAssertEqual(json["count"] as? Int, 1)
        let apps = try XCTUnwrap(json["apps"] as? [[String: Any]])
        let first = try XCTUnwrap(apps.first)
        XCTAssertEqual(first["bundleID"] as? String, "com.google.Chrome")
        XCTAssertEqual(first["appName"] as? String, "Google Chrome")
        XCTAssertEqual(first["bundleSuffix"] as? String, "Chrome")
        XCTAssertEqual(first["installed"] as? Bool, true)
    }

    func testHelpOutputEncodesStableKeys() throws {
        let output = CLIHelpOutput(
            topicPath: ["search"],
            summary: "Search history.",
            usage: "retrace search <query...>",
            notes: ["All commands emit JSON."],
            subcommands: [CLIHelpSubcommandOutput(name: "search", summary: "Search history.")],
            options: [CLIHelpOptionOutput(flag: "--range", valueName: "start..end", repeatable: true, description: "Date range.")],
            examples: ["retrace search openai"]
        )

        let json = try jsonObject(from: JSONEncoder().encode(output))

        XCTAssertEqual(json["topicPath"] as? [String], ["search"])
        XCTAssertEqual(json["summary"] as? String, "Search history.")
        XCTAssertEqual(json["usage"] as? String, "retrace search <query...>")
        XCTAssertNotNil(json["notes"] as? [String])
        XCTAssertNotNil(json["subcommands"] as? [[String: Any]])
        XCTAssertNotNil(json["options"] as? [[String: Any]])
        XCTAssertNotNil(json["examples"] as? [String])
    }

    func testCompletionsOutputEncodesStableKeys() throws {
        let output = CLICompletionsOutput(shell: .zsh, script: "#compdef retrace")
        let json = try jsonObject(from: JSONEncoder().encode(output))

        XCTAssertEqual(json["shell"] as? String, "zsh")
        XCTAssertEqual(json["script"] as? String, "#compdef retrace")
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try XCTUnwrap(object as? [String: Any])
    }
}
