import SwiftUI

struct ModelChecksSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var checks: ModelCheckController
    @Environment(\.dismiss) private var dismiss

    init(app: AppState) {
        self.app = app
        roles = app.modelRoles
        checks = app.modelChecks
    }

    private var availableRoles: [ModelRole] { ModelRole.allCases.filter { roles.snapshot[$0].isReady } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSheetHeading(title: "Check model setup", subtitle: "Check each available model independently using sample content.")
            VStack(alignment: .leading, spacing: 18) {
                Label(disclosure, systemImage: InferencePresentation(settings: app.settings).icon)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Checks confirm that a model responds. They do not measure transcription accuracy or answer quality.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                ForEach(ModelRole.allCases, id: \.self) { role in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: role.settingsIcon).font(.system(size: 19)).frame(width: 26)
                            .settingsModelIcon(role == .think ? InferencePresentation(settings: app.settings) : .onDevice)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(role.settingsTitle).font(.system(size: 14, weight: .semibold))
                            if checks.testingRole == role {
                                Text("Checking…").foregroundStyle(.secondary)
                            } else if let result = checks.results[role] {
                                Text(result.label).foregroundStyle(result.failure == nil ? Color.secondary : Color.orange)
                                    .textSelection(.enabled)
                                if result.failure == nil {
                                    Text(String(format: "Sample check completed in %.1f seconds", result.elapsed))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(roles.snapshot[role].isReady ? "Not checked yet" : roles.snapshot[role].label)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12))
                        Spacer()
                        if checks.testingRole == role { ProgressView().controlSize(.small) }
                        Button(checks.results[role]?.failure == nil ? "Check" : "Retry") { checks.run([role], app: app) }
                            .disabled(checks.isTesting || !roles.snapshot[role].isReady)
                            .accessibilityIdentifier("models.check.\(role.rawValue)")
                    }
                    if role != ModelRole.allCases.last { Divider() }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            Divider()
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if checks.isTesting {
                    Button("Cancel checks") { checks.cancel() }
                } else {
                    Button("Check available models") { checks.run(availableRoles, app: app) }
                        .primaryActionButton().keyboardShortcut(.defaultAction)
                        .disabled(availableRoles.isEmpty)
                        .accessibilityIdentifier("models.check.available")
                }
            }
            .padding(20)
        }
        .frame(width: 680)
        .onDisappear { checks.cancel() }
    }

    private var disclosure: String {
        InferencePresentation(settings: app.settings).detail(
            local: "Sample audio and text are processed on this Mac. No meeting, screen, or clipboard content is used.",
            remote: "Think sends a short sample prompt to your approved server. Transcription and autocomplete are checked on this Mac.")
    }
}
