import Foundation

public protocol CoachingProvider: Sendable {
    func suggest(_ request: CoachRequest) async throws -> CoachResponse
}

/// A predictable local responder for exercising the capture/review flow.
/// It is not an AI model and makes no network requests.
public struct DemoCoachingProvider: CoachingProvider {
    public init() {}

    public func suggest(_ request: CoachRequest) async throws -> CoachResponse {
        let placeholder = "轻载条件下"
        let expression = "under light-load conditions"
        guard request.sourceText.contains(placeholder) else {
            return CoachResponse(
                naturalText: request.sourceText,
                meaningPreserved: true,
                warnings: ["本地演示仅识别“轻载条件下”；尚未连接语言模型。"]
            )
        }

        return CoachResponse(
            naturalText: request.sourceText.replacingOccurrences(
                of: placeholder,
                with: expression
            ),
            meaningPreserved: true,
            learningPoints: [
                LearningPoint(
                    source: placeholder,
                    target: expression,
                    explanation: "表示设备或系统处于较轻负载时。",
                    category: .terminology
                )
            ]
        )
    }
}
