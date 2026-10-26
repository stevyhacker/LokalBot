import Foundation

/// One sync pass for one Gmail account.
///
/// - **First pass, or after Gmail expires the history:** search the window
///   (threads you wrote in, plus threads with calendar people), keep what
///   qualifies, and drop stored threads that no longer do.
/// - **Later passes:** read Gmail's change history since the saved cursor
///   and recheck only the threads it names, then search once for any person
///   who joined the calendar since the last pass.
///
/// The cursor is saved only after the threads it covers are stored, so an
/// interrupted pass repeats work instead of skipping it, and repeating it
/// rewrites the same files. A thread Gmail fails to return is left as it
/// was and checked again on the next pass, rather than holding back every
/// other one; a lost connection or an expired sign-in ends the pass.
struct GmailSyncer: Sendable {
    /// Parallel thread fetches. Gmail allows about 25 thread reads a second
    /// per user; four in flight stays well under it.
    static let concurrency = 4

    let client: GmailClient
    let store: EmailStore
    let now: Date
    /// Threads one search may return; a scan that reaches it says so.
    var threadLimit = EmailScope.maxThreadsPerScan

    func sync(_ account: EmailAccount, attendees: Set<String>) async throws -> EmailAccount {
        var account = account
        let windowStart = EmailScope.windowStart(now: now)
        // People stay known for the window after they were last on the
        // calendar, so a calendar that is briefly unreadable changes nothing.
        var people = account.sync.people.filter { $0.value >= windowStart }
        for address in EmailScope.knownPeople(attendees, excluding: account.ownedAddresses) {
            people[address] = now
        }
        account.sync.people = people
        let everyone = Set(people.keys)
        account.sync.searchedAddresses.formIntersection(everyone)

        if let historyID = account.sync.historyID {
            do {
                let changes = try await client.changes(since: historyID)
                let changed = changes.threadIDs.union(account.sync.retryThreadIDs)
                var failed = try await recheck(changed, accountID: account.id, people: everyone,
                                               windowStart: windowStart)
                let unsearched = everyone.subtracting(account.sync.searchedAddresses)
                if !unsearched.isEmpty {
                    let found = try await search(EmailScope.participantSearches(addresses: unsearched, after: windowStart),
                                                 limit: threadLimit)
                    failed.formUnion(try await recheck(Set(found.ids).subtracting(changed), accountID: account.id,
                                                       people: everyone, windowStart: windowStart))
                    account.sync.searchedAddresses.formUnion(found.completed)
                    account.sync.capped = found.cut
                }
                if !failed.isEmpty { lokalbotLog("email sync deferred threads=\(failed.count)") }
                account.sync.retryThreadIDs = Self.retries(failed)
                account.sync.historyID = changes.historyID
            } catch GmailError.historyExpired {
                lokalbotLog("email gmail history expired; rescanning the window")
                account = try await fullScan(account, people: everyone, windowStart: windowStart)
            }
        } else {
            account = try await fullScan(account, people: everyone, windowStart: windowStart)
        }
        let counts = try prune(account.id, people: everyone, windowStart: windowStart)
        account.sync.threadCount = counts.threads
        account.sync.messageCount = counts.messages
        return account
    }

    // MARK: Passes

    private func fullScan(_ account: EmailAccount, people: Set<String>,
                          windowStart: Date) async throws -> EmailAccount {
        var account = account
        // The cursor is read before searching, so mail that arrives during
        // the scan is replayed by the next pass rather than missed.
        let profile = try await client.profile()
        let aliases = (try? await client.sendAsAddresses()) ?? []
        let address = profile.emailAddress.lowercased()
        account.address = address
        account.aliases = Array(Set(aliases).subtracting([address])).sorted()

        let limit = threadLimit
        let sent = try await client.threadIDs(query: EmailScope.sentQuery(after: windowStart), limit: limit)
        var candidates = sent
        var cut = sent.count >= limit
        var searched: Set<String> = []
        if !cut {
            let found = try await search(EmailScope.participantSearches(addresses: people, after: windowStart),
                                         limit: limit - candidates.count)
            var seen = Set(sent)
            for id in found.ids where seen.insert(id).inserted {
                candidates.append(id)
            }
            searched = found.completed
            cut = found.cut
        }
        let result = try await fetch(candidates, sentIDs: Set(sent), accountID: account.id, people: people,
                                     windowStart: windowStart)
        // A full scan is the whole truth for the window, except for threads
        // it couldn't read this time.
        for id in store.threadIDs(accountID: account.id).subtracting(result.kept).subtracting(result.failed) {
            try store.deleteThread(accountID: account.id, threadID: id)
        }
        if !result.failed.isEmpty { lokalbotLog("email sync deferred threads=\(result.failed.count)") }
        account.sync.retryThreadIDs = Self.retries(result.failed)
        account.sync.capped = cut
        account.sync.historyID = profile.historyId
        account.sync.searchedAddresses = searched
        return account
    }

