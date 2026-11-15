import Foundation

struct CLIStoredSearchResults: Codable, Equatable {
    let storedAt: Date
    let queryText: String
    let results: [CLISearchResultOutput]
}

struct CLIResultStore {
    let fileURL: URL

    init(
        fileURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace-cli")
            .appendingPathComponent("latest-search-results.json")
    ) {
        self.fileURL = fileURL
    }

    func saveLatestSearchResults(queryText: String, results: [CLISearchResultOutput]) throws {
        let payload = CLIStoredSearchResults(
            storedAt: Date(),
            queryText: queryText,
            results: results
        )

        let encoder = JSONEncoder()
        CLIDateCoding.configure(encoder)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func loadLatestSearchResults() throws -> CLIStoredSearchResults? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        CLIDateCoding.configure(decoder)
        return try decoder.decode(CLIStoredSearchResults.self, from: data)
    }

    func resolveLatestSearchResult(id: Int) throws -> CLISearchResultOutput {
        guard let storedResults = try loadLatestSearchResults() else {
            throw CLIError.noStoredResultsAvailable
        }

        guard let result = storedResults.results.first(where: { $0.resultID == id }) else {
            throw CLIError.storedResultNotFound(id)
        }

        return result
    }
}
