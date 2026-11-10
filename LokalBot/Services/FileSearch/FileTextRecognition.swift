import CoreGraphics
import DigUpKit
import Foundation

/// Sends the text recognition of Files' indexer through the app's one queue
/// for it (`TextRecognitionQueue`), with a time limit, like every other
/// Vision text request in the app.
///
/// DigUp reads the words in screenshots and in scanned PDF pages. It used to
/// ask Vision itself and wait for as long as that took. On 2026-11-09 one
/// screenshot's request never came back: the pass and the media model it had
/// started stayed up until the app quit, and every other text recognition in
/// the app waited behind that request.
///
/// A file whose text gets no answer in time is not read without it, which
/// would settle it for good. DigUp leaves it waiting (a long PDF keeps its
/// place), the pass goes on with the next file, and a later pass reads it.
enum FileTextRecognition {
    /// As long as a screen capture waits for the text in its pixels.
    static let timeLimit = ScreenshotProcessingWorker.textRecognitionLimit

    /// What the queue's log lines call these requests.
    static let purpose = "files"

    /// Makes `queue` the way DigUp reads text in this process: the indexer's
    /// screenshots and scans, and the one-off speed check behind a folder's
    /// estimate. `recognize` is the reading itself, DigUp's own Vision
    /// request unless a test stands in for it.
    static func route(through queue: TextRecognitionQueue = .shared, within seconds: TimeInterval = timeLimit,
                      recognize: @escaping @Sendable (CGImage) -> String = TextRecognition.vision) {
        TextRecognition.reader = { image in
            let picture = Picture(image: image)
            // The thread reading files waits here, for `seconds` at most. Nil
            // (no answer in time, or recognition is stalled) leaves the file
            // for a later pass.
            return queue.runAndWait(purpose, urgency: .background, within: seconds) {
                recognize(picture.image)
            }
        }
    }

    private struct Picture: @unchecked Sendable {
        let image: CGImage
    }
}
