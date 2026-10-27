import Foundation

/// LokalBot's sample meeting (`Resources/SampleMeeting`): a made-up call
/// between two synthetic voices, bundled so a new library can show a cited
/// answer before anything is recorded. It goes through the ordinary import
/// and carries `Meeting.sampleID`, so Ask, search and agents see it while
/// personal memory leaves it out. The Windows and Linux app embeds the same
/// recording (`lokalbot_engine::sample`).
///
/// `Scripts/sample_meeting.py` builds the audio and its reference transcript,
/// and scores a transcript of it.
enum SampleMeeting {
    /// One recording of the sample, in one spoken language.
    struct Recording: Equatable, Sendable {
        /// Stored as the meeting's `sampleID`: the script, then its language.
        let id: String
        let language: String
        /// The meeting's title, in the language spoken.
        let title: String
        let fileName: String
    }

    static let english = Recording(
        id: "orders-api/en", language: "en",
        title: "Sample: Orders API delivery window", fileName: "orders-api.en.m4a")

    static let recordings = [
        english,
        Recording(id: "orders-api/de", language: "de",
                  title: "Beispiel: delivery window in der Orders API", fileName: "orders-api.de.m4a"),
        Recording(id: "orders-api/zh", language: "zh",
                  title: "示例：Orders API 的 delivery window", fileName: "orders-api.zh.m4a"),
        Recording(id: "orders-api/sr-Latn", language: "sr-Latn",
                  title: "Primer: delivery window u Orders API-ju", fileName: "orders-api.sr-Latn.m4a"),
    ]

    /// The question the sample suggests for Ask, shown in the interface
    /// language. Its answer is in the passage where the decision changes
    /// (`SampleMeeting/expected.<language>.json`).
    static let question = "Is the delivery window field required in the Orders API response?"

    /// The sample spoken in `language` (an interface language such as "de" or
    /// "sr-Latn"), else the English one.
    static func recording(for language: String) -> Recording {
        let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
        return recordings.first { $0.language.caseInsensitiveCompare(language) == .orderedSame }
            ?? recordings.first { $0.language.caseInsensitiveCompare(base) == .orderedSame }
            ?? english
    }

    static func audioURL(for recording: Recording, bundle: Bundle = .main) -> URL? {
        let url = URL(fileURLWithPath: recording.fileName)
        return bundle.url(forResource: url.deletingPathExtension().lastPathComponent,
                          withExtension: url.pathExtension, subdirectory: "SampleMeeting")
    }
}
