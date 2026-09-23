import SwiftUI

struct CotypingModelPreparationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var downloads = ModelDownloadManager.shared

    var compact = false

    var body: some View {
        let status = CotypingModelPreparer.status(
            settings: app.settings,
            storage: app.storage,
            downloads: downloads)
        VStack(alignment: .leading, spacing: 8) {
            ModelPreparationView(
                presentation: presentation(for: status),
                style: compact ? .compact : .standard,
                action: action(for: status))
            if !CotypingModelPreparer.recommendedIsActive(settings: app.settings),
               let entry = status.entry {
                Text("This selects \(entry.displayName) and keeps inline suggestions separate from the model used for meetings and Ask.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if status.entry?.id == ModelCatalog.recommendedCotypingID {
                HStack(spacing: 4) {
                    Text("LFM uses its own commercial and redistribution terms.")
                    Link("Review license", destination: ModelCatalog.recommendedCotypingLicenseURL)
                        .buttonStyle(.workspaceLink)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func presentation(
        for status: CotypingModelPreparationStatus
    ) -> ModelPreparationPresentation {
        switch status {
        case .ready(let entry):
            return .init(
                state: .ready,
                title: "Recommended autocomplete model",
                status: "\(entry.displayName) is ready.",
                actionTitle: isReadyAndActive(status) ? nil : "Use")
        case .downloading(let entry, let progress):
            return .init(
                state: .preparing,
                title: "Preparing autocomplete model",
                status: "Downloading \(entry.displayName) — \(Int(progress * 100))%",
                progress: progress)
        case .failed(let entry, let message):
            return .init(
                state: .failed,
                title: "Autocomplete model needs attention",
                status: "\(entry.displayName): \(message)",
                actionTitle: "Retry")
        case .missing(let entry):
            return .init(
                state: .waiting,
                title: "Recommended autocomplete model",
                status: "\(entry.displayName) has not been downloaded yet.",
                actionTitle: "Prepare")
        case .unavailable:
            return .init(
                state: .failed,
                title: "Autocomplete model unavailable",
                status: "The recommended model is not in this build.")
        }
    }

    private func action(for status: CotypingModelPreparationStatus) -> (() -> Void)? {
        guard !status.isDownloading, status != .unavailable, !isReadyAndActive(status) else {
            return nil
        }
        return { app.prepareRecommendedCotypingModel() }
    }

    private func isReadyAndActive(_ status: CotypingModelPreparationStatus) -> Bool {
        if case .ready = status {
            return CotypingModelPreparer.recommendedIsActive(settings: app.settings)
        }
        return false
    }

}
