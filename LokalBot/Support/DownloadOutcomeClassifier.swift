import Foundation

enum DownloadOutcome: Equatable, Sendable {
    case success
    case httpError(Int)
    case notGGUF
    case cancelled
    case transport(String)
}

extension DownloadOutcome {
    var userMessage: String {
        switch self {
        case .success:
            return "Download complete."
        case .httpError(let status):
            return "Download failed (HTTP \(status))."
        case .notGGUF:
            return "The downloaded file is not a supported local model."
        case .cancelled:
            return "Download cancelled."
        case .transport(let detail):
            return "Download failed: \(detail)"
        }
    }
}

enum DownloadOutcomeClassifier {
    static func classify(httpStatus: Int?, error: Error?, looksLikeGGUF: Bool) -> DownloadOutcome {
        if let error, isUserCancellation(error) {
            return .cancelled
        }
        if let httpStatus, !(200..<300).contains(httpStatus) {
            return .httpError(httpStatus)
        }
        if let error {
            return .transport(error.localizedDescription)
        }
        guard looksLikeGGUF else {
            return .notGGUF
        }
        return .success
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
