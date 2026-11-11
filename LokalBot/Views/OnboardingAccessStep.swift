import SwiftUI

/// Setup, step 2: only the permissions the choices need. Each row names the
/// feature it serves and shows its real state.
struct OnboardingAccessStep: View {
    let access: OnboardingAccess
    /// Whether the workday keeps text, which changes what Accessibility reads.
    let readsScreenText: Bool
    /// The permission to ask for, and the button's frame on screen, where the
    /// System Settings helper flies out from.
    let allow: (AppPermission, CGRect) -> Void
    let restart: () -> Void
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingHeading(
                title: "Allow access",
                lead: "LokalBot asks only for what your choices need. Skip one and that feature waits until you allow it.")
            OnboardingCard {
                ForEach(access.rows) { row in
                    if row.id != access.rows.first?.id { Divider() }
                    OnboardingPermissionRow(row: row, readsScreenText: readsScreenText, allow: allow)
                }
            }
            if !access.restartPermissions.isEmpty {
                restartBanner
                    .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
            if access.showsSettingsGuide {
                OnboardingSettingsGuide()
                    .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        // Grants arrive from polling while the user is in System Settings.
        .animation(WorkspaceMotion.animation(.milestone, reduceMotion: reduceMotion), value: access)
    }

    private var restartBanner: some View {
        let language = AppLanguage.matching(locale)
        let names = ListFormatter.onboarding(locale: locale)
            .string(from: access.restartPermissions.map { language.localized($0.title) }) ?? ""
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.clockwise").foregroundStyle(Brand.teal).accessibilityHidden(true)
            Text("Restart LokalBot to finish turning on \(names). Setup reopens right here.")
                .font(.scaled(.body))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restart now", action: restart)
                .accessibilityIdentifier("onboarding.restart")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .lbStatusSurface(Brand.teal)
        .accessibilityElement(children: .contain)
    }
}

private extension ListFormatter {
    static func onboarding(locale: Locale) -> ListFormatter {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter
    }
}

/// One permission: what it is, the feature it serves, why, and where it stands.
private struct OnboardingPermissionRow: View {
    let row: OnboardingAccess.Row
    let readsScreenText: Bool
    let allow: (AppPermission, CGRect) -> Void
    @State private var buttonFrame = CGRect.zero

    private var permission: AppPermission { row.permission }

    var body: some View {
        OnboardingRow(symbol: permission.onboardingSymbol) {
            OnboardingRowTitle(title: LocalizedStringKey(permission.title),
                               tag: LocalizedStringKey(permission.onboardingFeature))
            detail
        } trailing: {
            state
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.permission.\(permission.onboardingIdentifier)")
    }

    @ViewBuilder private var detail: some View {
        switch row.state {
        case .needed, .allowed:
            Text(LocalizedStringKey(permission.onboardingReason(readsScreenText: readsScreenText)))
                .font(.scaled(.callout)).workspaceSupportingForeground()
                .fixedSize(horizontal: false, vertical: true)
        case .waiting:
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch on LokalBot in System Settings, or drag it into the list.")
                    .font(.scaled(.callout)).foregroundStyle(Brand.teal)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open again") { allow(permission, buttonFrame) }
                    .buttonStyle(.workspaceLink)
                    .font(.scaled(.callout))
                    .background(PermissionScreenFrameReader(frameInScreen: $buttonFrame))
            }
        case .allowedAfterRestart:
            sub("arrow.clockwise", "Starts working after LokalBot restarts.")
                .workspaceSupportingForeground()
        case .turnedOff:
            sub("exclamationmark.triangle", "Turned off earlier. Switch it on in System Settings.")
                .foregroundStyle(LBTokens.Palette.attentionText)
        }
    }

    @ViewBuilder private var state: some View {
        switch row.state {
        case .needed:
            Button("Allow…") { allow(permission, buttonFrame) }
                .background(PermissionScreenFrameReader(frameInScreen: $buttonFrame))
                .help(Text(LocalizedStringKey(permission.guidanceHint)))
        case .turnedOff:
            Button("Open System Settings…") { allow(permission, buttonFrame) }
                .background(PermissionScreenFrameReader(frameInScreen: $buttonFrame))
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting").font(.scaled(.callout)).foregroundStyle(.secondary)
            }
        case .allowed, .allowedAfterRestart:
            OnboardingDoneLabel(text: "Allowed")
        }
    }

    private func sub(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.scaled(.callout))
    }
}

private extension AppPermission {
    /// Outline symbols, to sit in the row's tinted tile.
    var onboardingSymbol: String {
        switch self {
        case .microphone: "mic"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    var onboardingIdentifier: String {
        switch self {
        case .microphone: "microphone"
        case .screenRecording: "screenRecording"
        case .accessibility: "accessibility"
        case .inputMonitoring: "inputMonitoring"
        }
    }
}

/// What System Settings will ask for, shown before the person clicks: the
/// LokalBot row in the list, and the box it can be dragged in from.
private struct OnboardingSettingsGuide: View {
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            picture.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("When System Settings opens").font(.scaled(.callout).weight(.semibold))
                Text("Switch on LokalBot in the list. If it isn’t there, drag it in from the box LokalBot puts below the list.")
                    .font(.scaled(.callout)).workspaceSupportingForeground()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 12)
        .lbGroupedSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.settingsGuide")
    }

    /// A System Settings privacy list in miniature: another app switched
    /// off, LokalBot switched on, and an arrow coming up from the drag box.
    private var picture: some View {
        VStack(spacing: 3) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(.quaternary).frame(width: 4, height: 4) }
                    Spacer()
                }
                listRow(name: nil, on: false)
                listRow(name: "LokalBot", on: true)
                    .padding(.horizontal, 3).padding(.vertical, 4)
                    .background(Brand.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Brand.teal, style: StrokeStyle(lineWidth: 1, dash: [3, 2.2]))
                    }
            }
            .padding(6)
            .frame(width: 150)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LBTokens.Palette.groupStroke)
            }
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.teal)
        }
    }

    private func listRow(name: String?, on: Bool) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(on ? AnyShapeStyle(Brand.tealFill) : AnyShapeStyle(.quaternary))
                .frame(width: 9, height: 9)
            if let name {
                Text(verbatim: name).font(.system(size: 8, weight: .semibold))
            } else {
                Capsule().fill(.quaternary).frame(width: 46, height: 3)
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(on ? AnyShapeStyle(LBTokens.Palette.accentFill) : AnyShapeStyle(.quaternary))
                .frame(width: 17, height: 9)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 7, height: 7).padding(1)
                }
        }
    }
}
