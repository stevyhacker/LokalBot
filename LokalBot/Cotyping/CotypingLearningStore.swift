import Combine
import CryptoKit
import Foundation

struct CotypingLearningExample: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var appName: String
    var bundleID: String?
    var surfaceClass: String
    var contextHint: String?
    var prefixTail: String
    var acceptedText: String
    var scopeKey: String?
}

/// Learning is confined to an identified document. Generic windows, messaging
/// surfaces, and unknown websites cannot establish a recipient boundary.
enum CotypingLearningScope {
    static let nativeDocumentApps: Set<String> = [
        "com.apple.textedit", "com.apple.iwork.pages", "com.microsoft.word",
    ]

    static func key(bundleID: String?, documentURLString: String?) -> String? {
        guard let bundle = bundleID?.lowercased(), let raw = documentURLString,
              let url = URL(string: raw) else { return nil }
        let identity: String
        if nativeDocumentApps.contains(bundle), url.isFileURL,
           url.host == nil || url.host == "" || url.host == "localhost" {
            identity = url.standardizedFileURL.path
        } else if CotypingSurfaceClassifier.classify(bundleID: bundle) == .browser,
                  url.scheme == "https", url.host?.lowercased() == "docs.google.com",
                  url.user == nil, url.password == nil, url.port == nil {
            let parts = url.path.split(separator: "/")
            guard parts.count >= 3, parts[0] == "document", parts[1] == "d",
                  !parts[2].isEmpty else { return nil }
            identity = "https://docs.google.com/document/d/" + parts[2]
        } else {
            return nil
        }
        return SHA256.hash(data: Data((bundle + "\u{1f}" + identity).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct CotypingLearningSnapshot: Codable, Equatable, Sendable {
    var examples: [CotypingLearningExample] = []
}

/// Accumulates one visible suggestion's accepted chunks until the coordinator
/// closes that suggestion. Stats can still count each accept gesture, while
/// encrypted learning stores one coherent example and performs one write.
struct CotypingAcceptedSuggestionBatch: Equatable, Sendable {
    struct LearningRecord: Equatable, Sendable {
        var field: CotypingField
        var acceptedText: String
    }

    struct Completion: Equatable, Sendable {
        var acceptedChunkCount: Int
        var learningRecord: LearningRecord?
    }

    private(set) var acceptedChunkCount = 0
    private var learningField: CotypingField?
    private var learningText = ""

    var isEmpty: Bool { acceptedChunkCount == 0 }

    mutating func append(
        field: CotypingField,
        acceptedText: String,
        learningEnabled: Bool
    ) {
        guard !acceptedText.isEmpty else { return }
        acceptedChunkCount += 1
        guard learningEnabled else { return }
        if learningField == nil { learningField = field }
        learningText += acceptedText
    }

    /// Forgets the private text accumulated for the current suggestion while
    /// preserving its accept count so stats can still close on the normal
    /// suggestion boundary.
    mutating func discardLearningRecord() {
        learningField = nil
        learningText = ""
    }

    /// Returns one completed persistence unit and resets the accumulator.
    /// Calling it repeatedly without another accepted chunk is a no-op.
    mutating func complete() -> Completion? {
        guard acceptedChunkCount > 0 else { return nil }
        let learningRecord = learningField.map {
            LearningRecord(field: $0, acceptedText: learningText)
        }
        let completion = Completion(
            acceptedChunkCount: acceptedChunkCount,
            learningRecord: learningRecord)
        self = .init()
        return completion
    }
}

enum CotypingLearningRanker {
    static let maxAcceptedCharacters = 240
    static let maxPrefixCharacters = 180
    static let maxContextCharacters = 180
    static let minimumRankScore = 5
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    static func acceptedText(_ text: String) -> String? {
        guard let cleaned = clean(text, maxCharacters: maxAcceptedCharacters),
              cleaned.count >= 3,
              !CotypingPromptLeakGuard.looksLikePromptScaffolding(cleaned) else { return nil }
        return cleaned
    }

    static func prefixTail(_ text: String) -> String? {
        clean(String(text.suffix(maxPrefixCharacters)), maxCharacters: maxPrefixCharacters)
    }

    static func contextHint(for field: CotypingField) -> String? {
        guard let surface = CotypingSurfaceComposer.compose(
            appName: field.appName,
            bundleID: field.bundleID,
            windowTitle: field.windowTitle,
            fieldPlaceholder: field.fieldPlaceholder)
        else { return nil }
        return clean(
            CotypingSurfaceComposer.prefaceLines(for: surface).joined(separator: " "),
            maxCharacters: maxContextCharacters)
    }

    static func canLearn(from field: CotypingField) -> Bool {
        guard !field.isSecure, field.learningScopeKey?.isEmpty == false else { return false }
        switch CotypingSurfaceClassifier.classify(bundleID: field.bundleID) {
        case .codeEditor, .terminal, .email, .chat:
            return false
        case .browser, .other:
            return true
        }
    }

    static func surfaceKey(for bundleID: String?) -> String {
        CotypingSurfaceClassifier.classify(bundleID: bundleID).learningKey
    }

    static func rankedExamples(
        _ examples: [CotypingLearningExample],
        for field: CotypingField,
        limit: Int,
        now: Date = Date()
    ) -> [String] {
        guard canLearn(from: field), limit > 0 else { return [] }
        let surfaceKey = surfaceKey(for: field.bundleID)
        let prefixTerms = terms(in: field.precedingText)
        let contextTerms = contextHint(for: field).map { terms(in: $0) } ?? []

        let ranked = examples.compactMap { example -> (score: Int, date: Date, text: String)? in
            guard example.scopeKey == field.learningScopeKey,
                  sameBundle(example.bundleID, field.bundleID),
                  isRetained(example, now: now),
                  let text = acceptedText(example.acceptedText) else { return nil }
            let overlap = prefixTerms.intersection(terms(in: example.prefixTail)).count
            guard overlap >= 2 else { return nil }
            var score = 0
            if sameBundle(example.bundleID, field.bundleID) { score += 8 }
            if example.surfaceClass == surfaceKey { score += 3 }
            score += min(overlap, 5)
            if let hint = example.contextHint {
                let contextOverlap = contextTerms.intersection(terms(in: hint)).count
                score += min(contextOverlap, 4)
            }
            if sameAppName(example.appName, field.appName) { score += 2 }
            guard score >= minimumRankScore else { return nil }
            return (score, example.createdAt, text)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.date > $1.date
        }

        var seen = Set<String>()
        var selected: [String] = []
        for item in ranked {
            let key = item.text.lowercased()
            guard seen.insert(key).inserted else { continue }
            selected.append(item.text)
            if selected.count == limit { break }
        }
        return selected
    }

    static func isRetained(_ example: CotypingLearningExample, now: Date) -> Bool {
        example.scopeKey?.isEmpty == false
            && example.createdAt <= now
            && now.timeIntervalSince(example.createdAt) < retentionInterval
    }

    private static func clean(_ text: String, maxCharacters: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxCharacters))
    }

    private static func sameBundle(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.lowercased(), let rhs = rhs?.lowercased(),
              !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs
    }

    private static func sameAppName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func terms(in text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !["the", "and", "for", "that", "this", "with", "you", "your"].contains($0) })
    }
}

