import Foundation

enum ActionStatusFilter: String, CaseIterable {
    case all, active, open, deferred, done

    var description: String {
        switch self {
        case .all: ""
        case .active: "open or deferred "
        case .open: "open "
        case .deferred: "deferred "
        case .done: "completed "
        }
    }

    func includes(_ thread: ActionThread) -> Bool {
        thread.references.contains { reference in
            switch self {
            case .all: true
            case .active: reference.status != .done
            case .open: reference.status == .open
            case .deferred: reference.status == .deferred
            case .done: reference.status == .done
            }
        }
    }
}
