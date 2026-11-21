import AppKit
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: DictationShortcut
    let defaultShortcut: DictationShortcut
    let accessibilityIdentifier: String
    let changeHelp: LocalizedStringKey
    let validate: (DictationShortcut) -> DictationShortcut.Problem?
    var onRecordingChanged: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: DictationShortcut.Problem?
    @State private var chordModifiers: CGEventFlags = []
    @State private var heldModifiers: CGEventFlags = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if shortcut != defaultShortcut, !isRecording {
                    Button("Reset") { reset() }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("\(accessibilityIdentifier).reset")
                }
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Group {
                        if isRecording, !heldModifiers.isEmpty {
                            Text(verbatim: DictationShortcut(keyCode: nil, modifiers: heldModifiers).displayLabel + "…")
                        } else if isRecording {
                            Text("Press a shortcut…")
                        } else {
                            Text(verbatim: shortcut.displayLabel)
                        }
                    }
                    .frame(minWidth: 96)
                }
                .accessibilityIdentifier(accessibilityIdentifier)
                .help(isRecording
                      ? LocalizedStringKey("Press the new shortcut, or Esc to cancel.")
                      : changeHelp)
            }
            if let problem {
                Text(LocalizedStringKey(problem.message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        problem = nil
        chordModifiers = []
        heldModifiers = []
        isRecording = true
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                handleModifiers(Self.eventFlags(from: event.modifierFlags))
                return event
            }
            handle(event)
            return nil
        }
    }

    private func handleModifiers(_ modifiers: CGEventFlags) {
        heldModifiers = modifiers
        guard modifiers.isEmpty else {
            chordModifiers.formUnion(modifiers)
            return
        }
        let chord = chordModifiers
        chordModifiers = []
        guard !chord.isEmpty else { return }
        accept(DictationShortcut(keyCode: nil, modifiers: chord))
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged(false)
    }

    private func handle(_ event: NSEvent) {
        let candidate = DictationShortcut(
            keyCode: CGKeyCode(event.keyCode),
            modifiers: Self.eventFlags(from: event.modifierFlags))
        if candidate.keyCode == DictationShortcutKeyNames.escape, candidate.modifiers.isEmpty {
            problem = nil
            stopRecording()
            return
        }
        chordModifiers = []
        accept(candidate)
    }

    private func accept(_ candidate: DictationShortcut) {
        if let issue = validate(candidate) {
            problem = issue
            return
        }
        heldModifiers = []
        stopRecording()
        commit(candidate)
    }

    private func reset() {
        problem = validate(defaultShortcut)
        if problem == nil { commit(defaultShortcut) }
    }

    private func commit(_ candidate: DictationShortcut) {
        shortcut = candidate
        problem = shortcut == candidate ? nil : .unavailable
    }

    static func eventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }
}
