import Foundation

/// Capture the journal revision before awaiting a model, then verify it again
/// immediately before committing. A user edit or a newer generation wins.
enum DayDigestJournalWriter {
    struct Revision: Equatable, Sendable {
        var digest: String?
    }

    /// A two-file journal commit cannot be made atomic by the filesystem. Keep
    /// enough intent beside it to finish the ownership sidecar after a crash.
    /// Readers recognize the intended digest while this record exists, so a
    /// generated journal never becomes user-owned merely because the sidecar
    /// write was interrupted.
    private struct PendingWrite: Codable {
        static let currentVersion = 1

        var version: Int
        var expectedJournalDigest: String?
        var journalDigest: String
        var quality: DayDigestGenerationQuality
        var generatedAt: Date
        var evidenceLatestAt: Date?
        var evidenceSignature: String?
        var meetingEvidenceSignature: String?
    }

    private final class ActiveWriteRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func insert(_ url: URL) {
            lock.lock()
            paths.insert(url.path)
            lock.unlock()
        }

        func remove(_ url: URL) {
            lock.lock()
            paths.remove(url.path)
            lock.unlock()
        }

        func contains(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.contains(url.path)
        }
    }

    private static let activeWrites = ActiveWriteRegistry()

    enum WriteError: LocalizedError {
        case changedDuringGeneration

        var errorDescription: String? {
            "The journal changed while its digest was being generated. Your changes were preserved."
        }
    }

    static func revision(at url: URL) throws -> Revision {
        do {
            return Revision(digest: ContentFingerprint.digest(try Data(contentsOf: url)))
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError else {
                throw error
            }
            return Revision(digest: nil)
        }
    }

    static func write(
        _ text: String, to url: URL, replacing expected: Revision,
        evidence: DayDigestEvidence, quality: DayDigestGenerationQuality
    ) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try finishPendingWrite(at: url)
        guard try revision(at: url) == expected else { throw WriteError.changedDuringGeneration }
        activeWrites.insert(url)
        defer { activeWrites.remove(url) }

        let data = Data(text.utf8)
        let pending = PendingWrite(
            version: PendingWrite.currentVersion,
            expectedJournalDigest: expected.digest,
            journalDigest: ContentFingerprint.digest(data),
            quality: quality,
            generatedAt: Date(),
            evidenceLatestAt: evidence.latestEvidenceAt,
            evidenceSignature: evidence.contentSignature,
            meetingEvidenceSignature: evidence.meetingSignature)
        try JSONEncoder().encode(pending).write(
            to: transactionURL(for: url),
            options: .atomic)

        try data.write(to: url, options: .atomic)
        let metadata = try DayDigestGenerationMetadataStore.record(
            quality: quality, evidenceLatestAt: evidence.latestEvidenceAt,
            evidenceSignature: evidence.contentSignature,
            meetingEvidenceSignature: evidence.meetingSignature, for: url,
            generatedAt: pending.generatedAt)
        guard metadata.journalDigest == pending.journalDigest,
              DayDigestGenerationMetadataStore.journalMatches(metadata, at: url) else {
            try? FileManager.default.removeItem(
                at: DayDigestGenerationMetadataStore.metadataURL(for: url))
            throw WriteError.changedDuringGeneration
        }
        try removeTransactionIfPresent(for: url)
    }

    static func transactionURL(for journalURL: URL) -> URL {
        journalURL.deletingPathExtension().appendingPathExtension("write.json")
    }

    static func hasPendingWrite(at journalURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: transactionURL(for: journalURL).path)
    }

    /// Return recoverable ownership even when persisting the repaired sidecar
    /// still fails. Callers can therefore retract generated text without ever
    /// mistaking it for a user edit, and a later read retries the repair.
    static func recoverPendingMetadata(at journalURL: URL) -> DayDigestGenerationMetadata? {
        guard let pending = loadPendingWrite(at: journalURL) else { return nil }
        guard let journalData = try? Data(contentsOf: journalURL),
              ContentFingerprint.digest(journalData) == pending.journalDigest else {
            if !activeWrites.contains(journalURL) {
                try? removeTransactionIfPresent(for: journalURL)
            }
            return nil
        }

        let previous = DayDigestGenerationMetadataStore.loadWithoutRecovery(
            for: journalURL)
        if let previous, metadata(previous, matches: pending) {
            try? removeTransactionIfPresent(for: journalURL)
            return previous
        }
        if pending.expectedJournalDigest == pending.journalDigest {
            // An interrupted rewrite of byte-identical user content is
            // indistinguishable from a commit that never reached the journal.
            // Resolve that ambiguity in favor of the user's prior ownership.
            if !activeWrites.contains(journalURL) {
                try? removeTransactionIfPresent(for: journalURL)
            }
            return nil
        }

        guard let recovered = try? DayDigestGenerationMetadataStore.makeMetadata(
            quality: pending.quality,
            evidenceLatestAt: pending.evidenceLatestAt,
            evidenceSignature: pending.evidenceSignature,
            meetingEvidenceSignature: pending.meetingEvidenceSignature,
            for: journalURL,
            generatedAt: pending.generatedAt,
            previous: previous)
        else { return nil }

        do {
            try DayDigestGenerationMetadataStore.persist(
                recovered,
                for: journalURL)
            try removeTransactionIfPresent(for: journalURL)
        } catch {
            // The transaction remains the durable ownership record. A later
            // read retries once the filesystem failure is gone.
        }
        return recovered
    }

    private static func finishPendingWrite(at journalURL: URL) throws {
        let transaction = transactionURL(for: journalURL)
        guard FileManager.default.fileExists(atPath: transaction.path) else { return }
        guard recoverPendingMetadata(at: journalURL) != nil else {
            if FileManager.default.fileExists(atPath: transaction.path) {
                try removeTransactionIfPresent(for: journalURL)
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: transaction.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func loadPendingWrite(at journalURL: URL) -> PendingWrite? {
        guard let data = try? Data(contentsOf: transactionURL(for: journalURL)),
              let pending = try? JSONDecoder().decode(PendingWrite.self, from: data),
              pending.version == PendingWrite.currentVersion else { return nil }
        return pending
    }

    private static func removeTransactionIfPresent(for journalURL: URL) throws {
        let url = transactionURL(for: journalURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func metadata(
        _ metadata: DayDigestGenerationMetadata,
        matches pending: PendingWrite
    ) -> Bool {
        metadata.quality == pending.quality
            && metadata.generatedAt == pending.generatedAt
            && metadata.evidenceLatestAt == pending.evidenceLatestAt
            && metadata.evidenceSignature == pending.evidenceSignature
            && metadata.meetingEvidenceSignature == pending.meetingEvidenceSignature
            && metadata.journalDigest == pending.journalDigest
    }
}
