import SwiftUI

extension View {
    func focusOnAppear(_ focused: FocusState<Bool>.Binding) -> some View {
        onAppear { DispatchQueue.main.async { focused.wrappedValue = true } }
    }
}
