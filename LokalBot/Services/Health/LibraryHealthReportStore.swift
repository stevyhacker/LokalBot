import Foundation

enum LibraryHealthReportStore {
    @discardableResult
    static func write(_ report: LibraryHealthReport, root: URL) throws -> URL {
        let directory = DiagnosticsPaths.healthReports(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("\(report.dayKey).json"),
                                         options: .atomic)
        let markdownURL = directory.appendingPathComponent("\(report.dayKey).md")
        try Data(markdown(report).utf8).write(to: markdownURL, options: .atomic)
        return markdownURL
    }

    static func latestRunDate(root: URL) -> Date? {
        let directory = DiagnosticsPaths.healthReports(root: root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(LibraryHealthReport.self, from: Data(contentsOf: $0)).generatedAt }
            .max()
    }

    static func markdown(_ report: LibraryHealthReport) -> String {
        var lines = ["# LokalBot health — \(report.dayKey)", "",
                     "Overall: **\(report.status.rawValue.uppercased())**", ""]
        for finding in report.findings {
            lines.append("- **\(finding.status.rawValue.uppercased())** \(finding.check.title): \(finding.summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
