import Foundation

final class CotypingFieldContextCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var value: Value
        var capturedAt: TimeInterval
        var refreshing = false
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private let maxAge: TimeInterval
    private let maxEntries: Int
    private let refreshQueue: DispatchQueue
    private let clock: @Sendable () -> TimeInterval

    init(
        label: String,
        maxAge: TimeInterval,
        maxEntries: Int = 32,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maxAge = maxAge
        self.maxEntries = maxEntries
        self.clock = clock
        refreshQueue = DispatchQueue(label: "me.dotenv.LokalBot.cotyping.\(label)", qos: .utility)
    }

    func value(forKey key: String, read: @escaping @Sendable () -> Value) -> Value {
        let now = clock()
        lock.lock()
        if var entry = entries[key] {
            if now - entry.capturedAt > maxAge, !entry.refreshing {
                entry.refreshing = true
                entries[key] = entry
                let generation = generation
                lock.unlock()
                refreshQueue.async { [self] in store(read(), forKey: key, generation: generation) }
                return entry.value
            }
            lock.unlock()
            return entry.value
        }
        let generation = generation
        lock.unlock()
        let value = read()
        store(value, forKey: key, generation: generation)
        return value
    }

    func valueIfReadable(forKey key: String, read: @escaping @Sendable () -> Value?) -> Value? {
        let now = clock()
        lock.lock()
        if var entry = entries[key] {
            if now - entry.capturedAt > maxAge, !entry.refreshing {
                entry.refreshing = true
                entries[key] = entry
                let generation = generation
                lock.unlock()
                refreshQueue.async { [self] in
                    if let value = read() {
                        store(value, forKey: key, generation: generation)
                    } else {
                        lock.withLock { if generation == self.generation { entries[key]?.refreshing = false } }
                    }
                }
                return entry.value
            }
            lock.unlock()
            return entry.value
        }
        let generation = generation
        lock.unlock()
        guard let value = read() else { return nil }
        store(value, forKey: key, generation: generation)
        return value
    }

    func cachedValue(forKey key: String) -> Value? {
        lock.withLock { entries[key]?.value }
    }

    func removeAll() {
        lock.withLock {
            generation &+= 1
            entries.removeAll()
        }
    }

    func removeAll(except key: String?) {
        lock.withLock {
            guard entries.keys.contains(where: { $0 != key }) else { return }
            let kept = key.flatMap { entries[$0] }
            generation &+= 1
            entries.removeAll()
            if let key, let kept { entries[key] = Entry(value: kept.value, capturedAt: kept.capturedAt) }
        }
    }

    func waitForRefreshes() {
        refreshQueue.sync {}
    }

    private func store(_ value: Value, forKey key: String, generation: UInt64) {
        lock.withLock {
            guard generation == self.generation else { return }
            if entries[key] == nil, entries.count >= maxEntries,
               let oldest = entries.min(by: { $0.value.capturedAt < $1.value.capturedAt })?.key {
                entries[oldest] = nil
            }
            entries[key] = Entry(value: value, capturedAt: clock())
        }
    }
}
