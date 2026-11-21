import CoreGraphics
import CryptoKit
import DigUpKit
import Foundation
import ImageIO
import SQLite3

@MainActor
final class ScreenImageEmbeddings {
    nonisolated static let modelID = "embeddinggemma-2-q8-mmproj-q8-image280-v\(FileMediaEmbedder.vectorVersion)"
    nonisolated static let budget = 280
    nonisolated static let batchSize = 16
    nonisolated static let batteryLimit = 3 * batchSize
    nonisolated static let vectorBytes = 768 * MemoryLayout<Float>.stride

    struct Session: Sendable {
        let embed: @Sendable (Data) throws -> [Float]
        let end: @Sendable () async -> Void
    }

    typealias StartSession = @MainActor () async throws -> Session
    typealias LoadImage = @Sendable (_ path: String) -> CGImage?

    enum PassOutcome: Equatable {
        case skipped
        case finished(embedded: Int)
        case paused
        case waitingForPower(embedded: Int)
        case failed(String)
    }

    var isEnabled: () -> Bool = { false }
    var isInUse: () -> Bool = { false }
    var pauseReason: () -> FileSearchService.PauseReason? = { nil }
    var isOnBattery: () -> Bool = { false }
    var pacing = IndexPacing.unpaced

    private let database: SQLiteDatabase?
    private let startSession: StartSession
    private let makeLoader: @MainActor () throws -> LoadImage
    private let schedule: EmbeddingIndex.ScreenBackfillSchedule
    private var scheduled: Task<Void, Never>?
    private var running: Task<PassOutcome, Never>?
    private(set) var failures = 0

    init(databaseURL: URL,
         schedule: EmbeddingIndex.ScreenBackfillSchedule = .standard,
         startSession: @escaping StartSession,
         makeLoader: @escaping @MainActor () throws -> LoadImage) {
        self.schedule = schedule
        self.startSession = startSession
        self.makeLoader = makeLoader
        database = SQLiteDatabase(url: databaseURL)
        database?.exec("""
            CREATE TABLE IF NOT EXISTS screen_image_embeddings (
                snapshot_id INTEGER PRIMARY KEY,
                vec BLOB NOT NULL,
                model_id TEXT NOT NULL DEFAULT '',
                FOREIGN KEY(snapshot_id) REFERENCES screenshots(id) ON DELETE CASCADE
            );
            """)
        _ = database?.run("DELETE FROM screen_image_embeddings WHERE model_id != ?1", bind: [Self.modelID])
    }

    static func live(storage: StorageManager, databaseURL: URL) -> ScreenImageEmbeddings {
        let embeddings = ScreenImageEmbeddings(
            databaseURL: databaseURL,
            startSession: {
                let model = try await EmbeddingIndex.preparedModel(storage: storage)
                let projector = try await FileSearchModels.preparedProjector(storageRoot: storage.rootURL)
                let started = try await FileMediaEmbedderRuntime.shared.begin(model: model, projector: projector)
                let embedder = FileMediaEmbedder(endpoint: started.endpoint)
                let pass = started.pass
                return Session(embed: { try embedder.embedImage(png: $0) },
                               end: { await FileMediaEmbedderRuntime.shared.end(pass) })
            },
            makeLoader: {
                let key = try ScreenshotService.encryptionKey()
                return { path in
                    guard let data = ScreenshotService.decryptedData(path: path, key: key),
                          let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(
                        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                }
            })
        embeddings.isOnBattery = { PowerSourceMonitor.currentlyOnBattery() }
        embeddings.pacing = .live
        return embeddings
    }

    func capturesDidArrive() {
        guard scheduled == nil, running == nil, isEnabled(), isInUse() else { return }
        scheduleRun(after: schedule.newTextDelay)
    }

    func resume() {
        guard isEnabled(), isInUse(), running == nil else { return }
        scheduleRun(after: .seconds(1))
    }

    func conditionsDidChange() {
        if !isEnabled() || pauseReason() != nil {
            stop()
        } else if scheduled == nil, running == nil, isInUse() {
            scheduleRun(after: schedule.newTextDelay)
        }
    }

    func stop() {
        scheduled?.cancel()
        scheduled = nil
        running?.cancel()
    }

    private func scheduleRun(after delay: Duration) {
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            let outcome = await self.runPass()
            self.passDidFinish(outcome)
        }
    }

