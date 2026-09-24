import SwiftUI

/// One permission line in a grouped Form: state icon, title, rationale, and a
/// Grant button when missing. Shared by Settings, Dictation, and Cotyping so
/// permission state reads the same everywhere. Callers are responsible for
/// `PermissionManager.shared.startPolling()` while the row is visible.
struct PermissionRow: View {
    let permission: AppPermission
    var why: String?
    /// Settings rows keep the 12 pt help size under a 13 pt title; onboarding
    /// reads the rationale at its own larger body size.
    var prominentRationale = false
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        let granted = permissions.granted[permission] ?? permission.isGranted
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                if prominentRationale {
                    Text(why ?? permission.why)
                        .workspaceTextRole(.supporting)
                } else {
                    SettingsHelp(why ?? permission.why)
                }
            }
            Spacer()
            if !granted {
                Button("Grant Access") {
                    PermissionGuidanceController.shared.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame)
                }
                .background(PermissionScreenFrameReader(frameInScreen: $actionButtonFrame))
                .help(permission.guidanceHint)
            }
        }
    }
}
