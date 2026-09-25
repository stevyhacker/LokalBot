import Foundation

/// The engine entry point authorizes its configured origin. Redirects may
/// change a path on that origin, but cannot transfer prompts or credentials to
/// another server (including a different loopback port).
enum InferenceURLSession {
    static func make(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration, delegate: RedirectBoundary(), delegateQueue: nil)
    }

    static func allowsRedirect(from original: URL?, to destination: URL?) -> Bool {
        guard let original, let destination,
              destination.user == nil, destination.password == nil,
              let origin = InferenceEndpointPolicy.origin(for: original),
              let destinationOrigin = InferenceEndpointPolicy.origin(for: destination) else { return false }
        return origin == destinationOrigin
    }

    private final class RedirectBoundary: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(InferenceURLSession.allowsRedirect(
                from: task.originalRequest?.url, to: request.url) ? request : nil)
        }
    }
}
