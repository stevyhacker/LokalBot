import AppKit
import AuthenticationServices

/// Google's consent page in Apple's authentication sheet
/// (`ASWebAuthenticationSession`), the way Google's own SDK signs macOS apps
/// in. The sheet shares the browser's Google session, shows the page's real
/// address, and hands back only a redirect in LokalBot's own client scheme,
/// so no other app or web page can receive the authorization code.
@MainActor
final class GoogleSignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Shows `url` and returns the redirect Google sends to `callbackScheme`.
    /// Throws `CancellationError` when the person closes the sheet.
    nonisolated static func present(_ url: URL, callbackScheme: String) async throws -> URL {
        let sheet = await GoogleSignInSheet()
        return try await sheet.run(url, callbackScheme: callbackScheme)
    }

    private func run(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.continuation = continuation
                let callback = ASWebAuthenticationSession.Callback.customScheme(callbackScheme)
                let session = ASWebAuthenticationSession(url: url, callback: callback) { [weak self] returned, error in
                    Task { @MainActor in self?.complete(returned, error) }
                }
                session.presentationContextProvider = self
                // Reuse the Google account already signed in to the browser.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    finish(.failure(GmailError.signInFailed("LokalBot couldn't open Google sign-in.")))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func complete(_ returned: URL?, _ error: Error?) {
        if let returned {
            finish(.success(returned))
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(GmailError.signInFailed(
                "Google sign-in stopped: \(error?.localizedDescription ?? "no response").")))
        }
    }

    private func cancel() {
        session?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session = nil
        continuation.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
