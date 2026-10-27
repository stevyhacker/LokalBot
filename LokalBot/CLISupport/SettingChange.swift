import Foundation

/// How one requested change is authorized. Only `preference` and `narrowing`
/// changes apply directly; `widening` needs the person's approval in the app.
enum SettingChangeClass: String, Codable {
    case unchanged
    case preference
    case narrowing
    case widening
    case readOnly
}

extension SettingSpec {
    /// Reads a value typed on the command line into the form `config get`
    /// prints: tokens for choices, numbers, booleans, lists. Lists and
    /// structured values also accept JSON.
    func parse(_ text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bool:
            switch trimmed.lowercased() {
            case "true", "on", "yes", "1": return .bool(true)
            case "false", "off", "no", "0": return .bool(false)
            default: throw invalidValue("expects true or false")
            }
        case .integer:
            guard let value = Int(trimmed) else { throw invalidValue("expects a whole number") }
            return .number(Double(value))
        case .number:
            guard let value = Double(trimmed), value.isFinite else { throw invalidValue("expects a number") }
            return .number(value)
        case .text(let format):
            return .string(format == .plain ? text : trimmed)
        case .choice:
            return .string(trimmed)
        case .textList, .choiceList:
            if trimmed.hasPrefix("[") { return try json(trimmed) }
            return .array(trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(JSONValue.string))
        case .structured:
            return try json(trimmed)
        }
    }

    /// The value `AppSettings` stores for a presented value, after type,
    /// range, and choice checks. The app's decoder still has the last word.
    func stored(fromPresented value: JSONValue) throws -> JSONValue {
        switch kind {
        case .bool:
            guard case .bool = value else { throw invalidValue("expects true or false") }
            return value
        case .integer(let range):
            guard let number = value.intValue else { throw invalidValue("expects a whole number") }
            if let range, !range.contains(number) {
                throw invalidValue("must be between \(range.lowerBound) and \(range.upperBound)")
            }
            return .number(Double(number))
        case .number(let range):
            guard case .number(let number) = value, number.isFinite else { throw invalidValue("expects a number") }
            if let range, !range.contains(number) {
                throw invalidValue("must be between \(Self.format(range.lowerBound)) and \(Self.format(range.upperBound))")
            }
            return value
        case .text:
            guard case .string = value else { throw invalidValue("expects text") }
            return value
        case .textList:
            guard case .array(let items) = value, items.allSatisfy({ $0.stringValue != nil }) else {
                throw invalidValue("expects a list of text")
            }
            return value
        case .choice(let choices):
            guard let token = value.stringValue, let choice = choices.first(where: { $0.token == token }) else {
                throw invalidValue("expects one of: \(choices.map(\.token).joined(separator: ", "))")
            }
            return choice.stored
        case .choiceList(let choices):
            guard case .array(let items) = value else {
                throw invalidValue("expects a list of: \(choices.map(\.token).joined(separator: ", "))")
            }
            var stored: [JSONValue] = []
            for item in items {
                guard let token = item.stringValue, let choice = choices.first(where: { $0.token == token }) else {
                    throw invalidValue("expects a list of: \(choices.map(\.token).joined(separator: ", "))")
                }
                if !stored.contains(choice.stored) { stored.append(choice.stored) }
            }
            return .array(stored)
        case .structured:
            switch value {
            case .object, .array: return value
            default: throw invalidValue("expects a JSON object, as `config get` prints it")
            }
        }
    }

    /// Whether a change from `old` to `new` (both stored values) can apply
    /// directly. A consent setting widens when it captures, reads, records,
    /// keeps, or sends more; narrowing it is always allowed.
    func classify(from old: JSONValue?, to new: JSONValue) -> SettingChangeClass {
        if old == new { return .unchanged }
        switch tier {
        case .readOnly: return .readOnly
        case .preference: return .preference
        case .consent: return widens(from: old, to: new) ? .widening : .narrowing
        }
    }

    private func widens(from old: JSONValue?, to new: JSONValue) -> Bool {
        switch key {
        case "requireCalendarForBrowser":
            // Requiring a calendar match narrows auto-recording; dropping it widens.
            return new == .bool(false)
        case "retentionDays", "keepOCRTextForever":
            // Longer retention keeps more; shorter deletes, which goes through
            // the reviewed cleanup. Either way the person decides.
            return true
        case "autoRecordMode":
            return new == choiceStored("automatic")
        case "screenContextCaptureMode":
            return choiceRank(new) > choiceRank(old)
        case "openRouterDataPolicy":
            return new == choiceStored("accountPolicy")
        case "modelDownloadSource":
            // Each later source puts another third-party host ahead of the
            // earlier ones (ModelScope, then HF-Mirror, then Hugging Face), so
            // only moving back toward Hugging Face narrows.
            return choiceRank(new) > choiceRank(old)
        default:
            break
        }
        switch kind {
        case .bool:
            return new == .bool(true)
        case .text(.commaSeparated):
            // Exclusions: removing an entry captures or suggests in more places.
            let before = Self.entries(old?.stringValue ?? "")
            return !before.subtracting(Self.entries(new.stringValue ?? "")).isEmpty
        case .text(.path):
            // A new export or routine folder writes outside the library.
            return !(new.stringValue ?? "").isEmpty
        case .textList:
            // Approved origins: adding one sends data to a new place.
            let before = Set((old.flatMap(Self.strings) ?? []).map { $0.lowercased() })
            return !Set((Self.strings(new) ?? []).map { $0.lowercased() }).subtracting(before).isEmpty
        default:
            return true
        }
    }

    private func choiceStored(_ token: String) -> JSONValue? {
        kind.choices?.first { $0.token == token }?.stored
    }

    private func choiceRank(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        return kind.choices?.firstIndex { $0.stored == value } ?? 0
    }

    private static func entries(_ text: String) -> Set<String> {
        Set(text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    private static func strings(_ value: JSONValue) -> [String]? {
        guard case .array(let items) = value else { return nil }
        return items.compactMap(\.stringValue)
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private func json(_ text: String) throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw invalidValue("is not valid JSON")
        }
        return value
    }

    private func invalidValue(_ message: String) -> AppControlError {
        AppControlError.invalidValue(key, message)
    }
}