/// Async persistence seam. The production actor keeps JSON encoding,
/// encryption, and atomic file replacement off the main actor; tests inject a
/// recorder without touching the user's Keychain.
protocol CotypingLearningPersisting: Sendable {
    func persist(_ snapshot: CotypingLearningSnapshot) async
    func forget() async throws
}

actor EncryptedCotypingLearningPersistence: CotypingLearningPersisting {
    private let url: URL
    private let key: SymmetricKey?

    init(url: URL, key: SymmetricKey?) {
        self.url = url
        self.key = key
    }

    func forget() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func persist(_ snapshot: CotypingLearningSnapshot) {
        guard let key else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else {
                throw NSError(
                    domain: "LokalBot",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "Could not seal cotyping learning data."])
            }
            try combined.write(to: url, options: .atomic)
        } catch {
            // Learning is opportunistic. Match the previous best-effort write
            // behavior without blocking typing or surfacing private content.
        }
    }
}

@MainActor
final class CotypingLearningStore: ObservableObject {
    private static let keychainAccount = "cotyping-learning-key"
    private static let fileName = "cotyping-learning.enc"

    @Published private(set) var exampleCount = 0
    @Published private(set) var isForgetting = false

    private let now: () -> Date
    private var forgetTask: Task<Void, Error>?
    private let maxExamples: Int
    private let persistence: any CotypingLearningPersisting
    private var persistenceTask: Task<Void, Never>?
    private var revision = 0
    private var enqueuedRevision = 0
    private var snapshot: CotypingLearningSnapshot {
        didSet { exampleCount = snapshot.examples.count }
    }

