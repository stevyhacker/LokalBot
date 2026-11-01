import Foundation

/// Where built records go: the sync host while sharing is on, an in-memory
/// store in tests. Calls block and are made from the publisher's queue.
/// Publishing an unchanged body is a no-op on the host.
protocol CompanionRecordSink: AnyObject {
    @discardableResult func publish(kind: String, key: String, bodyJSON: String) throws -> Bool
    @discardableResult func remove(kind: String, key: String) throws -> Bool
    func recordKeys(kind: String) throws -> [String]
    func setManifest(bodyJSON: String) throws
}

/// Keeps the host's records equal to what the library shares. A full
/// reconcile builds every record, publishes it, and withdraws keys that no
/// longer exist (deleted, merged, out of the history window, or a class
/// turned off). Change hooks queue narrower rebuilds, coalesced on a serial
/// queue, so a burst of edits costs one pass.
final class CompanionPublisher: @unchecked Sendable {
    struct Context: Equatable, Sendable {
        var root: URL
        var activityDatabaseURL: URL
        var sharing: CompanionSharing
        var macName: String
        var libraryName = "LokalBot"
    }

    /// What one pass changed, for logs and tests.
    struct Report: Equatable, Sendable {
        var published = 0
        var changed = 0
        var removed = 0
        var failed = 0
    }

    private struct Pending {
        var full = false
        var meetingIDs: Set<UUID> = []
        var dayKeys: Set<String> = []
        var connections = false

        var isEmpty: Bool { !full && meetingIDs.isEmpty && dayKeys.isEmpty && !connections }
    }

    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.companion-publisher", qos: .utility)
    private let sink: CompanionRecordSink
    private let calendar: Calendar
    private let debounce: DispatchTimeInterval
    private let clock: () -> Date

    // Queue-owned state.
    private var context: Context
    private var pending = Pending()
    private var scheduled = false
    private var projectionCache: [UUID: MeetingOutcomeProjection] = [:]
    private var library: CompanionLibrary?

    init(sink: CompanionRecordSink, context: Context, calendar: Calendar = .current,
         debounce: DispatchTimeInterval = .seconds(2), clock: @escaping () -> Date = Date.init) {
        self.sink = sink
        self.context = context
        self.calendar = calendar
        self.debounce = debounce
        self.clock = clock
    }

    // MARK: - Requests

    /// Replace the settings the records depend on. A different record scope
    /// rebuilds everything; the manifest is always refreshed.
    func update(context next: Context) {
        queue.async { [self] in
            let rebuild = next.sharing.recordScope != context.sharing.recordScope || next.root != context.root
            context = next
            if rebuild {
                library = nil
                projectionCache = [:]
                enqueue { $0.full = true }
            } else {
                publishManifest()
            }
        }
    }

    func reconcileAll() {
        queue.async { [self] in enqueue { $0.full = true } }
    }

    /// Meeting evidence changed: outcomes, notes, processing, deletion or a
    /// merge. `days` names the days the meetings were on, which still matters
    /// for a meeting that no longer exists.
    func meetingsChanged(_ ids: Set<UUID>, days: [Date] = []) {
        let keys = Set(days.map { CompanionJSON.day($0, calendar: calendar) })
        queue.async { [self] in
            enqueue {
                $0.meetingIDs.formUnion(ids)
                $0.dayKeys.formUnion(keys)
                $0.connections = true
            }
        }
    }

    func daysChanged(_ days: [Date]) {
        let keys = Set(days.map { CompanionJSON.day($0, calendar: calendar) })
        guard !keys.isEmpty else { return }
        queue.async { [self] in enqueue { $0.dayKeys.formUnion(keys) } }
    }

    /// People or project curation, or a project's "Where it stands" note.
    func connectionsChanged() {
        queue.async { [self] in enqueue { $0.connections = true } }
    }

    /// Today's Timeline grows while the person works; rebuild today's record
    /// when anything was recorded within `window`.
    func refreshTodayIfActive(window: TimeInterval = 15 * 60) {
        queue.async { [self] in
            let now = clock()
            let latest = ActivityStore(databaseURL: context.activityDatabaseURL, readOnly: true).latestActivityEnd()
            guard let latest, now.timeIntervalSince(latest) <= window else { return }
            let key = CompanionJSON.day(now, calendar: calendar)
            enqueue { $0.dayKeys.insert(key) }
        }
    }

    /// Rebuild one meeting and what depends on it before returning, for ops
    /// the device waits on. Returns false when the pass did not finish in time.
    @discardableResult
    func republishNow(meetingID: UUID, timeout: TimeInterval = 30) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            pending.meetingIDs.insert(meetingID)
            pending.connections = true
            _ = drain()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Run whatever is queued now and wait for it, for tests and shutdown.
    @discardableResult
    func flush() -> Report {
        queue.sync { drain() }
    }

    // MARK: - Passes (queue only)