/// A `settings.set` request: values as `config get` prints them, keys to
/// reset to their defaults, and whether to only report what would happen.
struct SettingsChangeRequest: Equatable {
    var changes: [String: JSONValue]
    var reset: [String]
    var dryRun: Bool

    init(changes: [String: JSONValue] = [:], reset: [String] = [], dryRun: Bool = false) {
        self.changes = changes
        self.reset = reset
        self.dryRun = dryRun
    }

    init(params: [String: JSONValue]?) throws {
        var changes: [String: JSONValue] = [:]
        if let value = params?["changes"] {
            guard let object = value.objectValue else {
                throw AppControlError.invalidRequest("\"changes\" must be an object of setting keys and values.")
            }
            changes = object
        }
        var reset: [String] = []
        if let value = params?["reset"] {
            guard case .array(let items) = value, items.allSatisfy({ $0.stringValue != nil }) else {
                throw AppControlError.invalidRequest("\"reset\" must be a list of setting keys.")
            }
            reset = items.compactMap(\.stringValue)
        }
        guard !changes.isEmpty || !reset.isEmpty else {
            throw AppControlError.invalidRequest("Name at least one setting to change or reset.")
        }
        if let overlap = reset.first(where: { changes[$0] != nil }) {
            throw AppControlError.invalidRequest("\(overlap) is both changed and reset.")
        }
        var dryRun = false
        if case .bool(let value)? = params?["dryRun"] { dryRun = value }
        self.init(changes: changes, reset: reset, dryRun: dryRun)
    }

    var params: [String: JSONValue] {
        var params: [String: JSONValue] = ["dryRun": .bool(dryRun)]
        if !changes.isEmpty { params["changes"] = .object(changes) }
        if !reset.isEmpty { params["reset"] = .array(reset.map(JSONValue.string)) }
        return params
    }
}

