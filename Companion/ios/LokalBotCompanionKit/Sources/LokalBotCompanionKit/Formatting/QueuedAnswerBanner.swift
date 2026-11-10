import Foundation

/// What the notification says when the computer answers a question that was
/// queued while it was away. A banner shows on the lock screen and over other
/// apps, where App Lock doesn't reach, so with the lock on it names the
/// question and leaves the answer for inside the app, as the Android app does.
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
