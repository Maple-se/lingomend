import Foundation

/// Shared bounded transport. No response bodies or credentials enter diagnostics.
struct ChatCompletionClient: Sendable {
    let transport: any CoachingHTTPTransport

    func content(for request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let result: CoachingHTTPResult
        do {
            result = try await withThrowingTaskGroup(of: CoachingHTTPResult.self) { group in
                group.addTask { try await transport.send(request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.timeoutInterval))
                    throw CoachingProviderError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CoachingProviderError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? CoachingProviderError.timedOut : .network
        } catch { throw CoachingProviderError.network }
        try Task.checkCancellation()
        switch result.statusCode {
        case 200...299: break
        case 401, 403: throw CoachingProviderError.unauthorized
        case 429: throw CoachingProviderError.rateLimited
        default: throw CoachingProviderError.httpStatus(result.statusCode)
        }
        guard result.data.count <= 1_048_576 else { throw CoachingProviderError.responseTooLarge }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: result.data) }
        catch { throw CoachingProviderError.invalidResponse }
        guard envelope.choices.count == 1, let choice = envelope.choices.first else {
            throw CoachingProviderError.invalidResponse
        }
        if let refusal = choice.message.refusal, !refusal.isEmpty { throw CoachingProviderError.refused }
        guard choice.finishReason == "stop" else { throw CoachingProviderError.incompleteResponse }
        guard let content = choice.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = content.data(using: .utf8), data.count <= 262_144 else {
            throw CoachingProviderError.invalidResponse
        }
        return data
    }

    private struct Envelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String?; let refusal: String? }
            let message: Message
            let finishReason: String
            enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
        }
        let choices: [Choice]
    }
}
