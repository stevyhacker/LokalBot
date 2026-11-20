import Foundation

final class CotypingSurfaceCaptureSingleFlight: @unchecked Sendable {
    private final class Flight {
        let key: String
        let generation: UInt64
        let completion = DispatchGroup()
        var result: CotypingSurfaceCapture?

        init(key: String, generation: UInt64) {
            self.key = key
            self.generation = generation
            completion.enter()
        }
    }

    private let lock = NSLock()
    private var cachedKey: String?
    private var cachedCapture: CotypingSurfaceCapture = .empty
    private var cachedAt: TimeInterval?
    private var activeFlight: Flight?
    private var generation: UInt64 = 0

    func cachedValue(
        forKey key: String,
        maxAge: TimeInterval? = nil,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> CotypingSurfaceCapture? {
        lock.withLock {
            guard cachedKey == key,
                  isFresh(cachedAt: cachedAt, maxAge: maxAge, now: clock()) else {
                return nil
            }
            return cachedCapture
        }
    }

    func capture(
        forKey key: String,
        maxAge: TimeInterval? = nil,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        resolve: () -> CotypingSurfaceCapture
    ) -> CotypingSurfaceCapture {
        while true {
            lock.lock()
            if cachedKey == key,
               isFresh(cachedAt: cachedAt, maxAge: maxAge, now: clock()) {
                let value = cachedCapture
                lock.unlock()
                return value
            }
            if let activeFlight {
                let sharesResult = activeFlight.key == key
                    && activeFlight.generation == generation
                lock.unlock()
                activeFlight.completion.wait()
                if sharesResult,
                   let result = lock.withLock({ activeFlight.result }) {
                    return result
                }
                continue
            }

            let flight = Flight(key: key, generation: generation)
            activeFlight = flight
            lock.unlock()

            let resolved = resolve()

            lock.withLock {
                if flight.generation == generation {
                    cachedKey = key
                    cachedCapture = resolved
                    cachedAt = clock()
                }
                flight.result = resolved
                if activeFlight === flight {
                    activeFlight = nil
                }
            }
            flight.completion.leave()
            return resolved
        }
    }

    func removeAll() {
        lock.withLock {
            generation &+= 1
            cachedKey = nil
            cachedCapture = .empty
            cachedAt = nil
        }
    }

    private func isFresh(cachedAt: TimeInterval?, maxAge: TimeInterval?, now: TimeInterval) -> Bool {
        guard let maxAge else { return true }
        guard let cachedAt, maxAge >= 0, now >= cachedAt else { return false }
        return now - cachedAt <= maxAge
    }
}