    private func passDidFinish(_ outcome: PassOutcome) {
        switch outcome {
        case .failed(let reason):
            failures += 1
            let delay = schedule.retryDelay(afterFailures: failures)
            lokalbotLog("screen image embedding failed: \(reason); retrying in \(Int(delay.components.seconds)) s")
            scheduleRun(after: delay)
        case .finished, .waitingForPower:
            failures = 0
        case .paused, .skipped:
            break
        }
    }

    @discardableResult
    func runPass() async -> PassOutcome {
        if let running { return await running.value }
        let task = Task { @MainActor [weak self] () -> PassOutcome in
            await self?.performPass() ?? .skipped
        }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    private enum ItemResult: Sendable {
        case vector([Float])
        case unreadable
        case unavailable(String)
    }

    private struct Pending: Sendable {
        let snapshotID: Int64
        let path: String
    }

    private func performPass() async -> PassOutcome {
        guard isEnabled(), isInUse(), let database else { return .skipped }
        guard pauseReason() == nil else { return .paused }
        let loader: LoadImage
        do {
            loader = try makeLoader()
        } catch {
            return .failed("the screenshot key is not available: \(error.localizedDescription)")
        }
        var session: Session?
        var embedded = 0
        var tried = 0
        var outcome: PassOutcome?
        while outcome == nil {
            if Task.isCancelled { outcome = .paused; break }
            if !isEnabled() || pauseReason() != nil { outcome = .paused; break }
            let batch = Self.pending(database, limit: Self.batchSize)
            if batch.isEmpty { outcome = .finished(embedded: embedded); break }
            if tried >= Self.batteryLimit, isOnBattery() { outcome = .waitingForPower(embedded: embedded); break }
            if session == nil {
                do {
                    session = try await startSession()
                } catch {
                    outcome = .failed("the image model did not start: \(error.localizedDescription)")
                    break
                }
            }
            guard let current = session else { break }
            let started = Date()
            let results = await Task.detached(priority: .utility) {
                batch.map { item in (item, Self.embed(item, loader: loader, session: current)) }
            }.value
            var stop: String?
            do {
                try database.withTransaction {
                    for (item, result) in results {
                        let vector: Data
                        switch result {
                        case .vector(let values): vector = Self.vectorData(values)
                        case .unreadable: vector = Data()
                        case .unavailable(let reason):
                            stop = reason
                            continue
                        }
                        guard try database.hasRowChecked(
                            "SELECT 1 FROM screenshots WHERE id = ?1 AND path = ?2 AND path != ''",
                            bind: [item.snapshotID, item.path]) else { continue }
                        try database.runChecked("""
                            INSERT OR REPLACE INTO screen_image_embeddings (snapshot_id, vec, model_id)
                            VALUES (?1, ?2, ?3)
                            """, bind: [item.snapshotID, vector, Self.modelID])
                        if !vector.isEmpty { embedded += 1 }
                    }
                }
            } catch {
                outcome = .failed("could not store picture vectors: \(error.localizedDescription)")
                break
            }
            if let stop { outcome = .failed(stop) }
            tried += batch.count
            let rest = pacing.rest(after: Date().timeIntervalSince(started))
            if outcome == nil, rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
        }
        await session?.end()
        return outcome ?? .paused
    }

    nonisolated private static func embed(_ item: Pending, loader: LoadImage, session: Session) -> ItemResult {
        autoreleasepool {
            guard let image = loader(item.path),
                  let png = try? FileImageSizing.png(of: image, budget: budget) else { return .unreadable }
            do {
                return .vector(try session.embed(png))
            } catch let error as WorkerError {
                return .unavailable(error.description)
            } catch {
                return .unreadable
            }
        }
    }

    nonisolated private static func pending(_ database: SQLiteDatabase, limit: Int) -> [Pending] {
        database.query("""
            SELECT shot.id, shot.path FROM screenshots AS shot
            WHERE shot.id > 0 AND shot.path != ''
              AND NOT EXISTS (
                  SELECT 1 FROM screen_image_embeddings AS embedded
                  WHERE embedded.snapshot_id = shot.id AND embedded.model_id = ?1
              )
            ORDER BY shot.ts DESC, shot.id DESC
            LIMIT ?2
            """, bind: [modelID, limit]) { statement in
            guard let path = sqlite3_column_text(statement, 1) else { return nil }
            return Pending(snapshotID: sqlite3_column_int64(statement, 0), path: String(cString: path))
        }
    }

    nonisolated static func vectorData(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Data() }
            return Data(bytes: base, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    func embeddedCount() -> Int {
        database?.query("""
            SELECT COUNT(*) FROM screen_image_embeddings
            WHERE model_id = ?1 AND length(vec) = ?2
            """, bind: [Self.modelID, Self.vectorBytes]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }
}
