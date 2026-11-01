import SwiftUI

/// Values, not an AppState observer: `AppSceneState` publishes the language
/// and whether Agent is showing, and the App body passes them in.
struct AgentCommands: Commands {
    let app: AppState
    let language: AppLanguage
    let active: Bool
    var body: some Commands {
        CommandMenu(language.localized("Agent")) {
            Button(language.localized("New Task")) { app.agentSessions.addSession() }.keyboardShortcut("n", modifiers: .command)
                .disabled(!active)
            Button(language.localized("Search Tasks")) { app.agentSessions.searchRequest += 1 }.keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!active)
            Divider()
            Button(language.localized("Previous Task")) { app.agentSessions.selectNeighbor(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!active)
            Button(language.localized("Next Task")) { app.agentSessions.selectNeighbor(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!active)
            Button(language.localized("Toggle Results")) { app.agentSessions.resultsRequest += 1 }.keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!active)
            Button(language.localized("Focus Composer")) { app.agentSessions.composerFocusRequest += 1 }.keyboardShortcut("l", modifiers: .command)
                .disabled(!active)
            Divider()
            Button(language.localized("Increase Text Size")) { app.agentSessions.textSize = min(24, app.agentSessions.textSize + 1) }.keyboardShortcut("+", modifiers: .command)
                .disabled(!active)
            Button(language.localized("Decrease Text Size")) { app.agentSessions.textSize = max(12, app.agentSessions.textSize - 1) }.keyboardShortcut("-", modifiers: .command)
                .disabled(!active)
            Button(language.localized("Reset Text Size")) { app.agentSessions.textSize = 15 }.keyboardShortcut("0", modifiers: .command)
                .disabled(!active)
        }
    }
}
