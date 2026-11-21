import Foundation

struct CotypingMemoryLookup {
    struct Ticket: Equatable {
        let anchor: String
        let query: CotypingMemoryContext.Query
    }

    private(set) var snapshot = CotypingMemoryContextProvider.Snapshot.empty
    private var anchor: String?
    private var requested: CotypingMemoryContext.Query?
    var task: Task<Void, Never>?

    func needsLookup(anchor: String, query: CotypingMemoryContext.Query) -> Bool {
        anchor != self.anchor || query != requested
    }

    mutating func begin(anchor: String, query: CotypingMemoryContext.Query) -> Ticket {
        task?.cancel()
        task = nil
        if anchor != self.anchor { snapshot = .empty }
        self.anchor = anchor
        requested = query
        return Ticket(anchor: anchor, query: query)
    }

    mutating func finish(_ ticket: Ticket, with result: CotypingMemoryContextProvider.Snapshot) {
        guard ticket.anchor == anchor, ticket.query == requested else { return }
        snapshot = result
        task = nil
    }

    mutating func reset() {
        task?.cancel()
        self = CotypingMemoryLookup()
    }

    static func finishedWords(of text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return String(text[..<(text.lastIndex { !($0.isLetter || $0.isNumber) }.map(text.index(after:)) ?? text.startIndex)])
    }
}
