import SwiftUI

/// Settings → Day Memory → About you: what the person told LokalBot about
/// themselves, what it learned from their meetings, and learned preferences
/// waiting for review. Every row can be edited or forgotten here.
struct AboutYouSettings: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var personalModel: PersonalModelController
    @ObservedObject var access: PersonalContextAccessManager
    @State private var editing: EditorTarget?
    @State private var confirmingForgetAll = false
    @State private var error: String?

    enum EditorTarget: Identifiable {
        case add
        case edit(PersonalClaim)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let claim): claim.id.uuidString
            }
        }
    }

    var body: some View {
        Group {
            Toggle(isOn: $app.settings.askMemoryEnabled) {
                SettingsLabel("Remember what I tell Ask",
                              help: "Type “Remember …” in Ask or Quick Recall, or add items here. Ask gives the relevant ones to your Think model with each question.")
            }
            .settingTarget("settings.askMemoryEnabled", selected: app.focusedSettingID)
            .accessibilityIdentifier("settings.askMemory")
            Toggle(isOn: $app.settings.personalLearningEnabled) {
                SettingsLabel("Learn about me from my meetings and work",
                              help: "After the overnight review, LokalBot reads your own words from that day: what you said in "
                                  + "meetings, and what you typed to coding agents or in Ask. Up to three new facts or goals from "
                                  + "meetings are saved. Preferences, items from your typing, and goals or projects your work memory "
                                  + "has kept for two weeks wait for your review below. It never learns your principles or values.")
            }
            .settingTarget("settings.personalLearningEnabled", selected: app.focusedSettingID)
            .disabled(!app.settings.askMemoryEnabled)
            .accessibilityIdentifier("settings.personalLearning")
            Toggle(isOn: $app.settings.personalLearningFromDictation) {
                SettingsLabel("Learn from my dictation",
                              help: "Also reads what you dictate into other apps. LokalBot keeps the words you spoke, "
                                  + "encrypted, until that night's learning reads them, and never more than two days. "
                                  + "Only text pasted into a field it could identify is kept; excluded apps and websites, "
                                  + "private windows, and password fields are skipped. Items from dictation always wait "
                                  + "for your review. Turning this off deletes what is kept.")
            }
            .settingTarget("settings.personalLearningFromDictation", selected: app.focusedSettingID)
            .disabled(!app.settings.askMemoryEnabled || !app.settings.personalLearningEnabled)
            .accessibilityIdentifier("settings.personalLearningFromDictation")
            if app.settings.personalLearningEnabled, app.settings.askMemoryEnabled, !app.settings.dreamingEnabled {
                SettingsHelp("Learning runs after the overnight review, which is off.")
            }
            if let loadError = personalModel.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .workspaceTextRole(.warning)
            }
            let suggestions = personalModel.suggestions
            if !suggestions.isEmpty {
                Text(suggestions.count == 1 ? "1 suggestion to review" : "\(suggestions.count) suggestions to review")
                    .font(.scaled(.caption).weight(.semibold))
                    .settingsSecondary()
                ForEach(suggestions) { claim in
                    suggestionRow(claim)
                }
            }
            let claims = personalModel.orderedClaims.filter { $0.status == .confirmed }
            if claims.isEmpty {
                SettingsHelp("Nothing yet. Try “Remember that Maya is my manager” or “Remember: answer in bullet points”.")
            } else {
                ForEach(claims) { claim in
                    row(claim)
                }
            }
            agentAccessLine
            HStack(spacing: 8) {
                Button("Add…") { editing = .add }
                    .disabled(personalModel.loadError != nil)
                    .accessibilityIdentifier("settings.aboutYou.add")
                if !claims.isEmpty {
                    Button("Forget everything…", role: .destructive) { confirmingForgetAll = true }
                }
            }
            if let error { Text(error).workspaceTextRole(.warning) }
            SettingsDetails("How LokalBot uses this",
                            "Items stay on this Mac, encrypted with the same key as your Ask history. Each question gets "
                                + "the items marked Always use, your principles and preferences, and the facts and goals "
                                + "that share words with it, up to about 2,000 characters. If your Think model is a "
                                + "remote server you approved, they are sent there with the question. External agents "
                                + "(MCP clients and the CLI) read only items you mark Share with agents, and only while "
                                + "personal context access is on in Settings → Privacy. Agent Mode, Autocomplete, exports, "
                                + "and diagnostics never get them. Turning this off stops saving and using them in Ask; "
                                + "forget them here to delete them. Learned items go when you delete or correct the "
                                + "meeting they came from, unless you keep them. Questions limited to some sources or "
                                + "days don't get learned items. A forgotten learned item isn't learned again.")
        }
        .onAppear { personalModel.loadIfNeeded() }
        .sheet(item: $editing) { target in
            PersonalClaimEditor(target: target) { text, kind, sharing in
                save(target: target, text: text, kind: kind, sharing: sharing)
            }
        }
        .confirmationDialog(
            "Forget everything LokalBot remembers about you?",
            isPresented: $confirmingForgetAll, titleVisibility: .visible
        ) {
            Button("Forget Everything", role: .destructive) {
                if case .failure(let failure) = personalModel.forgetAll() {
                    error = failure.localizedDescription
                } else {
                    error = nil
                }
                app.forgetDictationForLearning()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every fact, preference, goal, and principle saved here. Your Ask history is kept.")
        }
    }

    private func row(_ claim: PersonalClaim) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: claim.kind.systemImage)
                .foregroundStyle(Brand.teal)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(claim.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsHelp(originLine(for: claim))
                if claim.authority == .learned, let quote = claim.quote {
                    quoteLine(quote, for: claim)
                }
            }
            Spacer(minLength: 8)
            if claim.sharing == .agents {
                Image(systemName: "person.2.wave.2")
                    .foregroundStyle(access.isEnabled ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.secondary))
                    .help(access.isEnabled ? "Shared with agents" : "Marked for agents; personal context access is off")
                    .accessibilityLabel("Shared with agents")
            }
            if claim.alwaysUse {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .help("Always used")
                    .accessibilityLabel("Always used")
            }
            Menu {
                Button("Edit…") { editing = .edit(claim) }
                Button(claim.alwaysUse ? "Stop Always Using" : "Always Use") {
                    report(personalModel.update(claim.id, alwaysUse: !claim.alwaysUse))
                }
                Button(claim.sharing == .agents ? "Stop Sharing with Agents" : "Share with Agents") {
                    report(personalModel.update(
                        claim.id, sharing: claim.sharing == .agents ? .lokalBotOnly : .agents))
                }
                if claim.isLearned, claim.authority != .stated, Self.hasRemovableSource(claim) {
                    Divider()
                    if case .learned(let meetingID, _) = claim.origin {
                        Button("Open Meeting") { app.openMeeting(meetingID) }
                    }
                    Button(Self.keepLabel(for: claim)) {
                        report(personalModel.keepAsStatement(claim.id))
                    }
                }
                Divider()
                Button("Forget", role: .destructive) { report(personalModel.forget([claim.id])) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(claim.text)")
        }
        .contextMenu {
            Button("Edit…") { editing = .edit(claim) }
            Button("Forget", role: .destructive) { report(personalModel.forget([claim.id])) }
        }
        .accessibilityIdentifier("settings.aboutYou.claim")
    }

    @ViewBuilder private var agentAccessLine: some View {
        let shared = personalModel.claims.filter { $0.sharing == .agents }.count
        if access.isEnabled {
            SettingsHelp(shared == 0
                ? "Personal context access is on, but nothing is shared yet. Choose Share with Agents on an item."
                : shared == 1 ? "Agents can read 1 shared item, when it's relevant to their task."
                : "Agents can read \(shared) shared items, when they're relevant to their task.")
        } else if shared > 0 {
            HStack(spacing: 6) {
                SettingsHelp(shared == 1 ? "1 item is marked for agents, but personal context access is off."
                                         : "\(shared) items are marked for agents, but personal context access is off.")
                Button("Privacy settings…") {
                    app.settingsTab = .privacy
                    app.focusedSettingID = "settings.personalContextAccess"
                }
                .buttonStyle(.workspaceLink)
            }
        }
    }

    private func suggestionRow(_ claim: PersonalClaim) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Brand.teal)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(claim.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsHelp(originLine(for: claim))
                if let quote = claim.quote { quoteLine(quote, for: claim) }
                HStack(spacing: 10) {
                    Button("Keep") { report(personalModel.confirm(claim.id)) }
                        .accessibilityIdentifier("settings.aboutYou.suggestion.keep")
                    Button("Edit…") { editing = .edit(claim) }
                    Button("Dismiss") { report(personalModel.dismiss(claim.id)) }
                        .accessibilityIdentifier("settings.aboutYou.suggestion.dismiss")
                    if case .learned(let meetingID, _) = claim.origin {
                        Button("Open Meeting") { app.openMeeting(meetingID) }
                    }
                }
                .buttonStyle(.borderless)
                .font(AppFont.scaled(.callout))
            }
        }
        .accessibilityIdentifier("settings.aboutYou.suggestion")
    }

    /// Dictated words are gone once read, so nothing can retract the item.
    static func hasRemovableSource(_ claim: PersonalClaim) -> Bool {
        if case .typed(.dictation, _) = claim.origin { return false }
        return true
    }

    static func keepLabel(for claim: PersonalClaim) -> String {
        switch claim.origin {
        case .learned: "Keep Even If the Meeting Is Deleted"
        case .typed(.ask, _): "Keep Even If the Conversation Is Deleted"
        default: "Keep Even If the Source Is Deleted"
        }
    }

    private func quoteLine(_ quote: String, for claim: PersonalClaim) -> some View {
        let verb: String
        switch claim.origin {
        case .typed(.dictation, _): verb = "You dictated"
        case .typed: verb = "You typed"
        default: verb = "You said"
        }
        return Text("\(verb): “\(quote)”")
            .font(.scaled(.caption))
            .italic()
            .settingsSecondary()
            .lineLimit(3)
            .textSelection(.enabled)
    }

    private func originLine(for claim: PersonalClaim) -> String {
        let day = claim.createdAt.formatted(date: .abbreviated, time: .omitted)
        let origin: String
        switch claim.origin {
        case .said: origin = "You said this in Ask"
        case .added: origin = "Added in Settings"
        case .learned(let meetingID, _):
            let title = app.meetings.first { $0.id == meetingID }?.title ?? "a meeting"
            origin = Self.learnedOrigin("Learned from \(title)", claim.authority)
        case .typed(.codingAgent(let name), _):
            origin = Self.learnedOrigin("Learned from what you typed to \(name)", claim.authority)
        case .typed(.ask, _):
            origin = Self.learnedOrigin("Learned from a question you asked", claim.authority)
        case .typed(.dictation(let appName), _):
            origin = Self.learnedOrigin(
                appName.isEmpty ? "Learned from your dictation" : "Learned from what you dictated in \(appName)",
                claim.authority)
        case .workMemory(let firstDay):
            let since = DreamDay.date(fromKey: firstDay).map { $0.formatted(date: .abbreviated, time: .omitted) }
                ?? firstDay
            origin = Self.learnedOrigin("In your work memory since \(since)", claim.authority)
        }
        return "\(claim.kind.displayName) · \(origin) · \(day)"
    }

    private static func learnedOrigin(_ base: String, _ authority: PersonalClaim.Authority) -> String {
        switch authority {
        case .learned: base
        case .confirmed: base + ", kept by you"
        case .stated: base + ", now your own statement"
        }
    }

    private func save(target: EditorTarget, text: String, kind: PersonalClaim.Kind,
                      sharing: PersonalClaim.Sharing) -> String? {
        var result: Result<PersonalClaim, PersonalModel.EditError>
        switch target {
        case .add:
            result = personalModel.remember(text, kind: kind, origin: .added)
            if case .success(let claim) = result, claim.sharing != sharing {
                result = personalModel.update(claim.id, sharing: sharing)
            }
        case .edit(let claim):
            result = personalModel.update(claim.id, text: text, kind: kind, sharing: sharing)
        }
        switch result {
        case .success:
            error = nil
            return nil
        case .failure(let failure):
            return failure.localizedDescription
        }
    }

    private func report<T>(_ result: Result<T, PersonalModel.EditError>) {
        if case .failure(let failure) = result {
            error = failure.localizedDescription
        } else {
            error = nil
        }
    }
}

