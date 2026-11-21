import Foundation

enum CotypingTokenCandidates {
    private struct Candidate {
        let token: Int32
        let score: Float

        func precedes(_ other: Candidate) -> Bool {
            score > other.score || (score == other.score && token < other.token)
        }
    }

    static func topTokens(
        in logits: UnsafePointer<Float>?,
        vocabularySize: Int32,
        limit: Int
    ) -> [Int32] {
        guard let logits, vocabularySize > 0, limit > 0 else { return [] }
        let capacity = min(limit, Int(vocabularySize))
        var heap: [Candidate] = []
        heap.reserveCapacity(capacity)
        for index in 0..<Int(vocabularySize) {
            let score = logits[index]
            guard score > -Float.infinity else { continue }
            let candidate = Candidate(token: Int32(index), score: score)
            if heap.count < capacity {
                heap.append(candidate)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard heap[parent].precedes(heap[child]) else { break }
                    heap.swapAt(parent, child)
                    child = parent
                }
            } else if candidate.precedes(heap[0]) {
                heap[0] = candidate
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, heap[child].precedes(heap[child + 1]) {
                        child += 1
                    }
                    guard heap[parent].precedes(heap[child]) else { break }
                    heap.swapAt(parent, child)
                    parent = child
                }
            }
        }
        return heap.sorted { $0.precedes($1) }.map(\.token)
    }
}
