import XCTest
@testable import LokalBot

final class DreamMemoryRetractionTests: XCTestCase {
    private let day = "2026-08-03"
    private let otherDay = "2026-08-06"
    private let now = Date(timeIntervalSince1970: 1_788_480_000)

    private func temporaryStore() throws -> DreamStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dream-retraction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DreamStore(root: root)
    }

    private func provenance(_ day: String, revision: UInt64 = 0) -> DreamEvidenceProvenance {
        .init(sources: [.init(kind: .meeting, id: "synthetic-\(day)", dayKey: day)], revision: revision)
    }

    private func memory(_ day: String, name: String = "Revoked", revision: UInt64 = 0) -> DreamMemory {
        let source = provenance(day, revision: revision)
        return DreamMemory(
            updatedAt: now, lastDreamDay: otherDay,
            activeProjects: [.init(name: name, status: "status from evidence", lastActiveDay: otherDay,
                                  pinned: true, provenance: source)],
            workGoals: [.init(text: name, horizon: "this month", lastReinforcedDay: otherDay,
                             pinned: true, provenance: source)],
            recurringPatterns: [name], patternProvenance: [name: source])
    }

    func testDeletingSourceRetractsPinnedMemoryAndItsLaterReportButKeepsUnrelatedPins() throws {
        let store = try temporaryStore()
        var combined = memory(day)
        let unrelated = memory(otherDay, name: "Keep")
        combined.activeProjects += unrelated.activeProjects
        combined.workGoals += unrelated.workGoals
        combined.recurringPatterns += unrelated.recurringPatterns
        combined.patternProvenance.merge(unrelated.patternProvenance) { _, new in new }
        let later = DreamReport(day: "2026-09-20", generatedAt: now, engineName: "test",
                                evidenceProvenance: provenance(day), narrative: "Revoked")
        try store.save(report: later, memory: combined)

        let invalidated = try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [day], at: now)

        let remaining = try XCTUnwrap(store.loadMemory())
        XCTAssertEqual(remaining.activeProjects.map(\.name), ["Keep"])
        XCTAssertEqual(remaining.workGoals.map(\.text), ["Keep"])
        XCTAssertEqual(remaining.recurringPatterns, ["Keep"])
        XCTAssertTrue(remaining.activeProjects[0].pinned)
        XCTAssertTrue(remaining.workGoals[0].pinned)
        XCTAssertTrue(invalidated.contains(later.day), "Inherited memory can outlive the comparison window")
        XCTAssertNil(store.report(forDayKey: later.day))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.reportJSONURL(forDayKey: later.day).path))
        let markdown = try String(contentsOf: store.memoryDirectory.appendingPathComponent("memory.md"), encoding: .utf8)
        XCTAssertFalse(markdown.contains("Revoked"))
        XCTAssertTrue(markdown.contains("Keep"))
    }

    func testCorrectedSourceCanProduceFreshMemoryWithoutRestoringItsOldValue() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        let revision = try store.evidenceRevision()
        let fresh = memory(day, name: "Corrected", revision: revision)
        let report = DreamReport(day: otherDay, generatedAt: now, engineName: "test",
                                 evidenceProvenance: provenance(day, revision: revision), narrative: "Corrected")
        try store.saveGenerated(report: report, memory: fresh, basedOnRevision: revision)
        XCTAssertEqual(try store.loadMemory()?.activeProjects.map(\.name), ["Corrected"])

        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty, "A second correction revokes the replacement too")
    }

    func testMeetingIdentityRetractsEvidenceAfterCalendarDayChanges() throws {
        let store = try temporaryStore()
        let id = UUID()
        var original = memory(day)
        original.activeProjects[0].provenance?.sources = [.init(kind: .meeting, id: id.uuidString, dayKey: day)]
        try store.save(original)
        // A different time zone can put the same meeting on another local day.
        // Full UUID provenance must still match even if day keys no longer do.
        try store.invalidateEvidence(affectedDayKeys: ["2026-08-04"], affectedMeetingIDs: [id], reportDayKeys: [])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).activeProjects.isEmpty)
    }

    func testPersistedRevisionRejectsUncancelledGenerationFromBeforeDeletion() throws {
        let store = try temporaryStore()
        let revision = try store.evidenceRevision()
        let staleMemory = memory(day)
        let staleReport = DreamReport(day: otherDay, generatedAt: now, engineName: "test",
                                      evidenceProvenance: provenance(day), narrative: "Revoked")
        try store.save(staleMemory)
        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        // A new instance models a separate generation completion which did not
        // observe scheduler cancellation, including one resumed after restart.
        let reopened = DreamStore(root: store.root)
        XCTAssertThrowsError(try reopened.saveGenerated(report: staleReport, memory: staleMemory,
                                                       basedOnRevision: revision)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(try XCTUnwrap(reopened.loadMemory()).isEmpty)
        XCTAssertFalse(reopened.hasReport(forDayKey: otherDay))
    }

    func testLegacyPinsAndPatternsRemainReadableUntilMutationThenRetractConservatively() throws {
        let store = try temporaryStore()
        try FileManager.default.createDirectory(at: store.memoryDirectory, withIntermediateDirectories: true)
        let legacy = Data("""
        {"version":1,"updatedAt":"2026-08-07T04:00:00Z","lastDreamDay":"2026-08-06",
         "activeProjects":[{"name":"Legacy","status":"old","lastActiveDay":"2026-08-06","pinned":true}],
         "workGoals":[{"text":"Legacy","horizon":"soon","lastReinforcedDay":"2026-08-06","pinned":true}],
         "recurringPatterns":["Legacy"]}
        """.utf8)
        try legacy.write(to: store.memoryDirectory.appendingPathComponent("memory.json"))
        XCTAssertEqual(try store.loadMemory()?.activeProjects.first?.pinned, true)
        XCTAssertNil(try store.loadMemory()?.activeProjects.first?.provenance)

        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
        XCTAssertEqual(try store.loadMemory()?.version, DreamMemory.currentVersion)
    }

    func testRephrasedMemoryInheritsSourceDependenciesAndLegacyUncertainty() throws {
        let original = memory(day)
        let dependencies = original.provenance(adding: provenance(otherDay).sources, revision: 0)
        let update = DreamMemoryUpdate(activeProjects: [.init(name: "New inference", status: "derived", evidence: [])],
                                       recurringPatterns: ["A new pattern"])
        let merged = original.merging(update, dreamDay: otherDay, at: now, provenance: dependencies)
        let retracted = merged.retractingEvidence(invalidations: [day: 1], revision: 1)
        XCTAssertTrue(retracted.isEmpty, "Rewording must not launder revoked evidence into a different item")

        var legacy = original
        legacy.activeProjects[0].provenance = nil
        let inheritedLegacy = legacy.provenance(adding: provenance(otherDay).sources, revision: 3)
        XCTAssertTrue(inheritedLegacy.includesUnattributedContext)
        XCTAssertTrue(inheritedLegacy.isInvalidated(by: ["unrelated": 4], currentRevision: 4))
    }

    func testMemoryAndReportReadsFailClosedAfterInterruptedRetraction() throws {
        let store = try temporaryStore()
        let originalMemory = memory(day)
        let originalReport = DreamReport(day: otherDay, generatedAt: now, engineName: "test",
                                         evidenceProvenance: provenance(day), narrative: "Revoked")
        try store.save(report: originalReport, memory: originalMemory)
        let memoryURL = store.memoryDirectory.appendingPathComponent("memory.json")
        let reportURL = store.reportJSONURL(forDayKey: otherDay)
        let oldMemoryBytes = try Data(contentsOf: memoryURL)
        let oldReportBytes = try Data(contentsOf: reportURL)
        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        // Recreate the on-disk state after revision persistence but before
        // cleanup, without relying on permission failures when tests run root.
        try oldMemoryBytes.write(to: memoryURL)
        try oldReportBytes.write(to: reportURL)
        XCTAssertTrue(try XCTUnwrap(DreamStore(root: store.root).loadMemory()).isEmpty)
        XCTAssertNil(DreamStore(root: store.root).report(forDayKey: otherDay))
    }

    func testFailedRevocationBlocksAllStoreInstancesUntilSuccessfulRetry() throws {
        let store = try temporaryStore()
        let oldMemory = memory(day)
        let oldReport = DreamReport(day: otherDay, generatedAt: now, engineName: "test",
                                    evidenceProvenance: provenance(day), narrative: "Revoked")
        try store.save(report: oldReport, memory: oldMemory)
        let stateURL = store.memoryDirectory.appendingPathComponent("evidence-revisions.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: []))
        let anotherStore = DreamStore(root: store.root)
        XCTAssertNil(try anotherStore.loadMemory())
        XCTAssertNil(anotherStore.report(forDayKey: otherDay))
        XCTAssertThrowsError(try anotherStore.evidenceRevision())
        XCTAssertThrowsError(try anotherStore.saveGenerated(report: oldReport, memory: oldMemory, basedOnRevision: 0))

        try FileManager.default.removeItem(at: stateURL)
        try anotherStore.invalidateEvidence(affectedDayKeys: [otherDay], reportDayKeys: [])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
        XCTAssertEqual(try store.evidenceRevision(), 1)
    }

    func testDurableIntentBlocksAStoreWithNoInMemoryFailureState() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        let stateURL = store.memoryDirectory.appendingPathComponent("evidence-revisions.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: []))

        // Copy the actual persisted files to an unseen root. No static block
        // exists for that root, reproducing a reader in a fresh process.
        let restored = try temporaryStore()
        try FileManager.default.copyItem(at: store.memoryDirectory, to: restored.memoryDirectory)
        let intentName = ".dream-revocation-pending.json"
        try FileManager.default.copyItem(at: store.root.appendingPathComponent(intentName),
                                        to: restored.root.appendingPathComponent(intentName))
        // The failing journal is gone on restart, but its absence must not
        // restore the unchanged old memory file.
        try FileManager.default.removeItem(at: restored.memoryDirectory.appendingPathComponent("evidence-revisions.json"))
        XCTAssertNil(try restored.loadMemory())
        XCTAssertEqual(try restored.evidenceRevision(), 1, "A ready intent can retry cleanup after storage recovers")
        XCTAssertTrue(try XCTUnwrap(restored.loadMemory()).isEmpty)
    }

    func testPreparedIntentCannotBeConsumedBeforeSourceMutationFinishes() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        try store.prepareEvidenceInvalidation(affectedDayKeys: [day])
        let anotherStore = DreamStore(root: store.root)
        XCTAssertNil(try anotherStore.loadMemory())
        XCTAssertThrowsError(try anotherStore.evidenceRevision())
        try anotherStore.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
    }

    func testCompletingOnePreparedMutationDoesNotReopenAnother() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        try store.prepareEvidenceInvalidation(affectedDayKeys: [day])
        try store.prepareEvidenceInvalidation(affectedDayKeys: [otherDay])
        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [])
        XCTAssertNil(try store.loadMemory())
        XCTAssertThrowsError(try store.evidenceRevision())
        try store.invalidateEvidence(affectedDayKeys: [otherDay], reportDayKeys: [])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
    }

    func testPreflightFailureNeverRunsTheSourceMutation() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent(".dream-revocation-pending.json"),
                                                withIntermediateDirectories: true)
        var mutated = false
        XCTAssertThrowsError(try store.withEvidenceMutation(affectedDayKeys: [day]) { mutated = true })
        XCTAssertFalse(mutated)
    }

    func testRevisionJournalFailurePreventsTheSourceMutation() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        let source = store.root.appendingPathComponent("synthetic-source")
        try Data("original".utf8).write(to: source)
        // Intent creation still succeeds, but the subsequent revision journal
        // cannot be decoded or replaced. The source must remain unchanged.
        try FileManager.default.createDirectory(
            at: store.memoryDirectory.appendingPathComponent("evidence-revisions.json"),
            withIntermediateDirectories: true)
        var mutated = false
        XCTAssertThrowsError(try store.withEvidenceMutation(affectedDayKeys: [day]) {
            mutated = true
            try FileManager.default.removeItem(at: source)
        })
        XCTAssertFalse(mutated)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }

    func testSuccessfulSourceMutationIsNotFailedBySubsequentDreamStorageErrors() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        let source = store.root.appendingPathComponent("synthetic-source")
        let result = try store.withEvidenceMutation(affectedDayKeys: [day]) {
            try Data("saved".utf8).write(to: source)
            // Simulate Dream storage becoming unavailable after source success.
            // A directory at the journal path fails even on privileged runners.
            let journal = store.memoryDirectory.appendingPathComponent("evidence-revisions.json")
            if FileManager.default.fileExists(atPath: journal.path) {
                try FileManager.default.removeItem(at: journal)
            }
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
            return "source saved"
        }
        XCTAssertEqual(result, "source saved")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "saved")
    }

    func testNestedSourceMutationsKeepRetractionAndPersistenceConsistent() throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        var writes: [String] = []
        try store.withEvidenceMutation(affectedDayKeys: [day]) {
            writes.append("outer start")
            try store.withEvidenceMutation(affectedDayKeys: [day]) { writes.append("inner write") }
            writes.append("outer finish")
        }
        XCTAssertEqual(writes, ["outer start", "inner write", "outer finish"])
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
        XCTAssertNoThrow(try store.evidenceRevision())
    }

    func testSourceWriteFailureStillRetractsPossiblyChangedEvidence() throws {
        enum FixtureError: Error { case partialWrite }
        let store = try temporaryStore()
        try store.save(memory(day))
        XCTAssertThrowsError(try store.withEvidenceMutation(affectedDayKeys: [day]) {
            try Data("partially corrected".utf8).write(to: store.root.appendingPathComponent("synthetic-source"))
            throw FixtureError.partialWrite
        })
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
        XCTAssertNoThrow(try store.evidenceRevision())
    }

    func testUnchangedEntriesKeepTheirOwnProvenanceAndPins() throws {
        let original = memory(day)
        let update = DreamMemoryUpdate(
            activeProjects: [.init(name: "Revoked", status: "status from evidence", evidence: [])],
            workGoals: [.init(text: "Revoked", horizon: "changed without reinforcement", reinforcedToday: false)],
            recurringPatterns: ["Revoked"])
        let merged = original.merging(update, dreamDay: otherDay, at: now, provenance: provenance(otherDay))
        XCTAssertEqual(merged.activeProjects, original.activeProjects)
        XCTAssertEqual(merged.workGoals, original.workGoals)
        XCTAssertEqual(merged.patternProvenance, original.patternProvenance)
    }

    func testEmptyRegenerationCannotBringBackDeletedDurableMemory() async throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        try store.invalidateEvidence(affectedDayKeys: [day], reportDayKeys: [day])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let target = DreamScheduler.target(for: try XCTUnwrap(DreamDay.date(fromKey: day, calendar: calendar)),
                                           calendar: calendar)
        let service = DreamService(storageRoot: store.root, makeEngine: {
            XCTFail("An empty regenerated day must not run a model")
            throw CancellationError()
        })
        let report = try await service.dream(target: target)
        XCTAssertEqual(report.fallbackReason, .emptyDay)
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
        XCTAssertEqual(try store.loadMemory()?.lastDreamDay, otherDay, "Historical repair preserves the watermark")
    }

    func testSourceCorrectionDuringModelGenerationCannotCommitItsReply() async throws {
        let store = try temporaryStore()
        try store.save(memory(day))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let target = DreamScheduler.target(for: try XCTUnwrap(DreamDay.date(fromKey: otherDay, calendar: calendar)),
                                           calendar: calendar)
        var evidence = try DreamCompiler.compile(day: target.day, storageRoot: store.root, calendar: calendar)
        evidence.digest = "Synthetic source before correction"
        evidence.sources += provenance(day).sources
        let capturedEvidence = evidence
        let engine = RetractionEngine {
            // Deliberately return a successful model reply after the mutation,
            // without cancelling this task. The store must still reject it.
            try store.invalidateEvidence(affectedDayKeys: [self.day], reportDayKeys: [])
        }
        let service = DreamService(storageRoot: store.root,
                                   makeEngine: { (engine, .init(location: .local)) },
                                   compileEvidence: { _, _ in capturedEvidence })
        do {
            _ = try await service.dream(target: target)
            XCTFail("A stale synthesis was committed")
        } catch is CancellationError {
            // Expected: the persisted source revision changed during generation.
        }
        XCTAssertTrue(try XCTUnwrap(store.loadMemory()).isEmpty)
        XCTAssertFalse(store.hasReport(forDayKey: otherDay))
    }
}

private struct RetractionEngine: TextEngine {
    var displayName: String { "Synthetic retraction test" }
    var onGenerate: () throws -> Void

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        try onGenerate()
        return """
        {"narrative":"Revoked reply","attention":[],"repeated_work":[],"suggested_checks":[],
         "frictions":[],"top_actions":[],"active_projects":[{"name":"Revoked","status":"old","evidence":[]}],
         "work_goals":[{"text":"Revoked","horizon":"soon","reinforced_today":true,"expired":false}],
         "recurring_patterns":["Revoked"]}
        """
    }
}
