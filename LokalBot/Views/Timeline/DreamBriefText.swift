import SwiftUI

/// The same selectable, linked presentation for every section of a dream.
struct DreamBriefText: View {
    @EnvironmentObject private var app: AppState
    let text: String
    var font: AppFont = .scaled(.body)

    var body: some View {
        SelectableDigestText(
            DreamBriefPresentation.markdown(text, meetings: app.meetings),
            font: font)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == DreamBriefPresentation.linkScheme else { return .systemAction }
                guard let id = DreamBriefPresentation.meetingID(for: url, meetings: app.meetings) else {
                    return .discarded
                }
                app.openMeeting(id)
                return .handled
            })
    }
}
