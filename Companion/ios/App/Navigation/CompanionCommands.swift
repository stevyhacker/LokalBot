import SwiftUI

/// Hardware keyboard shortcuts on iPad: ⌘1–⌘7 for sections in sidebar order,
/// ⌘F to search meetings and ⌘N for a new question.
struct CompanionCommands: Commands {
    @FocusedValue(\.navigator) private var navigator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Question") { navigator?.ask(about: nil) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(navigator == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Meetings") { navigator?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(navigator == nil)
        }
        CommandMenu("Go") {
            ForEach(Array(AppSection.shortcutOrder.enumerated()), id: \.element) { index, section in
                Button(section.title) { navigator?.open(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(navigator == nil)
            }
            Divider()
            Button("Settings") { navigator?.open(.settings) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(navigator == nil)
        }
    }
}
