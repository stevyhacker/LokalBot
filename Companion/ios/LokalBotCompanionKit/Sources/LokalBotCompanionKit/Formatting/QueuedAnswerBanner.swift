import Foundation

public struct QueuedAnswerBanner: Sendable, Hashable {
    public let title: String
    public let subtitle: String
    public let body: String

    public init(question: String, answer: String, appLockOn: Bool) {
        title = "Your computer answered"
        subtitle = question
        body = appLockOn ? "" : String(AskCitationParser.plainText(answer).prefix(180))
    }
}
