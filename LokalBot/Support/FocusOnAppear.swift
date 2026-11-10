import SwiftUI

extension View {
    /// Moves keyboard focus here when the view first appears, for a window
    /// that opens ready for typing. From macOS 26 a focus request made inside
    /// `onAppear` is dropped while the window's content is first being
    /// installed, so the request waits one turn of the main queue.
    func focusOnAppear(_ focused: FocusState<Bool>.Binding) -> some View {
        onAppear { DispatchQueue.main.async { focused.wrappedValue = true } }
    }
}