    private func enqueue(_ change: (inout Pending) -> Void) {
        change(&pending)
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + debounce) { [self] in
            scheduled = false
            _ = drain()
        }
    }

    private func drain() -> Report {
        let work = pending
        pending = Pending()
        guard !work.isEmpty else { return Report() }
        let started = Date()
        let report = work.full ? reconcile() : apply(work)
        lokalbotLog(String(
            format: "companion publish %@: %d built, %d changed, %d withdrawn, %d failed in %.2fs",
            work.full ? "full" : "incremental", report.published, report.changed, report.removed,
            report.failed, Date().timeIntervalSince(started)))
        return report
    }

    private func reconcile() -> Report {
        let now = clock()
        let loaded = CompanionLibrary.load(
            root: context.root, activityDatabaseURL: context.activityDatabaseURL,
            scope: context.sharing.recordScope, now: now, calendar: calendar)
        library = loaded
        projectionCache = loaded.projections
        let activity = ActivityStore(databaseURL: context.activityDatabaseURL, readOnly: true)
        let builder = CompanionRecordBuilder(library: loaded, activity: activity)
        var report = Report()
        let records = builder.allRecords()
        publish(records, into: &report)
        for kind in CompanionRecordKind.reconciled {
            let wanted = Set(records.filter { $0.kind == kind }.map(\.key))
            withdraw(kind: kind, keeping: wanted, into: &report)
        }
        publishManifest()
        return report
    }

    private func apply(_ work: Pending) -> Report {
        let now = clock()
        guard var current = library else { return reconcile() }
        // The meeting list is cheap to read again; outcomes are reloaded only
        // for the meetings that changed.
        for id in work.meetingIDs { projectionCache[id] = nil }
        current = CompanionLibrary.reloading(
            current, now: now, cachedProjections: projectionCache,
            recomputeConnections: work.connections || !work.meetingIDs.isEmpty)
        library = current
        projectionCache = current.projections
        let activity = ActivityStore(databaseURL: context.activityDatabaseURL, readOnly: true)
        let builder = CompanionRecordBuilder(library: current, activity: activity)
        var report = Report()
        var dayKeys = work.dayKeys
        let byID = Dictionary(current.allMeetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in work.meetingIDs {
            let key = CompanionJSON.id(id)
            let records = byID[id].map(builder.meetingRecords(for:)) ?? []
            publish(records, into: &report)
            for kind in [CompanionRecordKind.meeting, .transcript] where !records.contains(where: { $0.kind == kind }) {
                remove(kind: kind, key: key, into: &report)
            }
            if let meeting = byID[id] { dayKeys.insert(CompanionJSON.day(meeting.startedAt, calendar: calendar)) }
        }
        for key in dayKeys {
            if let record = builder.dayRecord(forKey: key) {
                publish([record], into: &report)
            } else {
                remove(kind: .day, key: key, into: &report)
            }
        }
        if work.connections || !work.meetingIDs.isEmpty {
            let people = builder.personRecords()
            let projects = builder.projectRecords()
            publish(people + projects, into: &report)
            withdraw(kind: .person, keeping: Set(people.map(\.key)), into: &report)
            withdraw(kind: .project, keeping: Set(projects.map(\.key)), into: &report)
        }
        return report
    }

    private func publishManifest() {
        guard let body = CompanionRecordBuilder.manifest(
            sharing: context.sharing, macName: context.macName,
            libraryName: context.libraryName, now: clock()) else { return }
        do {
            try sink.setManifest(bodyJSON: body)
        } catch {
            lokalbotLog("companion manifest publish failed: \(error.localizedDescription)")
        }
    }

    private func publish(_ records: [CompanionRecord], into report: inout Report) {
        for record in records {
            report.published += 1
            do {
                if try sink.publish(kind: record.kind.rawValue, key: record.key, bodyJSON: record.bodyJSON) {
                    report.changed += 1
                }
            } catch {
                report.failed += 1
                lokalbotLog("companion publish failed kind=\(record.kind.rawValue): \(error.localizedDescription)")
            }
        }
    }

    private func remove(kind: CompanionRecordKind, key: String, into report: inout Report) {
        do {
            if try sink.remove(kind: kind.rawValue, key: key) { report.removed += 1 }
        } catch {
            report.failed += 1
            lokalbotLog("companion withdraw failed kind=\(kind.rawValue): \(error.localizedDescription)")
        }
    }

    private func withdraw(kind: CompanionRecordKind, keeping wanted: Set<String>, into report: inout Report) {
        let existing: [String]
        do {
            existing = try sink.recordKeys(kind: kind.rawValue)
        } catch {
            report.failed += 1
            lokalbotLog("companion key listing failed kind=\(kind.rawValue): \(error.localizedDescription)")
            return
        }
        for key in existing where !wanted.contains(key) {
            remove(kind: kind, key: key, into: &report)
        }
    }
}

extension CompanionLibrary {
    /// The library again after a change: meetings re-read, outcomes reused
    /// from `cachedProjections` where present, people and projects rebuilt
    /// only when asked.
    static func reloading(
        _ previous: CompanionLibrary, now: Date,
        cachedProjections: [UUID: MeetingOutcomeProjection],
        recomputeConnections: Bool
    ) -> CompanionLibrary {
        let all = (try? SessionLookup.loadAllMeetings(root: previous.root, includeMergedSources: true)) ?? []
        let scope = previous.scope
        let shared = all.filter { isShared($0, history: scope.history, now: now, calendar: previous.calendar) }
        let classes = scope.dataClasses
        var projections: [UUID: MeetingOutcomeProjection] = [:]
        if classes.meetings || classes.people || classes.projects {
            for meeting in shared {
                if let cached = cachedProjections[meeting.id], cached.meeting == meeting {
                    projections[meeting.id] = cached
                } else if let projection = MeetingOutcomeProjection.load(for: meeting, root: previous.root) {
                    projections[meeting.id] = projection
                }
            }
        }
        guard recomputeConnections else {
            return CompanionLibrary(
                root: previous.root, activityDatabaseURL: previous.activityDatabaseURL, scope: scope,
                now: now, calendar: previous.calendar, allMeetings: all, meetings: shared,
                projections: projections, people: previous.people, projects: previous.projects,
                projectSummaries: previous.projectSummaries)
        }
        let rebuilt = load(root: previous.root, activityDatabaseURL: previous.activityDatabaseURL,
                           scope: scope, now: now, calendar: previous.calendar,
                           meetings: all, projections: projections)
        return rebuilt
    }
}
