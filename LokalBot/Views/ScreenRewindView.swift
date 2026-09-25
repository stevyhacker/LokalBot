import Combine
import SwiftUI

/// The visual memory rail embedded in Timeline. It deliberately stays within
/// the existing Timeline surface: scrub/play scenes, hover for a temporary
/// preview, save a moment, or select a destructive time range.
struct ScreenRewindView: View {
    enum Presentation: Equatable {
        case standard
        case compact
    }

    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let frames: [ScreenRewindFrame]
    @Binding var selectedSnapshotID: Int64?
    let onReload: () -> Void
    let presentation: Presentation

    @State private var currentIndex = 0
    @State private var hoveredFrameID: Int64?
    @State private var isPlaying = false
    @State private var isSelectingRange = false
    @State private var rangeStartIndex = 0
    @State private var rangeEndIndex = 0
    @State private var deletionReview: CaptureDeletionReview?
    @State private var includeSavedMoments = false
    @State private var deletionFailures: [String] = []

    private let playbackTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    init(
        frames: [ScreenRewindFrame],
        selectedSnapshotID: Binding<Int64?>,
        onReload: @escaping () -> Void,
        presentation: Presentation = .standard
    ) {
        self.frames = frames
        _selectedSnapshotID = selectedSnapshotID
        self.onReload = onReload
        self.presentation = presentation
    }

    private var currentFrame: ScreenRewindFrame? {
        guard !frames.isEmpty else { return nil }
        return frames[ScreenRewindSequence.clampedIndex(currentIndex, count: frames.count)]
    }

    private var previewFrame: ScreenRewindFrame? {
        guard let hoveredFrameID else { return currentFrame }
        return frames.first { $0.id == hoveredFrameID } ?? currentFrame
    }

