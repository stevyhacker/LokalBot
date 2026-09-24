import SwiftUI

struct GenerationTestFailurePresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case openRouterDataPolicy
        case generic
    }

    let kind: Kind
    let inlineTitle: String
    let title: String
    let explanation: String
    let recovery: String
    let privacyNote: String?
    let actionTitle: String?
    let actionURL: URL?
    let technicalDetails: String

    init(
        error: Error,
        baseURL: String?,
        model: String?,
        openRouterDataPolicy: OpenRouterDataPolicy = .privateOnly
    ) {
        let technicalDetails = error.localizedDescription
        let normalizedDetails = technicalDetails.lowercased()
        let host = baseURL.flatMap(URL.init(string:))?.host?.lowercased()
        let isOpenRouter = host == "openrouter.ai"
            || host?.hasSuffix(".openrouter.ai") == true
        let isDataPolicyFailure = normalizedDetails.contains("data policy")
            || normalizedDetails.contains("paid model training")
            || normalizedDetails.contains("openrouter.ai/settings/privacy")

        self.technicalDetails = technicalDetails

        if isOpenRouter && isDataPolicyFailure {
            let modelName = model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedModel = modelName.flatMap { $0.isEmpty ? nil : $0 }
                ?? "the selected model"

            kind = .openRouterDataPolicy
            switch openRouterDataPolicy {
            case .privateOnly:
                inlineTitle = "Private routing unavailable — review options…"
                title = "No private endpoint for this model"
                explanation = "LokalBot restricts OpenRouter to providers that do not collect "
                    + "inference data, but no available endpoint for \(selectedModel) matches "
                    + "that requirement."
                recovery = "Keep “Private endpoints only” and choose a compatible model, or "
                    + "change Provider data use to follow your OpenRouter privacy settings."
                privacyNote = "Private endpoints only remains recommended for meeting content."
                actionTitle = nil
                actionURL = nil
            case .accountPolicy:
                inlineTitle = "OpenRouter still blocks this model — review issue…"
                title = "OpenRouter still blocks this model"
                explanation = "LokalBot is following your OpenRouter policy, but OpenRouter "
                    + "couldn't find an allowed endpoint for \(selectedModel)."
                recovery = "Review the privacy settings and any guardrail assigned to this "
                    + "account, API key, or workspace, or choose another model."
                privacyNote = "LokalBot cannot read which OpenRouter policy applies to this "
                    + "key. Providers allowed by that policy may retain or train on approved "
                    + "meeting transcripts, screen text, and Agent context."
                actionTitle = "Open OpenRouter Privacy Settings"
                actionURL = URL(string: "https://openrouter.ai/settings/privacy")
            }
        } else {
            kind = .generic
            inlineTitle = "Test failed — review issue…"
            title = "Generation test failed"
            explanation = "LokalBot couldn't complete the test request."
            recovery = "Check the server URL, model name, API key, and server availability, "
                + "then try again."
            privacyNote = nil
            actionTitle = nil
            actionURL = nil
        }
    }
}

struct GenerationTestFailurePopover: View {
    let failure: GenerationTestFailurePresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(Brand.error)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(.headline)
                    Text(failure.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close error details")
            }

            Text(failure.recovery)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = failure.actionTitle,
               let actionURL = failure.actionURL {
                Link(destination: actionURL) {
                    Label(actionTitle, systemImage: "arrow.up.right.square")
                }
                .primaryActionButton()
                .controlSize(.large)
                .accessibilityIdentifier("models.generationTest.openPrivacy")
            }

            if let privacyNote = failure.privacyNote {
                Label {
                    Text(privacyNote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Brand.amber.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Technical details — select to copy")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(failure.technicalDetails)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 82)
                .padding(9)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
                .accessibilityIdentifier("models.generationTest.technicalDetails")
            }
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
        .accessibilityIdentifier("models.generationTest.details")
    }
}