    init(
        storageRoot: URL,
        maxExamples: Int = 500,
        persistence: (any CotypingLearningPersisting)? = nil,
        initialSnapshot: CotypingLearningSnapshot? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let url = storageRoot.appendingPathComponent(Self.fileName)
        self.maxExamples = maxExamples
        self.now = now
        let key: SymmetricKey?
        if let initialSnapshot {
            key = nil
            self.snapshot = initialSnapshot
        } else {
            key = try? KeychainSecrets.symmetricKey(account: Self.keychainAccount)
            self.snapshot = Self.load(from: url, key: key)
        }
        self.persistence = persistence
            ?? EncryptedCotypingLearningPersistence(url: url, key: key)
        self.exampleCount = snapshot.examples.count
        pruneExpiredExamples()
    }

    func recordCompletedSuggestion(field: CotypingField, acceptedText rawText: String) {
        pruneExpiredExamples()
        guard !isForgetting, CotypingLearningRanker.canLearn(from: field),
              let acceptedText = CotypingLearningRanker.acceptedText(rawText) else { return }

        let example = CotypingLearningExample(
            id: UUID(),
            createdAt: now(),
            appName: field.appName,
            bundleID: field.bundleID,
            surfaceClass: CotypingLearningRanker.surfaceKey(for: field.bundleID),
            contextHint: CotypingLearningRanker.contextHint(for: field),
            prefixTail: CotypingLearningRanker.prefixTail(field.precedingText) ?? "",
            acceptedText: acceptedText,
            scopeKey: field.learningScopeKey)
        snapshot.examples.append(example)
        if snapshot.examples.count > maxExamples {
            snapshot.examples.removeFirst(snapshot.examples.count - maxExamples)
        }
        revision &+= 1
        enqueuePersistence()
    }

    func examples(for field: CotypingField, limit: Int) -> [String] {
        pruneExpiredExamples()
        return CotypingLearningRanker.rankedExamples(snapshot.examples, for: field, limit: limit, now: now())
    }

    /// Clear memory immediately, then delete after every older queued write.
    /// New learning is paused while deletion is in flight, so forgotten text
    /// cannot be restored by an asynchronous write completing later.
    func forgetAll() async throws {
        if let forgetTask { return try await forgetTask.value }
        isForgetting = true
        snapshot = .init()
        revision &+= 1
        enqueuedRevision = revision
        let previous = persistenceTask
        let persistence = persistence
        let deletion = Task.detached(priority: .utility) {
            await previous?.value
            try await persistence.forget()
        }
        forgetTask = deletion
        persistenceTask = Task.detached { _ = try? await deletion.value }
        defer { forgetTask = nil; isForgetting = false }
        try await deletion.value
    }

    private func pruneExpiredExamples() {
        let retained = snapshot.examples.filter { CotypingLearningRanker.isRetained($0, now: now()) }
        guard retained.count != snapshot.examples.count else { return }
        snapshot.examples = retained
        revision &+= 1
        enqueuePersistence()
    }

    /// Forces any dirty in-memory snapshot into the background queue, then
    /// waits for it. Used at app termination; ordinary typing never awaits IO.
    func flushPersistence() async {
        if revision != enqueuedRevision { enqueuePersistence() }
        let pending = persistenceTask
        await pending?.value
    }

    /// Waits only for already-enqueued work. Kept internal for deterministic
    /// tests of the completed-suggestion batching boundary.
    func waitForPendingPersistence() async {
        let pending = persistenceTask
        await pending?.value
    }

    private func enqueuePersistence() {
        let persistedSnapshot = snapshot
        enqueuedRevision = revision
        let previous = persistenceTask
        let persistence = persistence
        persistenceTask = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            await persistence.persist(persistedSnapshot)
        }
    }

    private static func load(from url: URL, key: SymmetricKey?) -> CotypingLearningSnapshot {
        guard let encrypted = try? Data(contentsOf: url),
              let key,
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let data = try? AES.GCM.open(sealed, using: key),
              let snapshot = try? JSONDecoder().decode(CotypingLearningSnapshot.self, from: data)
        else { return .init() }
        return snapshot
    }
}

private extension CotypingSurfaceClass {
    var learningKey: String {
        switch self {
        case .codeEditor: "codeEditor"
        case .terminal: "terminal"
        case .email: "email"
        case .chat: "chat"
        case .browser: "browser"
        case .other: "other"
        }
    }
}
