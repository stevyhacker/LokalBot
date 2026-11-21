import CoreGraphics
import DigUpKit
import Foundation

enum FileTextRecognition {
    static let timeLimit = ScreenshotProcessingWorker.textRecognitionLimit

    static let purpose = "files"

    static func route(through queue: TextRecognitionQueue = .shared, within seconds: TimeInterval = timeLimit,
                      recognize: @escaping @Sendable (CGImage) -> String = TextRecognition.vision) {
        TextRecognition.reader = { image in
            let picture = Picture(image: image)
            return queue.runAndWait(purpose, urgency: .background, within: seconds) {
                recognize(picture.image)
            }
        }
    }

    private struct Picture: @unchecked Sendable {
        let image: CGImage
    }
}
