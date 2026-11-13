import Foundation

// Compile with the production CotypingTokenCandidates.swift and -O. This is a
// CPU component benchmark, not keystroke-to-overlay or model-generation timing.
@main
enum TokenRankingBenchmark {
    // Keep the original Int32 argmax exactly: changing the index representation
    // changes Swift's optimizer output and exaggerates the baseline cost.
    static func previousArgmax(in logits: UnsafePointer<Float>?, vocabularySize: Int32) -> Int32? {
        guard let logits, vocabularySize > 0 else { return nil }
        var bestToken: Int32?
        var bestLogit = -Float.infinity
        for index in 0..<Int(vocabularySize) {
            let value = logits[index]
            guard !value.isNaN else { continue }
            if value > bestLogit {
                bestLogit = value
                bestToken = Int32(index)
            }
        }
        return bestToken
    }

    @inline(never)
    static func previous(_ input: [Float], count: Int) -> [Int32] {
        var scores = input
        var result: [Int32] = []
        for _ in 0..<count {
            let winner = scores.withUnsafeBufferPointer {
                previousArgmax(in: $0.baseAddress, vocabularySize: Int32($0.count))
            }
            guard let winner else { break }
            result.append(winner)
            scores[Int(winner)] = -.infinity
        }
        return result
    }

    @inline(never)
    static func candidate(_ scores: [Float], count: Int) -> [Int32] {
        scores.withUnsafeBufferPointer {
            Array(CotypingTokenCandidates.topTokens(
                in: $0.baseAddress, vocabularySize: Int32($0.count), limit: 64).prefix(count))
        }
    }

    static func main() throws {
        var rows: [[String: Any]] = []
        var passesSpeedGate = true
        for size in [65_536, 262_144] {
            var seed: UInt64 = 42
            var scores = (0..<size).map { _ -> Float in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                return Float(Int64(bitPattern: seed) % 100_000) / 1000
            }
            scores[5] = .nan
            scores[25] = -.infinity
            precondition(previous(scores, count: 64) == candidate(scores, count: 64))
            for rank in [1, 8, 64] {
                var before: [Double] = []
                var after: [Double] = []
                for round in 0..<25 {
                    // Alternate order to reduce order/thermal bias; discard warmup.
                    for updated in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let value = updated ? candidate(scores, count: rank) : previous(scores, count: rank)
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                        precondition(value == previous(scores, count: rank))
                        if round >= 5 {
                            if updated { after.append(elapsed) } else { before.append(elapsed) }
                        }
                    }
                }
                before.sort(); after.sort()
                if rank == 64, before[before.count / 2] < after[after.count / 2] * 4 {
                    passesSpeedGate = false
                }
                rows.append([
                    "vocabularySize": size, "matchingCandidateRank": rank, "samples": before.count,
                    "beforeMedianMs": before[before.count / 2], "afterMedianMs": after[after.count / 2],
                    "beforeP95Ms": before[Int(ceil(Double(before.count) * 0.95)) - 1],
                    "afterP95Ms": after[Int(ceil(Double(after.count) * 0.95)) - 1],
                    "identicalCandidates": true,
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if CommandLine.arguments.contains("--check"), !passesSpeedGate {
            FileHandle.standardError.write(Data("Expected at least 4x faster rank-64 selection.\n".utf8))
            exit(1)
        }
    }
}
