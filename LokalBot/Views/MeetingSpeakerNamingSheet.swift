import SwiftUI

/// One sheet to name a meeting's unnamed voices: play a sample, read what
/// that voice said, then pick an invited name or type one. Names are saved
/// together; a voice left alone stays unnamed.
struct MeetingSpeakerNamingSheet: View {
    let voices: [MeetingSpeakerNamingVoice]
    let known: [MeetingSpeakerNamingKnown]
    let suggestions: [MeetingSpeakerSuggestion]
    /// Guests already assigned to a voice in this meeting.
    let assignedCalendarIdentityIDs: Set<String>
    let canPlay: Bool
    let busy: Bool
    let notice: String?
    let onPlay: (Transcript.Segment) -> Void
    let onChange: (String) -> Void
    let onSave: ([MeetingSpeakerNamingChoice]) -> Void
    let onCancel: () -> Void

    @State private var draft: MeetingSpeakerNamingDraft
    @State private var listHeight: CGFloat = 0
    @FocusState private var focusedVoice: String?
    @Environment(\.locale) private var locale

    init(voices: [MeetingSpeakerNamingVoice], known: [MeetingSpeakerNamingKnown],
         suggestions: [MeetingSpeakerSuggestion], assignedCalendarIdentityIDs: Set<String>,
         canPlay: Bool, busy: Bool, notice: String?,
         onPlay: @escaping (Transcript.Segment) -> Void, onChange: @escaping (String) -> Void,
         onSave: @escaping ([MeetingSpeakerNamingChoice]) -> Void, onCancel: @escaping () -> Void) {
        self.voices = voices
        self.known = known
        self.suggestions = suggestions
        self.assignedCalendarIdentityIDs = assignedCalendarIdentityIDs
        self.canPlay = canPlay
        self.busy = busy
        self.notice = notice
        self.onPlay = onPlay
        self.onChange = onChange
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: MeetingSpeakerNamingDraft(voices: voices, suggestions: suggestions))
    }

    private var choices: [MeetingSpeakerNamingChoice] { draft.choices(for: voices.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name speakers").font(AppFont.scaled(.title3).bold())
                Text("Play a voice, then pick who it is. LokalBot learns each voice for later meetings. Voices stay encrypted on this Mac.")
                    .workspaceTextRole(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(voices) { voice in
                        voiceRow(voice)
                        Divider()
                    }
                    ForEach(known) { speaker in
                        knownRow(speaker)
                        Divider()
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // A sheet sizes to its content, and a scroll view has no height of
            // its own: show every voice until the list would outgrow the window.
            .frame(height: min(max(listHeight, 60), 420))
            HStack(spacing: 8) {
                Group {
                    if let notice {
                        Text(verbatim: notice)
                    } else {
                        Text("Skip any voice you are not sure about.")
                    }
                }
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("meeting.naming.cancel")
                Button("Save names") { onSave(choices) }
                    .primaryActionButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(choices.isEmpty)
                    .accessibilityIdentifier("meeting.naming.save")
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 600)
        .disabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Name speakers")
        .accessibilityIdentifier("meeting.namingSheet")
        .background {
            SheetContainerName(name: AppLanguage.matching(locale).localized("Name speakers"))
                .accessibilityHidden(true)
        }
    }

    private func voiceRow(_ voice: MeetingSpeakerNamingVoice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if let sample = voice.sample { onPlay(sample) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Brand.tealFill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(voice.sample == nil || !canPlay)
            .opacity(voice.sample == nil || !canPlay ? 0.4 : 1)
            .help("Play Voice")
            .accessibilityLabel("Play Voice")
            .accessibilityValue(voice.label)
            .accessibilityIdentifier("meeting.naming.play.\(voice.id)")
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(LBTokens.Palette.speaker(at: voice.colorIndex))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(verbatim: voice.label).font(AppFont.scaled(.body).weight(.semibold))
                    Spacer(minLength: 8)
                    speechSummary(voice)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                }
                if let sample = voice.sample {
                    Text(verbatim: "“\(sample.text)”")
                        .font(AppFont.scaled(.body))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentLayoutDirection(of: sample.text)
                }
                MeetingWrappingRow(spacing: 6, lineSpacing: 6) {
                    let named = suggestions.filter { $0.name != nil }
                    // A recognized voice that is also a guest is that guest's
                    // chip, already picked; otherwise it gets a chip of its own.
                    if let recognized = voice.recognizedName {
                        let pick = MeetingSpeakerNamingDraft.recognizedPick(
                            recognized, for: voice.id, among: suggestions)
                        if !named.contains(where: { $0.id == pick.id }) {
                            chip(Text(verbatim: recognized), pick: pick, voice: voice,
                                 identifier: "meeting.naming.recognized.\(voice.id)")
                                .help("Recognized from earlier meetings")
                        }
                    }
                    if named.contains(where: { $0.calendar != nil }) {
                        Text("Invited")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
                    }
                    ForEach(named) { suggestion in
                        let pick = MeetingSpeakerNamingDraft.Pick(
                            id: suggestion.id, name: suggestion.name ?? "",
                            calendarIdentityID: suggestion.calendar?.id)
                        chip(Text(verbatim: pick.name), pick: pick, voice: voice,
                             identifier: "meeting.naming.choice.\(voice.id).\(suggestion.id)")
                            .opacity(isUsed(suggestion, by: voice) ? 0.45 : 1)
                    }
                    Button { beginTyping(voice) } label: { Text("Someone else…") }
                        .buttonStyle(MeetingNameChipStyle(selected: draft.isTyping(for: voice.id)))
                        .accessibilityIdentifier("meeting.naming.other.\(voice.id)")
                }
                if draft.isTyping(for: voice.id) {
                    TextField("Speaker name", text: Binding(
                        get: { draft.typedNames[voice.id] ?? "" },
                        set: { draft.typedNames[voice.id] = $0 }), prompt: Text("Name this speaker"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .focused($focusedVoice, equals: voice.id)
                        .accessibilityIdentifier("meeting.naming.name.\(voice.id)")
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(voice.label)
        .accessibilityIdentifier("meeting.naming.voice.\(voice.id)")
    }

    private func knownRow(_ speaker: MeetingSpeakerNamingKnown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(LBTokens.Palette.speaker(at: speaker.colorIndex))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(verbatim: speaker.name).font(AppFont.scaled(.body).weight(.semibold))
            if speaker.wasRecognized {
                Text("Recognized from earlier meetings")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(Color(nsColor: WorkspaceTextColor.supporting))
            }
            Spacer(minLength: 8)
            Button("Change…") { onChange(speaker.id) }
                .buttonStyle(.workspaceLink)
                .font(AppFont.scaled(.callout))
                .accessibilityIdentifier("meeting.naming.change.\(speaker.id)")
        }
        .padding(.leading, 22 + 26 + 12)
        .padding(.trailing, 22)
        .padding(.vertical, 12)
    }

    /// "12 min of speech · 2 actions"
    private func speechSummary(_ voice: MeetingSpeakerNamingVoice) -> Text {
        let speech = Text("\(MeetingDetailPresentation.speechMinutes(voice.speechSeconds)) min of speech")
        guard voice.actionCount > 0 else { return speech }
        let actions = voice.actionCount == 1 ? Text("1 action") : Text("\(voice.actionCount) actions")
        return speech + Text(verbatim: " · ") + actions
    }

    private func chip(_ label: Text, pick: MeetingSpeakerNamingDraft.Pick, voice: MeetingSpeakerNamingVoice,
                      identifier: String) -> some View {
        let selected = draft.isPicked(pick.id, for: voice.id)
        return Button { draft.toggle(pick, for: voice.id) } label: { label.lineLimit(1) }
            .buttonStyle(MeetingNameChipStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(identifier)
    }

    /// Dimmed, and still a choice: the guest already names another voice.
    private func isUsed(_ suggestion: MeetingSpeakerSuggestion, by voice: MeetingSpeakerNamingVoice) -> Bool {
        if draft.isTakenElsewhere(suggestion.id, for: voice.id) { return true }
        guard let id = suggestion.calendar?.id else { return false }
        return assignedCalendarIdentityIDs.contains(id)
    }

    private func beginTyping(_ voice: MeetingSpeakerNamingVoice) {
        draft.typeName(for: voice.id)
        focusedVoice = draft.isTyping(for: voice.id) ? voice.id : nil
    }
}

/// Names the view a sheet is hosted in. Assistive tools see that host as a
/// group around the sheet's content, and it has no name of its own.
private struct SheetContainerName: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.name = name
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.name = name
        probe.apply()
    }

    final class Probe: NSView {
        var name = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Only an unnamed host is named, so a window that says what it is
        /// keeps its own words.
        func apply() {
            guard let host = window?.contentView, host !== self,
                  (host.accessibilityLabel() ?? "").isEmpty || host.accessibilityLabel() == name else { return }
            host.setAccessibilityLabel(name)
        }
    }
}

/// A rounded name choice: outlined, filled with the accent once picked.
private struct MeetingNameChipStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        // A rounded rectangle, not a capsule: a capsule's inset border drew
        // stray marks at its ends at this size.
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label
            .font(AppFont.scaled(.callout).weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? AnyShapeStyle(Brand.tealFill)
                        : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)),
                        in: shape)
            .overlay {
                shape.strokeBorder(selected ? Brand.tealFill
                                   : .primary.opacity(contrast == .increased ? 0.5 : 0.18))
            }
            .contentShape(shape)
    }
}
