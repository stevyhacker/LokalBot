import AppKit
import SwiftUI

struct ExclusionRulesEditor: View {
    enum Kind { case applications, domains, writingDomains, folders }
    let title: String
    @Binding var value: String
    let kind: Kind
    @State private var draft = ""
    @State private var error: String?
    @State private var selectedRule: Int?
    @State private var addingRule = false

    private var rules: [String] {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(title)).font(AppFont.scaled(.callout).weight(.semibold))
            VStack(spacing: 0) {
                List(selection: $selectedRule) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        HStack {
                            Label { Text(rule) } icon: { ruleIcon(rule).accessibilityHidden(true) }
                            Spacer()
                            Text(ruleKindLabel)
                                .font(.scaled(.caption)).foregroundStyle(.secondary)
                            if !isValid(rule) {
                                Text("Legacy rule · review").font(.scaled(.callout)).foregroundStyle(Brand.amber)
                            }
                        }
                        .tag(index)
                    }
                }
                .listStyle(.inset)
                .frame(height: CGFloat(min(max(rules.count, 2), 6)) * 28 + 8)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                Divider()
                HStack(spacing: 12) {
                    Button { draft = ""; error = nil; addingRule = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Exclusion…").help("Add Exclusion…")
                        .popover(isPresented: $addingRule) { addRulePopover }
                    Button(action: removeSelectedRule) { Image(systemName: "minus") }
                        .accessibilityLabel("Remove Selected Exclusion").help("Remove Selected Exclusion")
                        .disabled(selectedRule == nil)
                    Spacer()
                    if kind == .applications { Button("Choose App…", action: chooseApplication) }
                    if kind == .folders { Button("Choose Folder…", action: chooseFolder) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .lbGroupedSurface()
            if let error, !addingRule {
                Text(error).workspaceTextRole(.warning)
                    .accessibilityIdentifier("exclusions.error")
            }
            if kind == .writingDomains {
                SettingsHelp("Matches this domain and its subdomains. A pasted URL applies to its whole domain.")
            } else if kind == .domains {
                SettingsHelp("A domain excludes its subdomains too. A URL with a path excludes that URL prefix. Existing rules are kept until you remove them.")
            }
        }
        .onChange(of: value) { selectedRule = nil; error = nil }
    }

    private var addRulePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Exclusion").font(.scaled(.headline))
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder).onSubmit(add)
            if let error { Text(error).workspaceTextRole(.warning) }
            HStack {
                Spacer()
                Button("Cancel") { error = nil; addingRule = false }.keyboardShortcut(.cancelAction)
                Button("Add", action: add).primaryActionButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 360)
    }

    private func removeSelectedRule() {
        guard let index = selectedRule, rules.indices.contains(index) else { return }
        var next = rules
        next.remove(at: index)
        value = next.joined(separator: ", ")
        selectedRule = nil
    }

    private var placeholder: String {
        switch kind {
        case .applications: "Application name"
        case .folders: "~/Code/client-project"
        case .domains, .writingDomains: "example.com or https://example.com/private"
        }
    }

    private var ruleKindLabel: String {
        switch kind {
        case .applications: "App"
        case .folders: "Folder"
        case .domains, .writingDomains: "Domain / URL"
        }
    }

    private func isValid(_ rule: String) -> Bool {
        switch kind {
        case .applications: true
        case .folders: rule.hasPrefix("/") || rule.hasPrefix("~")
        case .domains, .writingDomains: validDomain(rule)
        }
    }

    /// The real app icon when LokalBot can resolve it; a plain symbol otherwise.
    /// An empty rounded square read as an unchecked checkbox.
    @ViewBuilder private func ruleIcon(_ rule: String) -> some View {
        if kind == .applications, let icon = QuickRecallApplicationIconResolver.icon(for: rule) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: kind == .applications ? "square.grid.2x2" : kind == .folders ? "folder" : "globe")
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !candidate.contains(",") else { error = "Add one rule at a time."; return }
        guard isValid(candidate) else {
            error = kind == .folders
                ? "Enter a folder path starting with / or ~. Existing rules remain unchanged."
                : "Enter a domain or an HTTP(S) URL prefix. Existing rules remain unchanged."
            return
        }
        guard !rules.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else {
            error = "This rule is already excluded."
            return
        }
        value = (rules + [candidate]).joined(separator: ", ")
        draft = ""
        error = nil
        addingRule = false
    }

    private func validDomain(_ candidate: String) -> Bool {
        let url = URL(string: candidate.contains("://") ? candidate : "https://\(candidate)")
        return url?.host?.contains(".") == true && !candidate.contains(where: \.isWhitespace)
            && ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
    }

    private func chooseApplication() {
        error = nil
        let panel = NSOpenPanel()
        panel.title = "Choose an application to exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The file name ("Passwords") is not the name the app runs under in
        // every language ("Passwörter"); its bundle identifier is.
        draft = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        add()
    }

    private func chooseFolder() {
        error = nil
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to exclude"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft = (url.path as NSString).abbreviatingWithTildeInPath
        add()
    }
}
