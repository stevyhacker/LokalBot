import SwiftUI

struct MeetingMergeDraft: Identifiable {
    let id = UUID()
    let meetings: [Meeting]
}

/// Reviewable merge confirmation. The copy makes the operation's data
/// contract explicit: sources remain intact and speaker labels stay scoped to
/// their original recording until the user confirms any identity changes.
struct MeetingMergeSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    let meetings: [Meeting]
    private let sourceDurations: [Meeting.ID: TimeInterval]
    private let totalDuration: TimeInterval
    private let hasTranscript: Bool
    @State private var title: String
    @State private var generateSummary: Bool
    @State private var isMerging = false
    @State private var errorMessage: String?

    init(meetings: [Meeting], storage: StorageManager) {
        let ordered = meetings.sorted { $0.startedAt < $1.startedAt }
        self.meetings = ordered
        var durations: [Meeting.ID: TimeInterval] = [:]
        var total: TimeInterval = 0
        var transcriptAvailable = false
        for meeting in ordered {
            let folder = meeting.folderURL(in: storage)
            transcriptAvailable = transcriptAvailable || FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("transcript.json").path)
            if let duration = Self.sourceDuration(meeting, storage: storage) {
                durations[meeting.id] = duration
                total += duration
            }
        }
        self.sourceDurations = durations
        self.totalDuration = total
        self.hasTranscript = transcriptAvailable
        _title = State(initialValue: Self.suggestedTitle(for: ordered))
        _generateSummary = State(initialValue: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleSection
                    sourceSection
                    summarySection
                    trustNote
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(WorkspaceTypography.editorialBody)
                            .foregroundStyle(Brand.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("meeting.mergeError")
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 650)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.mergeSheet")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Brand.teal)
                .frame(width: 42, height: 42)
                .background(Brand.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
            VStack(alignment: .leading, spacing: 4) {
                Text("Merge meetings")
                    .font(WorkspaceTypography.pageTitle)
                Text("Create one reviewable timeline from \(meetings.count) recordings.")
                    .font(WorkspaceTypography.editorialBody)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .accessibilityAddTraits(.isHeader)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("New meeting name")
                .font(WorkspaceTypography.editorialSectionTitle)
            TextField("Merged meeting", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(WorkspaceTypography.body)
                .accessibilityIdentifier("meeting.mergeTitle")
            Text("You can rename it later from the meeting workspace.")
                .font(WorkspaceTypography.metadata)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Sources")
                    .font(WorkspaceTypography.editorialSectionTitle)
                Spacer()
                Text("\(meetings.count) recordings · \(formattedDuration(totalDuration))")
                    .font(WorkspaceTypography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                    sourceRow(index: index, meeting: meeting)
                    if index < meetings.count - 1 {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.09))
                                .frame(width: 1, height: 11)
                                .padding(.leading, 17)
                            Spacer()
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                    .strokeBorder(Color.primary.opacity(0.10))
            }
            .accessibilityIdentifier("meeting.mergeSources")
        }
    }

    private func sourceRow(index: Int, meeting: Meeting) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(index.isMultiple(of: 2) ? Brand.teal.opacity(0.13) : Brand.them.opacity(0.14))
                Text("\(index + 1)")
                    .font(WorkspaceTypography.metadataEmphasis.monospacedDigit())
                    .foregroundStyle(index.isMultiple(of: 2) ? Brand.teal : Brand.them)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.displayTitle)
                    .font(WorkspaceTypography.rowTitle)
                    .lineLimit(1)
                Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.appName)")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(sourceDurations[meeting.id].map(formattedDuration) ?? "—")
                .font(WorkspaceTypography.metadata.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meeting.mergeSource.\(meeting.id.uuidString)")
    }

    private var summarySection: some View {
        Toggle(isOn: $generateSummary) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Generate a fresh combined summary")
                    .font(WorkspaceTypography.control.weight(.semibold))
                Text(hasTranscript
                     ? "Runs on the merged transcript after the new meeting is created."
                     : "No source transcript is available, so there is nothing to summarize yet.")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .disabled(!hasTranscript)
        .accessibilityIdentifier("meeting.mergeGenerateSummary")
    }

    private var trustNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Brand.teal)
            Text("Original audio, transcripts, summaries, and speaker decisions stay preserved in their source folders. After the merge, those source rows are folded into one meeting, and each speaker keeps a source label so identities do not get mixed automatically.")
                .font(WorkspaceTypography.editorialBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Brand.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.control)
                .strokeBorder(Brand.teal.opacity(0.16))
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isMerging)
            Spacer()
            if isMerging {
                ProgressView()
                    .controlSize(.small)
                Text("Building merged meeting…")
                    .font(WorkspaceTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            Button("Merge meetings") { merge() }
                .primaryActionButton()
                .disabled(isMerging || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("meeting.mergeConfirm")
        }
        .padding(18)
    }

    private static func sourceDuration(_ meeting: Meeting, storage: StorageManager) -> TimeInterval? {
        let folder = meeting.folderURL(in: storage)
        let raw = meeting.recordedDuration
            ?? MeetingAudioFiles.longestDuration(in: folder)
            ?? meeting.duration
        guard let raw, raw.isFinite, raw > 0 else { return nil }
        guard let range = meeting.contentRange, range.isValid else { return raw }
        return min(range.end, raw) - min(range.start, raw)
    }

    private func merge() {
        errorMessage = nil
        isMerging = true
        let requestedTitle = title
        Task { @MainActor in
            do {
                _ = try await app.mergeMeetings(
                    meetings,
                    title: requestedTitle,
                    generateSummary: generateSummary)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isMerging = false
            }
        }
    }

    private static func suggestedTitle(for meetings: [Meeting]) -> String {
        meetings.first?.displayTitle ?? "Meeting"
    }

    private func formattedDuration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        let minutes = seconds / 60
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
