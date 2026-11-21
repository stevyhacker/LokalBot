import AVFoundation
import Synchronization

final class RealtimeBufferRing: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    private let identities: [ObjectIdentifier: Int]
    private let slots: UnsafeMutablePointer<Int>
    private let capacity: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(buffers: [AVAudioPCMBuffer]) {
        self.buffers = buffers
        capacity = buffers.count + 1
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: 0, count: capacity)
        var identities: [ObjectIdentifier: Int] = [:]
        for (index, buffer) in buffers.enumerated() {
            slots[index] = index
            identities[ObjectIdentifier(buffer)] = index
        }
        self.identities = identities
        tail.store(buffers.count, ordering: .releasing)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    func borrow() -> AVAudioPCMBuffer? {
        let start = head.load(ordering: .relaxed)
        guard start != tail.load(ordering: .acquiring) else { return nil }
        let buffer = buffers[slots[start]]
        head.store((start + 1) % capacity, ordering: .releasing)
        return buffer
    }

    func giveBack(_ buffer: AVAudioPCMBuffer) {
        guard let index = identities[ObjectIdentifier(buffer)] else { return }
        let end = tail.load(ordering: .relaxed)
        let next = (end + 1) % capacity
        guard next != head.load(ordering: .acquiring) else { return }
        slots[end] = index
        tail.store(next, ordering: .releasing)
    }

    var availableCount: Int {
        let start = head.load(ordering: .acquiring)
        let end = tail.load(ordering: .acquiring)
        return (end - start + capacity) % capacity
    }
}