    var body: some View {
        if !frames.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                header
                if presentation == .standard { preview }
                playbackControls
                filmstrip
                if isSelectingRange {
                    rangeControls
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(presentation == .compact ? 9 : 10)
            .background(.quaternary.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                    .strokeBorder(.quaternary.opacity(0.8))
            }
            .onAppear(perform: synchronizeSelection)
            .onChange(of: frames) { synchronizeSelection() }
            .onChange(of: selectedSnapshotID) { synchronizeSelection() }
            .onReceive(playbackTimer) { _ in advancePlayback() }
            .onDisappear { isPlaying = false }
            .sheet(item: $deletionReview) { review in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review capture deletion").font(WorkspaceTypography.sectionTitle)
                    Text("\(review.interval.start.formatted(date: .abbreviated, time: .standard)) – \(review.interval.end.addingTimeInterval(-0.001).formatted(date: .omitted, time: .standard))")
                    Text("\(review.captures.count) moments, including \(review.pixelCount) image records. Their captured text, search vectors and saved notes will also be removed permanently.")
                    Text("\(review.savedExcluded) saved moments excluded · \(review.savedIncluded) saved moments included")
                    Text("This cannot be undone.").foregroundStyle(Brand.error)
                    HStack {
                        Button("Cancel") { deletionReview = nil }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Delete reviewed moments", role: .destructive) { deleteSelectedRange(review) }
                            .disabled(review.captures.isEmpty)
                    }
                }.padding(24).frame(width: 470)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Label(presentation == .compact ? "Context moments" : "Context rewind",
                  systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .accessibilityIdentifier("timeline.rewind")
            Text("\(frames.count) scene\(frames.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let screenshot = currentFrame?.screenshot {
                Button {
                    toggleSaved(screenshot)
                } label: {
                    Image(systemName: screenshot.isBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(screenshot.isBookmarked ? AnyShapeStyle(Brand.amber)
                                                                : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(screenshot.isBookmarked ? "Remove saved moment" : "Save this moment")
                .accessibilityIdentifier("rewind.bookmark")
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    isSelectingRange.toggle()
                    rangeStartIndex = currentIndex
                    rangeEndIndex = currentIndex
                    isPlaying = false
                }
            } label: {
                Image(systemName: isSelectingRange ? "selection.pin.in.out" : "selection.pin.in.out")
                    .foregroundStyle(isSelectingRange ? AnyShapeStyle(Brand.teal)
                                                      : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(isSelectingRange ? "Finish range selection" : "Select a range to delete")
            .accessibilityIdentifier("rewind.selectRange")
        }
    }

    @ViewBuilder private var preview: some View {
        if let frame = previewFrame {
            Button {
                select(frame)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    ScreenThumbnailView(screenshot: frame.screenshot, height: 150)
                    LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                   startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(frame.screenshot.app)
                                .font(.callout.weight(.semibold))
                            if !frame.screenshot.windowTitle.isEmpty {
                                Text(frame.screenshot.windowTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        if frame.duplicateCount > 1 {
                            Text("\(frame.duplicateCount) similar")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.45), in: Capsule())
                        }
                        Text(frame.screenshot.ts.formatted(date: .omitted, time: .shortened))
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(9)
                }
                .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hoveredFrameID == nil ? "Show this moment in detail" : "Select previewed moment")
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .disabled(currentIndex <= 0)
                .help("Previous scene")
                .accessibilityLabel("Previous context moment")
            Button {
                if currentIndex >= frames.count - 1 { select(index: 0) }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 12)
            }
            .help(isPlaying ? "Pause Rewind" : "Play Rewind")
            .accessibilityLabel(isPlaying ? "Pause context rewind" : "Play context rewind")
            Button { step(1) } label: { Image(systemName: "forward.frame.fill") }
                .disabled(currentIndex >= frames.count - 1)
                .help("Next scene")
                .accessibilityLabel("Next context moment")
            Slider(value: currentIndexBinding,
                   in: 0...Double(max(frames.count - 1, 1)), step: 1)
                .disabled(frames.count < 2)
                .accessibilityLabel("Rewind position")
            Text("\(currentIndex + 1)/\(frames.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(frames) { frame in
                        Button {
                            select(frame)
                        } label: {
                            ScreenThumbnailView(screenshot: frame.screenshot, height: 42)
                                .frame(width: 68)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Brand.Radius.control)
                                        .strokeBorder(
                                            currentFrame?.id == frame.id ? Brand.teal : .clear,
                                            lineWidth: 2)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if frame.screenshot.isBookmarked {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Brand.amber)
                                            .padding(4)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                hoveredFrameID = hovering ? frame.id : nil
                            }
                            .help("\(frame.screenshot.app) · \(frame.screenshot.ts.formatted(date: .omitted, time: .shortened))")
                            .accessibilityLabel("\(frame.screenshot.app) context moment")
                            .accessibilityValue(frame.screenshot.ts.formatted(
                                date: .omitted, time: .shortened))
                            .accessibilityHint("Show this moment in the context panel")
                            .accessibilityIdentifier("timeline.moment.\(frame.id)")
                            .id(frame.id)
                    }
                }
            }
            .frame(height: 44)
            .onChange(of: currentFrame?.id) {
                guard let id = currentFrame?.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Delete range", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(selectedCaptureCount) capture\(selectedCaptureCount == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Text("From").font(.caption2).foregroundStyle(.secondary).frame(width: 28)
                Slider(value: rangeStartBinding,
                       in: 0...Double(max(frames.count - 1, 1)), step: 1)
                DatePicker("From", selection: rangeDateBinding(isStart: true), displayedComponents: .hourAndMinute)
                    .labelsHidden().accessibilityLabel("Delete range from time")
            }
            HStack(spacing: 7) {
                Text("To").font(.caption2).foregroundStyle(.secondary).frame(width: 28)
                Slider(value: rangeEndBinding,
                       in: 0...Double(max(frames.count - 1, 1)), step: 1)
                DatePicker("To", selection: rangeDateBinding(isStart: false), displayedComponents: .hourAndMinute)
                    .labelsHidden().accessibilityLabel("Delete range to time")
            }
            Toggle("Include saved moments", isOn: $includeSavedMoments)
                .font(.caption)
            Text("Times snap to the nearest captured scene. Review shows the exact affected moments.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(deletionFailures, id: \.self) { Text($0).foregroundStyle(Brand.error) }
            HStack {
                Spacer()
                Button("Review deletion") {
                    guard let interval = selectedInterval else { return }
                    do {
                        deletionReview = try app.activityStore.captureDeletionReview(in: interval, includesSaved: includeSavedMoments)
                    } catch { deletionFailures = ["Could not prepare review: \(error.localizedDescription)"] }
                }
                .disabled(selectedCaptureCount == 0)
                .accessibilityIdentifier("rewind.deleteRange")
            }
        }
        .padding(8)
        .background(.red.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private var currentIndexBinding: Binding<Double> {
        Binding(get: { Double(currentIndex) }, set: { select(index: Int($0.rounded())) })
    }

    private var rangeStartBinding: Binding<Double> {
        Binding(get: { Double(rangeStartIndex) }, set: {
            rangeStartIndex = ScreenRewindSequence.clampedIndex(Int($0.rounded()), count: frames.count)
        })
    }

    private var rangeEndBinding: Binding<Double> {
        Binding(get: { Double(rangeEndIndex) }, set: {
            rangeEndIndex = ScreenRewindSequence.clampedIndex(Int($0.rounded()), count: frames.count)
        })
    }

    private var selectedCaptureCount: Int {
        guard let interval = selectedInterval else { return 0 }
        return Set(frames.flatMap(\.screenshots).filter {
            $0.ts >= interval.start && $0.ts < interval.end && (includeSavedMoments || !$0.isBookmarked)
        }.map(\.id)).count
    }

    private func synchronizeSelection() {
        if let selectedSnapshotID,
           let index = frames.firstIndex(where: {
               $0.screenshots.contains { $0.id == selectedSnapshotID }
           }) {
            currentIndex = index
        } else {
            currentIndex = ScreenRewindSequence.clampedIndex(currentIndex, count: frames.count)
            if selectedSnapshotID != nil, frames.isEmpty { self.selectedSnapshotID = nil }
        }
        rangeStartIndex = ScreenRewindSequence.clampedIndex(rangeStartIndex, count: frames.count)
        rangeEndIndex = ScreenRewindSequence.clampedIndex(rangeEndIndex, count: frames.count)
    }

    private func select(_ frame: ScreenRewindFrame) {
        guard let index = frames.firstIndex(where: { $0.id == frame.id }) else { return }
        select(index: index)
    }

    private func select(index: Int) {
        guard !frames.isEmpty else { return }
        currentIndex = ScreenRewindSequence.clampedIndex(index, count: frames.count)
        selectedSnapshotID = frames[currentIndex].screenshot.id
    }

    private func step(_ amount: Int) {
        isPlaying = false
        select(index: currentIndex + amount)
    }

    private func advancePlayback() {
        guard isPlaying, !frames.isEmpty else { return }
        if currentIndex >= frames.count - 1 {
            isPlaying = false
        } else {
            select(index: currentIndex + 1)
        }
    }

    private func toggleSaved(_ screenshot: ActivityStore.Screenshot) {
        do {
            try app.withPrimaryEvidenceChange(on: [screenshot.ts]) {
                if screenshot.isBookmarked {
                    try app.activityStore.removeSavedMoment(snapshotID: screenshot.id)
                } else {
                    try app.activityStore.saveMoment(snapshotID: screenshot.id)
                }
            }
            app.primaryEvidenceDidChange(on: screenshot.ts)
            onReload()
        } catch {
            app.lastError = "Could not update saved moment: \(error.localizedDescription)"
        }
    }

    private var selectedInterval: DateInterval? {
        ScreenRewindSequence.deletionInterval(frames: frames, firstIndex: rangeStartIndex, lastIndex: rangeEndIndex)
    }

    private func rangeDateBinding(isStart: Bool) -> Binding<Date> {
        Binding(get: {
            frames[ScreenRewindSequence.clampedIndex(isStart ? rangeStartIndex : rangeEndIndex, count: frames.count)].screenshot.ts
        }, set: { value in
            guard let nearest = frames.indices.min(by: {
                abs(frames[$0].screenshot.ts.timeIntervalSince(value)) < abs(frames[$1].screenshot.ts.timeIntervalSince(value))
            }) else { return }
            if isStart { rangeStartIndex = nearest } else { rangeEndIndex = nearest }
        })
    }

    private func deleteSelectedRange(_ review: CaptureDeletionReview) {
        do {
            let days = Set(review.captures.map { Calendar.current.startOfDay(for: $0.ts) })
            deletionFailures = try app.withPrimaryEvidenceChange(on: Array(days)) {
                try app.screenshots.applyCaptureDeletionReview(review)
            }
            deletionReview = nil
            app.primaryEvidenceDidChange(on: Array(days))
            selectedSnapshotID = nil
            isSelectingRange = !deletionFailures.isEmpty
            isPlaying = false
            onReload()
        } catch {
            deletionFailures = [error.localizedDescription]
            deletionReview = nil
            onReload()
        }
    }

    private func timeLabel(at index: Int) -> String {
        guard !frames.isEmpty else { return "—" }
        let safe = ScreenRewindSequence.clampedIndex(index, count: frames.count)
        return frames[safe].screenshot.ts.formatted(date: .omitted, time: .shortened)
    }
}
