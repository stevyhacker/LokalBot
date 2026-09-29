import SwiftUI

/// Deletes the screen captures retained in a time range of one day. Times snap
/// to captured scenes, and a review sheet lists exactly what will be removed
/// before anything is deleted.
struct CaptureRangeDeletionView: View {
    @EnvironmentObject private var app: AppState

    let frames: [ScreenRewindFrame]
    let onDeleted: () -> Void

    @State private var isExpanded = false
    @State private var rangeStartIndex = 0
    @State private var rangeEndIndex = 0
    @State private var includeSavedMoments = false
    @State private var deletionReview: CaptureDeletionReview?
    @State private var deletionFailures: [String] = []

    var body: some View {
        if !frames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isExpanded.toggle()
                    if isExpanded {
                        rangeStartIndex = 0
                        rangeEndIndex = frames.count - 1
                        deletionFailures = []
                    }
                } label: {
                    Label(isExpanded ? "Cancel Range Deletion" : "Delete Captures in a Time Range…",
                          systemImage: "trash")
                }
                .accessibilityIdentifier("timeline.deleteRange.toggle")
                if isExpanded { rangeControls }
            }
            .onChange(of: frames) {
                rangeStartIndex = ScreenRewindSequence.clampedIndex(rangeStartIndex, count: frames.count)
                rangeEndIndex = ScreenRewindSequence.clampedIndex(rangeEndIndex, count: frames.count)
            }
            .sheet(item: $deletionReview) { review in
                reviewSheet(review)
            }
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("From").font(.scaled(.caption)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                DatePicker("From", selection: rangeDateBinding(isStart: true), displayedComponents: .hourAndMinute)
                    .labelsHidden().accessibilityLabel("Delete range from time")
                Text("To").font(.scaled(.caption)).foregroundStyle(.secondary)
                DatePicker("To", selection: rangeDateBinding(isStart: false), displayedComponents: .hourAndMinute)
                    .labelsHidden().accessibilityLabel("Delete range to time")
                Spacer()
                Text("\(selectedCaptureCount) capture\(selectedCaptureCount == 1 ? "" : "s")")
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Toggle("Include saved moments", isOn: $includeSavedMoments)
                .font(.scaled(.caption))
            Text("Times snap to the nearest captured scene. Review shows the exact affected moments.")
                .font(.scaled(.caption)).foregroundStyle(.secondary)
            ForEach(deletionFailures, id: \.self) { Text($0).foregroundStyle(Brand.error) }
            HStack {
                Spacer()
                Button("Review Deletion") {
                    guard let interval = selectedInterval else { return }
                    do {
                        deletionReview = try app.activityStore.captureDeletionReview(
                            in: interval, includesSaved: includeSavedMoments)
                    } catch {
                        deletionFailures = ["Could not prepare review: \(error.localizedDescription)"]
                    }
                }
                .disabled(selectedCaptureCount == 0)
                .accessibilityIdentifier("timeline.deleteRange")
            }
        }
        .padding(8)
        .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private func reviewSheet(_ review: CaptureDeletionReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review capture deletion").font(AppFont.scaled(.headline))
            Text("\(review.interval.start.formatted(date: .abbreviated, time: .standard)) – \(review.interval.end.addingTimeInterval(-0.001).formatted(date: .omitted, time: .standard))")
            Text("\(review.captures.count) moments, including \(review.pixelCount) image records. Their captured text, search vectors and saved notes will also be removed permanently.")
            Text("\(review.savedExcluded) saved moments excluded · \(review.savedIncluded) saved moments included")
            Text("This cannot be undone.").foregroundStyle(Brand.error)
            HStack {
                Button("Cancel") { deletionReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete reviewed moments", role: .destructive) { deleteReviewed(review) }
                    .disabled(review.captures.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private var selectedInterval: DateInterval? {
        ScreenRewindSequence.deletionInterval(frames: frames, firstIndex: rangeStartIndex, lastIndex: rangeEndIndex)
    }

    private var selectedCaptureCount: Int {
        guard let interval = selectedInterval else { return 0 }
        return Set(frames.flatMap(\.screenshots).filter {
            $0.ts >= interval.start && $0.ts < interval.end && (includeSavedMoments || !$0.isBookmarked)
        }.map(\.id)).count
    }

    private func rangeDateBinding(isStart: Bool) -> Binding<Date> {
        Binding(get: {
            frames[ScreenRewindSequence.clampedIndex(isStart ? rangeStartIndex : rangeEndIndex, count: frames.count)]
                .screenshot.ts
        }, set: { value in
            guard let nearest = frames.indices.min(by: {
                abs(frames[$0].screenshot.ts.timeIntervalSince(value))
                    < abs(frames[$1].screenshot.ts.timeIntervalSince(value))
            }) else { return }
            if isStart { rangeStartIndex = nearest } else { rangeEndIndex = nearest }
        })
    }

    private func deleteReviewed(_ review: CaptureDeletionReview) {
        do {
            let days = Set(review.captures.map { Calendar.current.startOfDay(for: $0.ts) })
            deletionFailures = try app.withPrimaryEvidenceChange(on: Array(days)) {
                try app.screenshots.applyCaptureDeletionReview(review)
            }
            deletionReview = nil
            app.primaryEvidenceDidChange(on: Array(days))
            isExpanded = !deletionFailures.isEmpty
            onDeleted()
        } catch {
            deletionFailures = [error.localizedDescription]
            deletionReview = nil
            onDeleted()
        }
    }
}
