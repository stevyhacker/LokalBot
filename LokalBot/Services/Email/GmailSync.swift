import Foundation

struct GmailSyncer: Sendable {
    static let concurrency = 4

    let client: GmailClient
    let store: EmailStore
    let now: Date
    var threadLimit = EmailScope.maxThreadsPerScan

    func sync(_ account: EmailAccount, attendees: Set<String>) async throws -> EmailAccount {
        var account = account
        let windowStart = EmailScope.windowStart(now: now)
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
                lokalbotLog("email history changed=\(changes.threadIDs.count) retried=\(account.sync.retryThreadIDs.count) "
                            + "newPeople=\(unsearched.count) people=\(everyone.count)")
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

    private func fullScan(_ account: EmailAccount, people: Set<String>,
                          windowStart: Date) async throws -> EmailAccount {
        var account = account
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
        for id in store.threadIDs(accountID: account.id).subtracting(result.kept).subtracting(result.failed) {
            try store.deleteThread(accountID: account.id, threadID: id)
        }
        if !result.failed.isEmpty { lokalbotLog("email sync deferred threads=\(result.failed.count)") }
        lokalbotLog("email scan sent=\(sent.count) withPeople=\(candidates.count - sent.count) "
                    + "kept=\(result.kept.count) people=\(people.count) searched=\(searched.count) cut=\(cut)")
        account.sync.retryThreadIDs = Self.retries(result.failed)
        account.sync.capped = cut
        account.sync.historyID = profile.historyId
        account.sync.searchedAddresses = searched
        return account
    }

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
        var completed: Set<String> = []
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
        if let lastFailure, fetched.failed.count > max(Self.skippableFailures, ids.count / 10) {
            throw lastFailure
        }
        return fetched
    }

    static let skippableFailures = 3
    static let maxRetries = 200

    static func retries(_ failed: Set<String>) -> Set<String> {
        Set(failed.sorted().prefix(maxRetries))
    }

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
