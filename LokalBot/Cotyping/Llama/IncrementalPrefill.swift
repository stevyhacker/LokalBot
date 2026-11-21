import Foundation

enum IncrementalPrefill {
    static func commonPrefixLength(_ a: [Int32], _ b: [Int32]) -> Int {
        let limit = min(a.count, b.count)
        var p = 0
        while p < limit && a[p] == b[p] { p += 1 }
        return p
    }
}
