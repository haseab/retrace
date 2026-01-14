import Foundation
import App
import Shared

@main
struct TestMostRecentFrame {
    static func main() async throws {
        print("=== Testing getMostRecentFrameTimestamp() ===\n")

        // Force enable Rewind data for this test
        UserDefaults.standard.set(true, forKey: "useRewindData")
        print("✓ Enabled Rewind data source\n")

        // Initialize services
        let coordinator = AppCoordinator()
        try await coordinator.initialize()

        // Call getMostRecentFrameTimestamp
        let result = try await coordinator.getMostRecentFrameTimestamp()

        // Format the result
        let utcFormatter = DateFormatter()
        utcFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        utcFormatter.timeZone = TimeZone(identifier: "UTC")!

        let localFormatter = DateFormatter()
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"

        if let timestamp = result {
            print("✅ Most recent frame found:")
            print("   UTC:   \(utcFormatter.string(from: timestamp))")
            print("   Local: \(localFormatter.string(from: timestamp))")
            print("   Unix:  \(timestamp.timeIntervalSince1970)")
        } else {
            print("❌ No frames found in any source")
        }

        // Shutdown
        try await coordinator.shutdown()
    }
}
