import AppKit
import SwiftUI

struct ExclusionRulesEditor: View {
    enum Kind { case applications, domains, writingDomains }
    let title: String
    @Binding var value: String
    let kind: Kind
    @State private var draft = ""
    @State private var error: String?

    private var rules: [String] {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(WorkspaceTypography.metadataEmphasis)
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack {
                    Label {
                        Text(rule).textSelection(.enabled)
                    } icon: {
                        ruleIcon(rule)
                    }
                    if kind != .applications, !validDomain(rule) {
                        Text("Legacy rule · review").font(WorkspaceTypography.metadata).foregroundStyle(Brand.amber)
                    }
                    Spacer()
                    Button {
                        var next = rules
                        next.remove(at: index)
                        value = next.joined(separator: ", ")
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(rule)")
                }.padding(7).workspaceControl()
            }
            HStack {
                // A plain String keeps the example URL from rendering as a link.
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if kind == .applications { Button("Choose app…", action: chooseApplication) }
            }
            if let error { Text(error).workspaceTextRole(.warning) }
            if kind == .writingDomains {
                SettingsHelp("Matches this domain and its subdomains. A pasted URL applies to its whole domain.")
            } else if kind == .domains {
                SettingsHelp("A domain excludes its subdomains too. A URL with a path excludes that URL prefix. Existing rules are kept until you remove them.")
            }
        }
    }

    private var placeholder: String {
        kind == .applications ? "Application name" : "example.com or https://example.com/private"
    }

    /// The real app icon when LokalBot can resolve it; a plain symbol otherwise.
    /// An empty rounded square read as an unchecked checkbox.
    @ViewBuilder private func ruleIcon(_ rule: String) -> some View {
        if kind == .applications, let icon = QuickRecallApplicationIconResolver.icon(for: rule) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: kind == .applications ? "square.grid.2x2" : "globe")
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(",") else { error = "Add one rule at a time."; return }
        if kind != .applications {
            guard validDomain(candidate) else {
                error = "Enter a domain or an HTTP(S) URL prefix. Existing rules remain unchanged."
                return
            }
        }
        if !rules.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            value = (rules + [candidate]).joined(separator: ", ")
        }
        draft = ""
        error = nil
    }

    private func validDomain(_ candidate: String) -> Bool {
        let url = URL(string: candidate.contains("://") ? candidate : "https://\(candidate)")
        return url?.host?.contains(".") == true && !candidate.contains(where: \.isWhitespace)
            && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application to exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = url.deletingPathExtension().lastPathComponent
        add()
    }
}