    /// Rechecks threads Gmail says changed: store the ones that still
    /// qualify, remove the ones that no longer do (trashed, deleted, spam).
    /// Returns the ids that couldn't be read and were left as they were.
    @discardableResult
    private func recheck(_ threadIDs: Set<String>, accountID: UUID, people: Set<String>,
                         windowStart: Date) async throws -> Set<String> {
        guard !threadIDs.isEmpty else { return [] }
        let ids = threadIDs.sorted()
        let result = try await fetch(ids, sentIDs: [], accountID: accountID, people: people, windowStart: windowStart)
        for id in ids where !result.kept.contains(id) && !result.failed.contains(id) {
            try store.deleteThread(accountID: accountID, threadID: id)
        }
        return result.failed
    }

    private struct Found {
        var ids: [String] = []
        /// People whose search ran to the end.
        var completed: Set<String> = []
        /// The thread limit stopped the searches early.
        var cut = false
    }

    private func search(_ searches: [EmailScope.ParticipantSearch], limit: Int) async throws -> Found {
        var found = Found()
        var seen: Set<String> = []
        for search in searches {
            guard found.ids.count < limit else {
                found.cut = true
                break
            }
            let ids = try await client.threadIDs(query: search.query, limit: limit - found.ids.count)
            for id in ids where seen.insert(id).inserted {
                found.ids.append(id)
            }
            // A full page may have stopped at the limit with more to come.
            if found.ids.count >= limit {
                found.cut = true
                break
            }
            found.completed.formUnion(search.addresses)
        }
        return found
    }

    private struct Fetched {
        var kept: Set<String> = []
        var failed: Set<String> = []
    }

    /// Fetches candidates a few at a time and stores the ones that qualify.
    /// Threads you wrote in skip the headers-only check.
    private func fetch(_ ids: [String], sentIDs: Set<String>, accountID: UUID, people: Set<String>,
                       windowStart: Date) async throws -> Fetched {
        var fetched = Fetched()
        var lastFailure: Error?
        var next = 0
        try await withThrowingTaskGroup(of: (String, Result<EmailThread?, Error>).self) { group in
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                let wroteIn = sentIDs.contains(id)
                group.addTask {
                    do {
                        return (id, .success(try await self.qualifyingThread(
                            id, wroteIn: wroteIn, accountID: accountID, people: people, windowStart: windowStart)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let (id, result) = try await group.next() {
                switch result {
                case .success(let thread?):
                    try store.saveThread(thread)
                    fetched.kept.insert(id)
                case .success(nil):
                    break
                case .failure(let error):
                    guard Self.isThreadSpecific(error) else {
                        group.cancelAll()
                        throw error
                    }
                    fetched.failed.insert(id)
                    lastFailure = error
                }
                addNext()
            }
        }
        // Many failures at once mean Gmail is having trouble, not a few odd
        // threads: end the pass so the cursor stays and it runs again later.
        if let lastFailure, fetched.failed.count > max(Self.skippableFailures, ids.count / 10) {
            throw lastFailure
        }
        return fetched
    }

    /// Threads one pass may skip before it gives up.
    static let skippableFailures = 3
    /// Threads kept for the next pass to retry; the rest wait for a change.
    static let maxRetries = 200

    static func retries(_ failed: Set<String>) -> Set<String> {
        Set(failed.sorted().prefix(maxRetries))
    }

    /// Errors that concern one thread only. Anything else (sign-in,
    /// connection, rate limits that outlasted the retries, cancellation)
    /// stops the pass.
    static func isThreadSpecific(_ error: Error) -> Bool {
        switch error as? GmailError {
        case .unexpectedResponse?:
            return true
        case .requestFailed(let status, _)?:
            return ![401, 403, 429].contains(status)
        default:
            return false
        }
    }

    private func qualifyingThread(_ id: String, wroteIn: Bool, accountID: UUID, people: Set<String>,
                                  windowStart: Date) async throws -> EmailThread? {
        if !wroteIn {
            guard let metadata = try await client.thread(id: id, format: .metadata),
                  EmailScope.qualifies(metadata, people: people, windowStart: windowStart) else {
                return nil
            }
        }
        guard let full = try await client.thread(id: id, format: .full),
              EmailScope.qualifies(full, people: people, windowStart: windowStart) else {
            return nil
        }
        return EmailScope.thread(from: full, accountID: accountID, windowStart: windowStart)
    }

    /// Drops messages that aged out of the window, then threads whose
    /// remaining messages no longer qualify on their own (the reply that
    /// qualified them aged out). Returns what remains.
    private func prune(_ accountID: UUID, people: Set<String>,
                       windowStart: Date) throws -> (threads: Int, messages: Int) {
        var threads = 0
        var messages = 0
        for var thread in store.threads(accountID: accountID) {
            let kept = thread.messages.filter { $0.date >= windowStart }
            if kept.count != thread.messages.count {
                thread.messages = kept
                guard !kept.isEmpty, EmailScope.stillQualifies(thread, people: people) else {
                    try store.deleteThread(accountID: accountID, threadID: thread.id)
                    continue
                }
                try store.saveThread(thread)
            }
            threads += 1
            messages += kept.count
        }
        return (threads, messages)
    }
}
