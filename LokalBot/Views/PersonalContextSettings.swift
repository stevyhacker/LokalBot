import SwiftUI

/// Settings → Personal Context: learned items waiting for review, what
/// LokalBot keeps about the person grouped by kind, the learning switches,
/// and what agents can read. Every item can be edited or forgotten here.
struct PersonalContextSettings: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var personalModel: PersonalModelController
    @ObservedObject var access: PersonalContextAccessManager
    @State private var editing: EditorTarget?
    @State private var confirmingForgetAll = false
    @State private var confirmingDismissAll = false
    @State private var showsAllSuggestions = false
    @State private var error: String?

    /// Suggestions shown before "Show N more", so kept items stay in view.
    static let collapsedSuggestionLimit = 5

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
            if let message = personalModel.loadError ?? error {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .workspaceTextRole(.warning)
                }
            }
            reviewSection
            keptSection
            learningSection
            agentsSection
            detailsSection
        }
        .onAppear { personalModel.loadIfNeeded() }
    }

    // MARK: - To review

    @ViewBuilder private var reviewSection: some View {
        let suggestions = personalModel.suggestions
        if !suggestions.isEmpty {
            let limit = Self.collapsedSuggestionLimit
            let visible = showsAllSuggestions ? suggestions : Array(suggestions.prefix(limit))
            Section {
                ForEach(visible) { claim in
                    suggestionRow(claim)
                }
                if suggestions.count > limit {
                    Button {
                        showsAllSuggestions.toggle()
                    } label: {
                        if showsAllSuggestions {
                            Text("Show less")
                        } else {
                            Text("Show \(suggestions.count - limit) more")
                        }
                    }
                    .buttonStyle(.workspaceLink)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("settings.personalContext.suggestions.more")
                }
            } header: {
                sectionHeader("To review", count: suggestions.count,
                              subtitle: "Learned from your own words. LokalBot uses them only after you keep them.") {
                    Button("Keep All") {
                        report(personalModel.confirm(Set(suggestions.map(\.id))))
                    }
                    .buttonStyle(.workspaceLink)
                    .accessibilityIdentifier("settings.personalContext.suggestions.keepAll")
                    Button("Dismiss All") { confirmingDismissAll = true }
                        .buttonStyle(.plain)
                        .settingsSecondary()
                        .accessibilityIdentifier("settings.personalContext.suggestions.dismissAll")
                        .confirmationDialog("Dismiss all suggestions?", isPresented: $confirmingDismissAll,
                                            titleVisibility: .visible) {
                            Button("Dismiss All", role: .destructive) {
                                report(personalModel.forget(Set(personalModel.suggestions.map(\.id))))
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("LokalBot won't suggest them again.")
                        }
                }
            }
        }
    }

    private func suggestionRow(_ claim: PersonalClaim) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: claim.kind.systemImage)
                .settingsSecondary()
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(claim.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                metaLine(for: claim, showsKind: true)
                if let quote = claim.quote {
                    quoteLine(quote, for: claim)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Button { report(personalModel.confirm(claim.id)) } label: {
                    Label("Keep", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityIdentifier("settings.personalContext.suggestion.keep")
                Button { report(personalModel.dismiss(claim.id)) } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("settings.personalContext.suggestion.dismiss")
                actionsMenu(for: claim) {
                    Button("Edit…") { editing = .edit(claim) }
                    if case .learned(let meetingID, _) = claim.origin {
                        Button("Open Meeting") { app.openMeeting(meetingID) }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .editorSheet(for: .edit(claim), editing: $editing, save: save)
        .accessibilityIdentifier("settings.personalContext.suggestion")
    }

    // MARK: - Kept

    @ViewBuilder private var keptSection: some View {
        let claims = personalModel.orderedClaims.filter { $0.status == .confirmed }
        Section {
            if claims.isEmpty {
                SettingsHelp("Nothing yet. Try “Remember that Maya is my manager” or “Remember: answer in bullet points”.")
            } else {
                ForEach(PersonalClaim.Kind.allCases, id: \.self) { kind in
                    let group = claims.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Label {
                            Text(Self.groupTitle(kind))
                        } icon: {
                            Image(systemName: kind.systemImage)
                        }
                        .font(.scaled(.caption).weight(.semibold))
                        .textCase(.uppercase)
                        .settingsSecondary()
                        .accessibilityAddTraits(.isHeader)
                        ForEach(group) { claim in
                            row(claim)
                        }
                    }
                }
            }
        } header: {
            sectionHeader("Kept", count: claims.isEmpty ? nil : claims.count) {
                Button { editing = .add } label: {
                    Label("Add…", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(personalModel.loadError != nil)
                .accessibilityIdentifier("settings.personalContext.add")
                .editorSheet(for: .add, editing: $editing, save: save)
            }
        }
    }

    private func row(_ claim: PersonalClaim) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(claim.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                metaLine(for: claim, showsKind: false)
            }
            Spacer(minLength: 12)
            if claim.alwaysUse {
                Image(systemName: "pin.fill")
                    .font(.scaled(.caption))
                    .settingsSecondary()
                    .help("Always used")
                    .accessibilityLabel("Always used")
            }
            if claim.sharing == .agents {
                Text("Shared")
                    .font(.scaled(.caption).weight(.medium))
                    .foregroundStyle(access.isEnabled ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(access.isEnabled ? AnyShapeStyle(Brand.tealFill.opacity(0.2))
                                                                : AnyShapeStyle(.quaternary)))
                    .help(access.isEnabled ? "Shared with agents" : "Marked for agents; personal context access is off")
            }
            actionsMenu(for: claim) {
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
            }
        }
        .contextMenu {
            Button("Edit…") { editing = .edit(claim) }
            Button("Forget", role: .destructive) { report(personalModel.forget([claim.id])) }
        }
        .editorSheet(for: .edit(claim), editing: $editing, save: save)
        .accessibilityIdentifier("settings.personalContext.claim")
    }

    static func groupTitle(_ kind: PersonalClaim.Kind) -> LocalizedStringKey {
        switch kind {
        case .fact: "Facts"
        case .preference: "Preferences"
        case .goal: "Goals"
        case .principle: "Principles"
        }
    }

    // MARK: - Learning and agents

    private var learningSection: some View {
        Section {
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
        } header: {
            Text("Learning")
        }
    }

    @ViewBuilder private var agentsSection: some View {
        let shared = personalModel.claims.filter { $0.sharing == .agents }.count
        if access.isEnabled || shared > 0 {
            Section {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "person.2.wave.2")
                        .foregroundStyle(access.isEnabled ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(LocalizedStringKey(Self.agentSummary(shared: shared, accessEnabled: access.isEnabled)))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Privacy settings…") {
                        app.settingsTab = .privacy
                        app.focusedSettingID = "settings.personalContextAccess"
                    }
                    .buttonStyle(.workspaceLink)
                }
            } header: {
                Text("Agents")
            }
        }
    }

    static func agentSummary(shared: Int, accessEnabled: Bool) -> String {
        if accessEnabled {
            return shared == 0
                ? "Personal context access is on, but nothing is shared yet. Choose Share with Agents on an item."
                : shared == 1 ? "Agents can read 1 shared item, when it's relevant to their task."
                : "Agents can read \(shared) shared items, when they're relevant to their task."
        }
        return shared == 1 ? "1 item is marked for agents, but personal context access is off."
                           : "\(shared) items are marked for agents, but personal context access is off."
    }

    private var detailsSection: some View {
        Section {
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
        } footer: {
            if !personalModel.claims.isEmpty {
                HStack {
                    Spacer()
                    Button("Forget everything…", role: .destructive) { confirmingForgetAll = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(LBTokens.Palette.recordingText)
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
            }
        }
    }

    // MARK: - Shared row parts

    private func sectionHeader<Actions: View>(
        _ title: LocalizedStringKey, count: Int? = nil, subtitle: LocalizedStringKey? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                if let count {
                    Text(count, format: .number)
                        .font(.scaled(.caption).weight(.semibold).monospacedDigit())
                        .settingsSecondary()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer(minLength: 8)
                HStack(spacing: 12) { actions() }
                    .font(.scaled(.callout).weight(.medium))
                    .textCase(nil)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.scaled(.callout).weight(.regular))
                    .settingsSecondary()
                    .textCase(nil)
            }
        }
    }

    private func actionsMenu<Items: View>(for claim: PersonalClaim,
                                          @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        .fixedSize()
        .accessibilityLabel("Actions for \(claim.text)")
    }

    private func metaLine(for claim: PersonalClaim, showsKind: Bool) -> some View {
        Text(verbatim: Self.metaLine(for: claim, showsKind: showsKind,
                                     meetingTitle: meetingTitle(for: claim)))
            .font(.scaled(.subheadline))
            .settingsSecondary()
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meetingTitle(for claim: PersonalClaim) -> String? {
        guard case .learned(let meetingID, _) = claim.origin else { return nil }
        return app.meetings.first { $0.id == meetingID }?.title
    }

    private func quoteLine(_ quote: String, for claim: PersonalClaim) -> some View {
        let verb: String
        switch claim.origin {
        case .typed(.dictation, _): verb = "You dictated"
        case .typed: verb = "You typed"
        default: verb = "You said"
        }
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.quaternary)
                .frame(width: 2)
            Text(verbatim: "“\(quote)”")
                .font(.scaled(.callout))
                .settingsSecondary()
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(verb): \(quote)"))
    }

    /// "Preference · From Claude Code · 22 Oct": the kind (in review only,
    /// where kept items are grouped by kind instead), where it came from,
    /// and the day, with the year only when it isn't this year.
    static func metaLine(for claim: PersonalClaim, showsKind: Bool, meetingTitle: String?,
                         now: Date = Date(), calendar: Calendar = .current) -> String {
        let source: String
        switch claim.origin {
        case .said: source = "Said in Ask"
        case .added: source = "Added by you"
        case .learned: source = meetingTitle.map { "From \($0)" } ?? "From a meeting"
        case .typed(.codingAgent(let name), _): source = "From \(name)"
        case .typed(.ask, _): source = "From a question in Ask"
        case .typed(.dictation(let appName), _):
            source = appName.isEmpty ? "From your dictation" : "Dictated in \(appName)"
        case .workMemory(let firstDay):
            let since = DreamDay.date(fromKey: firstDay).map { $0.formatted(date: .abbreviated, time: .omitted) }
                ?? firstDay
            source = "In work memory since \(since)"
        }
        var parts = showsKind ? [claim.kind.displayName, source] : [source]
        if claim.status == .confirmed, claim.authority == .learned {
            parts.append("Saved automatically")
        }
        let sameYear = calendar.isDate(claim.createdAt, equalTo: now, toGranularity: .year)
        parts.append(claim.createdAt.formatted(sameYear ? .dateTime.day().month(.abbreviated)
                                                        : .dateTime.day().month(.abbreviated).year()))
        return parts.joined(separator: " · ")
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

private extension View {
    /// The editor sheet hangs off the row or button that opens it: Form
    /// rows load lazily, so a sheet on another row may not exist to present.
    func editorSheet(
        for target: PersonalContextSettings.EditorTarget,
        editing: Binding<PersonalContextSettings.EditorTarget?>,
        save: @escaping (PersonalContextSettings.EditorTarget, String, PersonalClaim.Kind,
                         PersonalClaim.Sharing) -> String?
    ) -> some View {
        sheet(item: Binding(
            get: { editing.wrappedValue?.id == target.id ? editing.wrappedValue : nil },
            set: { editing.wrappedValue = $0 }
        )) { target in
            PersonalClaimEditor(target: target) { text, kind, sharing in
                save(target, text, kind, sharing)
            }
        }
    }
}

/// Add or edit one claim. Returns an error message from `onSave` to keep the
/// sheet open; nil closes it.
struct PersonalClaimEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: PersonalContextSettings.EditorTarget
    let onSave: (String, PersonalClaim.Kind, PersonalClaim.Sharing) -> String?
    @State private var text: String
    @State private var kind: PersonalClaim.Kind
    @State private var sharesWithAgents: Bool
    @State private var error: String?

    init(target: PersonalContextSettings.EditorTarget,
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
            Text(isAdding ? "Add to Personal Context" : "Edit")
                .font(.scaled(.title3).weight(.semibold))
            Picker("Kind", selection: $kind) {
                ForEach(PersonalClaim.Kind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.personalContext.kind")
            TextField(Self.placeholder(for: kind), text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.personalContext.text")
            Toggle("Share with agents", isOn: $sharesWithAgents)
                .help("MCP clients and the CLI can read this item while personal context access is on in Settings → Privacy.")
                .accessibilityIdentifier("settings.personalContext.share")
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