/// Add or edit one claim. Returns an error message from `onSave` to keep the
/// sheet open; nil closes it.
struct PersonalClaimEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: AboutYouSettings.EditorTarget
    let onSave: (String, PersonalClaim.Kind, PersonalClaim.Sharing) -> String?
    @State private var text: String
    @State private var kind: PersonalClaim.Kind
    @State private var sharesWithAgents: Bool
    @State private var error: String?

    init(target: AboutYouSettings.EditorTarget,
         onSave: @escaping (String, PersonalClaim.Kind, PersonalClaim.Sharing) -> String?) {
        self.target = target
        self.onSave = onSave
        switch target {
        case .add:
            _text = State(initialValue: "")
            _kind = State(initialValue: .fact)
            _sharesWithAgents = State(initialValue: false)
        case .edit(let claim):
            _text = State(initialValue: claim.text)
            _kind = State(initialValue: claim.kind)
            _sharesWithAgents = State(initialValue: claim.sharing == .agents)
        }
    }

    private var isAdding: Bool {
        if case .add = target { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isAdding ? "Add to About you" : "Edit")
                .font(.scaled(.title3).weight(.semibold))
            Picker("Kind", selection: $kind) {
                ForEach(PersonalClaim.Kind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.aboutYou.kind")
            TextField(Self.placeholder(for: kind), text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.aboutYou.text")
            Toggle("Share with agents", isOn: $sharesWithAgents)
                .help("MCP clients and the CLI can read this item while personal context access is on in Settings → Privacy.")
                .accessibilityIdentifier("settings.aboutYou.share")
            HStack {
                Text("\(text.count)/\(PersonalModel.maxCharacters)")
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(text.count > PersonalModel.maxCharacters ? AnyShapeStyle(Brand.error)
                                                                               : AnyShapeStyle(.secondary))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let failure = onSave(text, kind, sharesWithAgents ? .agents : .lokalBotOnly) {
                        error = failure
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).workspaceTextRole(.warning) }
        }
        .padding(20)
        .frame(width: 460)
    }

    static func placeholder(for kind: PersonalClaim.Kind) -> String {
        switch kind {
        case .fact: "Maya Chen is my manager."
        case .preference: "Answer in bullet points, amounts in EUR."
        case .goal: "Ship LokalBot 1.0 this year."
        case .principle: "I don't take work that requires relocating my family."
        }
    }
}
