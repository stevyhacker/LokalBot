import Foundation

enum SampleMeeting {
    struct Recording: Equatable, Sendable {
        let id: String
        let language: String
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

    static let question = "Is the delivery window field required in the Orders API response?"

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
