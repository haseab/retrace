import Foundation
import Shared

extension FeedbackService {
    // MARK: - Submission

    /// Submit feedback to the backend
    /// - Parameter submission: The feedback to submit
    /// - Returns: True if successful
    public func submitFeedback(_ submission: FeedbackSubmission) async throws -> Bool {
        let endpoint = Self.feedbackEndpoint

        Log.info("[FeedbackService] Submitting feedback to \(endpoint.absoluteString)", category: .app)

        let request = try Self.makeFeedbackRequest(for: submission, endpoint: endpoint)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FeedbackError.submissionFailed
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                Log.error("[FeedbackService] Submission failed with status \(httpResponse.statusCode): \(responseBody)", category: .app)
                throw FeedbackError.submissionFailed
            }

            Log.info("[FeedbackService] Feedback submitted successfully", category: .app)
            return true
        } catch let urlError as URLError {
            Log.error("[FeedbackService] Network error (code: \(urlError.code.rawValue))", category: .app, error: urlError)
            throw FeedbackError.networkError(urlError.localizedDescription)
        } catch {
            Log.error("[FeedbackService] Submission error", category: .app, error: error)
            throw error
        }
    }

    static func makeFeedbackRequest(
        for submission: FeedbackSubmission,
        endpoint: URL = feedbackEndpoint
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestBody = try encoder.encode(submission)
        let compressedBody = try gzipCompress(requestBody)
        request.httpBody = compressedBody
        return request
    }
}
