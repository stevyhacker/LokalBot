import SwiftUI

struct RetentionSettingsControls: View {
    @EnvironmentObject private var app: AppState
    @State private var review: RetentionReview?
    @State private var error: String?
    @State private var completion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper("Keep screen context \(app.settings.retentionDays) days", value: Binding(
                get: { app.settings.retentionDays },
                set: { propose(days: $0, forever: app.settings.keepOCRTextForever) }), in: 1...90)
                .settingTarget("settings.retentionDays", selected: app.focusedSettingID)
            Toggle("Keep screen text forever", isOn: Binding(
                get: { app.settings.keepOCRTextForever },
                set: { propose(days: app.settings.retentionDays, forever: $0) }))
                .settingTarget("settings.keepOCRTextForever", selected: app.focusedSettingID)
            Text("Saved moments keep their images and text until you unsave or delete them. Shortening retention opens a cleanup review before changing the policy.")
                .workspaceTextRole(.trust)
            Button("Review expired context…") {
                loadReview(days: app.settings.retentionDays, forever: app.settings.keepOCRTextForever)
            }
            if let error { Text(error).workspaceTextRole(.warning) }
            if let completion { Text(completion).workspaceTextRole(.supporting) }
        }
        .accessibilityIdentifier("settings.retention")
        .sheet(item: $review) { proposal in
            RetentionReviewSheet(review: proposal, error: error, onCancel: { review = nil }, onApply: { apply(proposal) })
        }
    }

    private func propose(days: Int, forever: Bool) {
        if days < app.settings.retentionDays || (app.settings.keepOCRTextForever && !forever) {
            loadReview(days: days, forever: forever)
        } else {
            app.settings.retentionDays = days
            app.settings.keepOCRTextForever = forever
        }
    }

    private func loadReview(days: Int, forever: Bool) {
        do {
            review = try app.activityStore.retentionReview(days: days, keepTextForever: forever)
            error = nil
            completion = nil
        } catch { self.error = error.localizedDescription }
    }

    private func apply(_ proposal: RetentionReview) {
        do {
            let failures = try app.screenshots.applyRetentionReview(proposal)
            let days = Set(proposal.candidates.map { Calendar.current.startOfDay(for: $0.timestamp) })
            app.primaryEvidenceDidChange(on: Array(days))
            app.settings.retentionDays = proposal.days
            app.settings.keepOCRTextForever = proposal.keepTextForever
            review = nil
            completion = failures.isEmpty ? "Retention updated. Reviewed cleanup completed." : nil
            error = failures.isEmpty ? nil : "Retention updated; \(failures.count) moments could not be fully cleaned up.\n" + failures.joined(separator: "\n")
        } catch RetentionReviewError.scopeChanged {
            loadReview(days: proposal.days, forever: proposal.keepTextForever)
            error = RetentionReviewError.scopeChanged.localizedDescription
        } catch { self.error = error.localizedDescription }
    }
}

private struct RetentionReviewSheet: View {
    let review: RetentionReview
    let error: String?
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review retention change").font(WorkspaceTypography.pageTitle)
            Text("Keep images for \(review.days) days. " + (review.keepTextForever ? "Keep unsaved text indefinitely." : "Delete unsaved text and its search vectors on the same schedule."))
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow { Text("Images to remove"); Text("\(review.pixelCount)") }
                GridRow { Text("Text records to remove"); Text("\(review.textCount)") }
                GridRow { Text("Search vectors to remove"); Text("\(review.vectorCount)") }
                GridRow { Text("Saved moments preserved"); Text("\(review.savedCount)") }
                GridRow { Text("Image space recovered"); Text(ByteCountFormatter.string(fromByteCount: review.bytes, countStyle: .file)) }
            }
            if let first = review.oldest, let last = review.newest {
                Text("Affected captures: \(first.formatted()) – \(last.formatted())")
                    .workspaceTextRole(.supporting)
            }
            Text("Cleanup cannot be undone. The policy stays unchanged until you apply this review. Failed deletions remain visible and can be retried.")
                .workspaceTextRole(.trust)
            if let error { Text(error).workspaceTextRole(.warning) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply policy and cleanup", role: .destructive, action: onApply)
                    .primaryActionButton()
                    .accessibilityIdentifier("retention.confirm")
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
