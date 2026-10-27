import SwiftUI

/// The selection actions panel: the selected text and where it came from, the
/// actions that fit it, and the streamed result with ways to use it.
struct SelectionActionsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        SelectionActionsContent(controller: app.selectionActions)
            .background(HiddenWindowButtons())
    }
}

private struct SelectionActionsContent: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismissWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var controller: SelectionActionsController

    @State private var query = ""
    @State private var selection = 0
    /// Typed instructions read matching meetings and work memory unless this
    /// is turned off.
    @State private var instructionUsesMemory = true
    @FocusState private var inputFocused: Bool

    private var isChoosing: Bool {
        switch controller.phase {
        case .idle, .capturing, .choosing: true
        case .generating, .finished, .failed: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .onAppear { inputFocused = true }
        .onDisappear {
            query = ""
            controller.panelClosed()
        }
        .onChange(of: query) { selection = 0 }
        .onChange(of: controller.phase) {
            if controller.phase == .choosing { inputFocused = true }
        }
        .onKeyPress(.upArrow) {
            guard isChoosing else { return .ignored }
            move(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard isChoosing else { return .ignored }
            move(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            controller.dismiss()
            dismissWindow()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if isChoosing {
                    Image(systemName: "text.cursor")
                        .font(.scaled(.title2))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    TextField(controller.capture.hasSelection
                              ? "Choose an action or describe what to do…"
                              : "Describe what to write…",
                              text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($inputFocused)
                        .onSubmit(runSelected)
                        .disabled(controller.capture.issue != nil || controller.phase == .capturing)
                        .accessibilityIdentifier("selectionActions.input")
                } else {
                    Button(action: controller.chooseAgain) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .font(.scaled(.title2))
                    .foregroundStyle(.tint)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Choose another action (⌘[)")
                    .accessibilityLabel("Back to actions")
                    if let action = controller.action {
                        Image(systemName: action.icon)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        title(of: action)
                            .font(.scaled(.title3).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }
            sourceLine
            if controller.capture.hasSelection {
                Text(controller.capture.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(isChoosing ? 3 : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                    .accessibilityLabel("Selected text")
                    .accessibilityValue(controller.capture.text)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Where the text came from and what can happen to the result.
    private var sourceLine: some View {
        let capture = controller.capture
        let appName = capture.source?.appName ?? ""
        let line: String
        if controller.phase == .capturing {
            line = "Reading the selection…"
        } else if capture.hasSelection {
            var parts = ["Selected in \(appName.isEmpty ? "the app" : appName)",
                         "\(capture.text.count.formatted()) characters"]
            if capture.isClipped {
                parts.append("the first \(SelectionActionPrompt.selectionCharacterLimit.formatted()) are used")
            }
            if !capture.canInsert { parts.append("read-only, so results are copied") }
            line = parts.joined(separator: " · ")
        } else if capture.canInsert {
            line = "Nothing selected in \(appName). The result is inserted at the cursor."
        } else if !appName.isEmpty {
            line = "Nothing selected in \(appName). The result is copied to the clipboard."
        } else {
            line = "Nothing selected. The result is copied to the clipboard."
        }
        return HStack(spacing: 6) {
            if !appName.isEmpty, let icon = QuickRecallApplicationIconResolver.icon(for: appName) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            }
            Text(line)
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("selectionActions.source")
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let issue = controller.capture.issue {
            issueView(issue)
        } else {
            switch controller.phase {
            case .idle, .capturing:
                Color.clear
            case .choosing:
                actionList
            case .generating, .finished, .failed:
                resultView
            }
        }
    }

    private func issueView(_ issue: SelectionCaptureResult.Issue) -> some View {
        let appName = controller.capture.source?.appName ?? "this app"
        let message: String = switch issue {
        case .accessibilityNeeded:
            "LokalBot needs Accessibility access to read the selected text and paste results back."
        case .excludedApp:
            "\(appName) is in your excluded apps, so LokalBot did not read anything from it."
        case .secureField:
            "A password field has focus. LokalBot does not read or paste into password fields."
        case .focusChanged:
            "LokalBot could not confirm the selected field. Select the text again and press the shortcut."
        }
        return VStack(spacing: 12) {
            Image(systemName: issue == .accessibilityNeeded ? "hand.raised" : "lock.shield")
                .font(.scaled(.title))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.scaled(.callout))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .accessibilityIdentifier("selectionActions.issue")
            if issue == .accessibilityNeeded, let url = AppPermission.accessibility.settingsURL {
                Button("Open Accessibility Settings") { _ = NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var rows: [SelectionAction] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtIn = SelectionAction.matching(
            trimmed, hasSelection: controller.capture.hasSelection, language: app.settings.appLanguage)
        guard !trimmed.isEmpty else { return builtIn }
        // A typed instruction leads, unless it is just the start of an action's name.
        let custom = SelectionAction.custom(trimmed, usesMemory: instructionUsesMemory)
        return builtIn.isEmpty ? [custom] : builtIn + [custom]
    }

    @ViewBuilder private var actionList: some View {
        let rows = rows
        if rows.isEmpty {
            ContentUnavailableView {
                Label("Write with your memory", systemImage: "text.cursor")
            } description: {
                Text("Describe what to write, like “a status update on the beta launch”. LokalBot drafts it with the local model and, when on, your meetings and work memory.")
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, action in
                            Button { run(action) } label: {
                                SelectionActionRow(action: action, title: title(of: action),
                                                   selected: index == selection)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(action.id)
                            .accessibilityAddTraits(index == selection ? [.isSelected] : [])
                            .accessibilityIdentifier("selectionActions.row.\(action.id)")
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) {
                    if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
                }
            }
        }
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let notice = controller.notice {
                    Label(notice, systemImage: "doc.on.clipboard")
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.amber.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                        .accessibilityIdentifier("selectionActions.notice")
                }
                if case .failed(let message) = controller.phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("selectionActions.error")
                } else if controller.output.isEmpty {
                    LoadingStateLabel(loadingText)
                } else {
                    Text(controller.output)
                        .font(.scaled(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("selectionActions.output")
                }
                if !controller.memorySources.isEmpty {
                    memorySources
                }
            }
            .padding(18)
        }
    }

    private var loadingText: String {
        if controller.action?.usesMemory == true, controller.modelName == nil {
            return "Looking through your meetings and work memory…"
        }
        return controller.modelName.map { "Writing with \($0)…" } ?? "Writing…"
    }

    /// The meetings the memory lookup matched, so a claim can be checked.
    private var memorySources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From your memory")
                .font(.scaled(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(controller.memorySources) { source in
                        Button {
                            app.openMeeting(source.id)
                            WindowAccess.shared.open("main")
                            controller.panelClosed()
                            dismissWindow()
                        } label: {
                            Label(sourceLabel(source), systemImage: "waveform")
                                .font(.scaled(.caption))
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Open this meeting")
                    }
                }
            }
        }
    }

    private func sourceLabel(_ source: SelectionMemoryContext.Source) -> String {
        guard let date = source.date else { return source.title }
        return "\(source.title) · \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if isChoosing {
                Text("↑↓ Navigate   ↩ Run   esc Close")
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Toggle("Use my memory for typed instructions", isOn: $instructionUsesMemory)
                    .toggleStyle(.checkbox)
                    .font(.scaled(.caption))
                    .help("Typed instructions search your meetings and work memory first. Built-in rewrites never do.")
                inferenceLabel
            } else {
                Button("Try Again", action: controller.retry)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(controller.phase == .generating)
                Spacer(minLength: 0)
                inferenceLabel
                resultButtons
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    @ViewBuilder private var resultButtons: some View {
        let finished = controller.phase == .finished
        if controller.capture.canInsert, controller.action?.result == .replacement {
            Button("Copy", action: copy)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!finished)
                .accessibilityIdentifier("selectionActions.copy")
            Button(controller.capture.hasSelection ? "Replace Selection" : "Insert", action: insert)
                .keyboardShortcut(.defaultAction)
                .disabled(!finished)
                .accessibilityIdentifier("selectionActions.insert")
        } else {
            if controller.capture.canInsert {
                Button(controller.capture.hasSelection ? "Replace Selection" : "Insert", action: insert)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!finished)
                    .accessibilityIdentifier("selectionActions.insert")
            }
            Button("Copy", action: copy)
                .keyboardShortcut(.defaultAction)
                .disabled(!finished)
                .accessibilityIdentifier("selectionActions.copy")
        }
    }

    private var inferenceLabel: some View {
        let inference = InferencePresentation(settings: app.settings)
        return Label(inference.label, systemImage: inference.icon)
            .font(.scaled(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(inference.detail(
                local: "Selection actions use a model on this Mac.",
                remote: "Selection actions use your configured remote model."))
    }

    // MARK: - Actions

    /// Built-in titles are interface text; a typed instruction is the user's.
    private func title(of action: SelectionAction) -> Text {
        action.id == SelectionAction.customID
            ? Text(verbatim: action.title)
            : Text(LocalizedStringKey(action.title))
    }

    private func move(by offset: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = (selection + offset + count) % count
    }

    private func runSelected() {
        let rows = rows
        guard rows.indices.contains(selection) else { return }
        run(rows[selection])
    }

    private func run(_ action: SelectionAction) {
        query = ""
        controller.run(action)
    }

    private func copy() {
        controller.copyOutput()
        dismissWindow()
    }

    private func insert() {
        controller.insertOutput()
        dismissWindow()
    }
}

private struct SelectionActionRow: View {
    let action: SelectionAction
    let title: Text
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.icon)
                .font(.scaled(.title3))
                .foregroundStyle(selected ? Color.white : LBTokens.Palette.accentText)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.scaled(.callout))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if action.id == SelectionAction.customID {
                    Text(action.usesMemory ? "Run this instruction with your memory" : "Run this instruction")
                        .font(.scaled(.caption))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                } else if action.usesMemory {
                    Text("Uses your meetings and work memory")
                        .font(.scaled(.caption))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "return")
                .font(.scaled(.caption))
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? LBTokens.Palette.accentFill : .clear,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
    }
}
