import SwiftUI

/// One presentation model for first-use downloads and local-runtime startup.
/// Cotyping, Dictation, and Ask use the same vocabulary and recovery shape so
/// a long first run never falls back to an unexplained spinner.
struct ModelPreparationPresentation: Equatable {
    enum State: Equatable {
        case waiting
        case preparing
        case ready
        case failed
    }

    var state: State
    var title: String
    var status: String
    var progress: Double?
    var actionTitle: String?

    init(
        state: State,
        title: String,
        status: String,
        progress: Double? = nil,
        actionTitle: String? = nil
    ) {
        self.state = state
        self.title = title
        self.status = status
        self.progress = progress
        self.actionTitle = actionTitle
    }
}

struct ModelPreparationView: View {
    enum Style: Equatable {
        case standard
        case compact
        case hud
    }

    let presentation: ModelPreparationPresentation
    var style: Style = .standard
    var action: (() -> Void)?

    var body: some View {
        switch style {
        case .standard, .compact:
            standardBody
        case .hud:
            hudBody
        }
    }

    private var standardBody: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.title)
                    .font(style == .compact ? .scaled(.caption) : .scaled(.callout))
                Text(presentation.status)
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            preparationProgress(width: style == .compact ? 58 : 80)
            actionButton
        }
        .accessibilityElement(children: .contain)
    }

    private var hudBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.scaled(.caption))
                    .foregroundStyle(tint)
                Text(presentation.title)
                    .font(.scaled(.callout).weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                actionButton
            }
            HStack(spacing: 7) {
                preparationProgress(width: 72)
                Text(presentation.status)
                    .font(.scaled(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func preparationProgress(width: CGFloat) -> some View {
        if presentation.state == .preparing {
            if let progress = presentation.progress {
                ProgressView(value: max(0, min(1, progress)))
                    .frame(width: width)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if let title = presentation.actionTitle, let action {
            Button(title, action: action)
                .controlSize(style == .standard ? .small : .mini)
        }
    }

    private var iconName: String {
        switch presentation.state {
        case .waiting: "arrow.down.circle"
        case .preparing: "arrow.down.circle"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch presentation.state {
        case .waiting: .orange
        case .preparing: Brand.teal
        case .ready: .green
        case .failed: .orange
        }
    }
}
