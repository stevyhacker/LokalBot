import SwiftUI

struct SpeakerIdentitySettingsControls: View {
    @EnvironmentObject var app: AppState
    @State private var managingProfiles = false

    var body: some View {
        Toggle(isOn: $app.settings.rememberSpeakersOnMac) {
            SettingsLabel("Remember speakers on this Mac",
                          help: "When you confirm who spoke into this Mac's microphone, eligible voice samples can create an encrypted local profile that suggests the name in later recordings. Remote participants' voices are never remembered, and automatic guesses never train profiles.")
        }
            .accessibilityLabel("Remember speakers on this Mac")
            .accessibilityIdentifier("settings.rememberSpeakers")
        if !app.settings.multiSpeakerDiarization {
            SettingsHelp("Turn on “Separate voices by speaker” to collect the voice samples remembering needs.")
        }
        Button("Manage remembered people…") { managingProfiles = true }
            .sheet(isPresented: $managingProfiles) {
                SpeakerVoiceProfileManager(identity: app.speakerIdentity)
            }
    }
}

private struct SpeakerVoiceProfileManager: View {
    @ObservedObject var identity: MeetingSpeakerIdentityService
    @Environment(\.dismiss) private var dismiss
    @State private var people: [SpeakerVoiceProfile] = []
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remembered people").font(.title2.bold())
            Text("Voice profiles stay on this Mac. Forgetting a person removes their samples and identity links. Existing transcript names remain.")
                .font(.callout).foregroundStyle(.secondary)
            if people.isEmpty {
                Text("No remembered voices yet. Confirm a speaker after a recording with enough clear speech.")
                    .foregroundStyle(.secondary).padding(.vertical)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(people) { person in
                        SpeakerVoiceProfileRow(person: person) { name in
                            perform { try await identity.renameProfile(person.id, name: name) }
                        } onForget: {
                            perform { try await identity.forgetProfile(person.id) }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Clear all", role: .destructive) { perform { try await identity.forgetProfile(nil) } }
                    .disabled(people.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520).disabled(busy)
        .task { await reload() }
    }
    private func reload() async {
        do { people = try await identity.profiles(managing: true) } catch { self.error = "Could not read remembered people: \(error.localizedDescription)" }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); error = nil; await reload() } catch { self.error = "Change pending: \(error.localizedDescription)" }
        }
    }
}

private struct SpeakerVoiceProfileRow: View {
    let person: SpeakerVoiceProfile
    let onRename: (String) -> Void
    let onForget: () -> Void
    @State private var name: String
    init(person: SpeakerVoiceProfile, onRename: @escaping (String) -> Void, onForget: @escaping () -> Void) {
        self.person = person; self.onRename = onRename; self.onForget = onForget
        _name = State(initialValue: person.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Person's name", text: $name).textFieldStyle(.roundedBorder)
                Button("Rename") { onRename(name) }.disabled(name == person.name || ParticipantObservation.safeName(name) == nil)
                Button("Forget", role: .destructive, action: onForget)
            }
            Text("\(person.contributions.count) confirmed recording(s) · Profile \(person.id.uuidString.prefix(6))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Lives inside the existing native rename sheet; evidence never joins the
/// ordinary transcript model or its search/export paths.
struct SpeakerIdentityReview: View {
    let speaker: String
    let state: MeetingSpeakerIdentityState?
    let profiles: [SpeakerVoiceProfile]
    let rememberingEnabled: Bool
    @Binding var name: String
    @Binding var remember: Bool
    @Binding var profileID: UUID?
    let onPlay: (Double) -> Void
    let onAction: (SpeakerAliasDecision.Action, String?, Bool, UUID?) -> Void
    let onDeleteEvidence: () -> Void
    var canConfirmIdentity = false
    var microphoneIsUser = false
    private var assignment: SpeakerIdentityAssignment? { state?.assignments.first { $0.label == speaker } }
    /// Only voices recorded by this Mac's microphone can be remembered.
    private var isMicrophoneVoice: Bool {
        (assignment?.source ?? state?.timeline.first { $0.speaker == speaker }?.resolvedSource) == .microphone
    }

    private var identityDescription: String {
        if let isUser = assignment?.isLocalUser { return isUser ? "Confirmed as you" : "Confirmed as someone else" }
        return microphoneIsUser ? "Attributed to you from your microphone" : "Confirm who is speaking"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canConfirmIdentity {
                Text(identityDescription)
                    .font(.subheadline.weight(.semibold))
                HStack {
                    if let time = assignment?.anchors.first?.start { Button("Play speech") { onPlay(time) } }
                    Button("This is me") { onAction(.confirmUser, name, remember, profileID) }
                    Button("Someone else") { onAction(.confirmOther, name, remember, profileID) }
                }
            } else {
                Text("This audio mixes voices, so it can't be confirmed as one person. You can still name it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let match = assignment?.match, assignment?.origin.isProtected == false {
                Text("Automatically identified").font(.subheadline.weight(.semibold))
                Text(match.explanation).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let time = match.evidence.first?.start { Button("Play supporting speech") { onPlay(time) } }
                    Button("Undo") { onAction(.undo, assignment?.name, false, nil) }
                }
            }
            if assignment?.automaticDisabled == true {
                Text("Automatic naming is paused for this speaker.").font(.caption).foregroundStyle(.secondary)
                Button("Resume automatic identification") { onAction(.resume, nil, false, nil) }
            }
            if let candidates = state?.suggestions[speaker], !candidates.isEmpty, assignment?.origin.isProtected != true {
                Text("Suggested names").font(.subheadline.weight(.semibold))
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button(candidate.name) { name = candidate.name; profileID = candidate.profileID }
                            Spacer()
                            if let time = candidate.evidence.first?.start { Button("Play") { onPlay(time) } }
                            Button("Dismiss") { onAction(.dismiss, candidate.name, false, nil) }
                        }
                        Text(candidate.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if rememberingEnabled && speaker != "me" && isMicrophoneVoice {
                Picker("Remember this choice", selection: $remember) {
                    Text("This meeting only").tag(false)
                    Text("Remember on this Mac").tag(true)
                }
                if remember {
                    Picker("Person", selection: $profileID) {
                        Text("Create a new person").tag(UUID?.none)
                        ForEach(profiles) { profile in
                            Text("\(profile.name) · \(profile.id.uuidString.prefix(6))").tag(Optional(profile.id))
                        }
                    }
                    Text("Select an existing person explicitly to add voice samples to their profile. Similar names are never merged automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let previous = state?.assignments.filter({ $0.label.hasPrefix("unresolved-") && $0.name != nil }), !previous.isEmpty {
                Text("Previously named voices").font(.subheadline.weight(.semibold))
                Text("Speaker separation changed. Play the saved speech before choosing a previous name for this speaker.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(previous.prefix(6)) { item in
                    HStack {
                        Button(item.name ?? "Unnamed") { name = item.name ?? ""; profileID = nil }
                        if let time = item.anchors.first?.start { Button("Play saved speech") { onPlay(time) } }
                    }
                }
            }
            if state?.revision ?? 0 > 0 {
                Button("Delete meeting speaker evidence", role: .destructive, action: onDeleteEvidence)
                    .font(.caption)
                Text("Keeps your saved speaker names and remembered voice profiles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