/// What a `settings.set` request would do to the current settings: the
/// stored value each key gets and how each change is authorized. Pure, so the
/// app and the tests share it; the app then decodes and applies the result.
struct SettingsChangePlan: Equatable {
    struct Item: Equatable {
        let spec: SettingSpec
        let previous: JSONValue?
        /// Nil removes the key, for an optional setting reset to its default.
        let stored: JSONValue?
        let change: SettingChangeClass
    }

    let items: [Item]

    var readOnly: [Item] { items.filter { $0.change == .readOnly } }
    var widening: [Item] { items.filter { $0.change == .widening } }
    var applicable: [Item] { items.filter { $0.change == .preference || $0.change == .narrowing } }

    static func make(
        request: SettingsChangeRequest,
        current: [String: JSONValue],
        defaults: [String: JSONValue],
        redactURL: (String) -> String = { $0 }
    ) throws -> SettingsChangePlan {
        var items: [String: Item] = [:]
        for (key, value) in request.changes {
            guard let spec = SettingRegistry.spec(for: key) else { throw AppControlError.unknownKey(key) }
            var stored = try spec.stored(fromPresented: value)
            // `config list` and `export` show URLs without user info or query.
            // Writing that form back must not strip them from the real value.
            if case .text(.url) = spec.kind, let existing = current[key]?.stringValue,
               stored.stringValue == redactURL(existing) {
                stored = .string(existing)
            }
            items[key] = Item(spec: spec, previous: current[key], stored: stored,
                              change: spec.classify(from: current[key], to: stored))
        }
        for key in request.reset {
            guard let spec = SettingRegistry.spec(for: key) else { throw AppControlError.unknownKey(key) }
            let stored = defaults[key]
            let change: SettingChangeClass = stored == current[key]
                ? .unchanged
                : spec.classify(from: current[key], to: stored ?? .null)
            items[key] = Item(spec: spec, previous: current[key], stored: stored, change: change)
        }
        let order = Dictionary(uniqueKeysWithValues: SettingRegistry.all.enumerated().map { ($1.key, $0) })
        return SettingsChangePlan(items: items.values.sorted { order[$0.spec.key, default: 0] < order[$1.spec.key, default: 0] })
    }

    /// Reviewed items again, from the settings as they are now: the same keys
    /// and values, each classified from its current value.
    static func rebasing(_ items: [Item], on current: [String: JSONValue]) -> SettingsChangePlan {
        SettingsChangePlan(items: items.map { item in
            let previous = current[item.spec.key]
            let change: SettingChangeClass = item.stored == previous
                ? .unchanged
                : item.spec.classify(from: previous, to: item.stored ?? .null)
            return Item(spec: item.spec, previous: previous, stored: item.stored, change: change)
        })
    }

    /// Whether this plan widens something `reviewed` did not show: a widening
    /// change that was not on it, or one that now starts from another value.
    func widens(beyond reviewed: [Item]) -> Bool {
        widening.contains { item in
            guard let shown = reviewed.first(where: { $0.spec.key == item.spec.key }) else { return true }
            return shown.change != .widening || shown.previous != item.previous
        }
    }

    /// The report each item gets in a `settings.set` reply.
    func entries(redactURL: (String) -> String = { $0 }) -> [JSONValue] {
        items.map { item in
            [
                "key": .string(item.spec.key),
                "title": .string(item.spec.title),
                "tier": .string(item.spec.tier.rawValue),
                "change": .string(item.change.rawValue),
                "previous": Self.presented(item.previous, item.spec, redactURL),
                "value": Self.presented(item.stored, item.spec, redactURL),
            ]
        }
    }

    private static func presented(_ stored: JSONValue?, _ spec: SettingSpec, _ redactURL: (String) -> String) -> JSONValue {
        guard let stored else { return .null }
        if case .text(.url) = spec.kind, case .string(let url) = stored { return .string(redactURL(url)) }
        return spec.presented(stored)
    }
}
