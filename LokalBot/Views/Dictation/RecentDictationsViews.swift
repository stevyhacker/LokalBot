import SwiftUI

/// The menu bar's way back to a dictation the clipboard lost: a dictation that
/// finished after focus moved is left on the clipboard, where the next copy
/// replaces it. One row copies the newest and shows its start; earlier ones
/// are in the row's context menu and on the Dictation page.
struct LastDictationMenuRow: View {
    /// Newest first.
    let entries: [DictationHistoryEntry]
    let localized: (String) -> String
    let copy: (DictationHistoryEntry.ID) -> Bool
    @State private var copied = false

    /// How long the row reads "Copied" after a click.
    static let confirmationTime: Duration = .seconds(1.5)

    var body: some View {
        if let latest = entries.first {
            Button { copyEntry(latest.id) } label: {
                MenuBarRowLabel(
                    title: Text(copied ? "Copied" : "Copy last dictation"),
                    icon: copied ? "checkmark" : "doc.on.doc",
                    detail: Text(verbatim: latest.preview))
            }
            .buttonStyle(MenuBarRowStyle())
            .contextMenu {
                ForEach(entries.dropFirst()) { entry in
                    Button { copyEntry(entry.id) } label: { Text(verbatim: entry.menuTitle) }
                }
            }
            .help(Text(verbatim: latest.caption(localized: localized)))
            .accessibilityIdentifier("menubar.lastDictation")
        }
    }

    private func copyEntry(_ id: DictationHistoryEntry.ID) {
        guard copy(id) else { return }
        copied = true
        Task {
            try? await Task.sleep(for: Self.confirmationTime)
            copied = false
        }
    }
}

/// Earlier dictations on the Dictation page, each with a Copy button.
struct RecentDictationsSection: View {
    let entries: [DictationHistoryEntry]
    let localized: (String) -> String
    let copy: (DictationHistoryEntry.ID) -> Bool
    let clear: () -> Void

    var body: some View {
        Section {
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.text)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: entry.caption(localized: localized))
                            .font(.scaled(.caption))
                            .settingsSecondary()
                    }
                    DictationCopyButton { copy(entry.id) }
                }
            }
            SettingsHelp("Saved encrypted on this Mac for 7 days, so you can copy a dictation again after the clipboard changes or the Mac restarts. Text meant for a password field is never kept.")
        } header: {
            HStack {
                Text("Recent dictations")
                Spacer()
                Button("Clear", action: clear)
                    .controlSize(.small)
                    .accessibilityIdentifier("dictation.recent.clear")
            }
        }
        .accessibilityIdentifier("dictation.recent")
    }
}

/// Copy, then "Copied" for a moment.
struct DictationCopyButton: View {
    let copy: () -> Bool
    @State private var copied = false

    var body: some View {
        Button(LocalizedStringKey(copied ? "Copied" : "Copy")) {
            guard copy() else { return }
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .controlSize(.small)
    }
}
