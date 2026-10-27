// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// Inline `/macro` autocomplete. A faithful port of Cotabby's macro subsystem
/// (`MacroEngine` + the arithmetic / date / random / unit / currency families),
/// folded into one self-contained file and driven from the focused field's AX
/// text instead of Cotabby's stateful capture.
///
/// Trigger: a `/` only opens a query at a word boundary (start of field or after
/// whitespace), so `http://`, `and/or`, and file paths typed mid-sentence never
/// fire. Crucially the macro is **evaluate-or-nothing**: the ghost only shows
/// when the typed `/query` actually computes to a result, so a stale `/` run or
/// arbitrary text never surfaces junk. Examples:
/// `/5+5` → `= 10`, `/10km->mi` → `6.214 mi`, `/today` → `Jun 23, 2026`,
/// `/100usd to eur` → `€92.00`, `/d20` → a roll, `/uuid` → a UUID.
enum CotypingMacro {

    /// A computed result: what to preview under the caret, and what to insert on
    /// accept. The two differ for arithmetic (`= 10` preview, `10` insertion).
    struct Result: Equatable {
        let preview: String
        let insertion: String
        init(preview: String, insertion: String) { self.preview = preview; self.insertion = insertion }
        init(_ value: String) { preview = value; insertion = value }
    }

    // MARK: - Trigger scan

    /// Best macro for the trailing `/query` at the caret, or nil. Uses the live
    /// clock/RNG by default; tests inject a deterministic `Engine`.
    static func match(
        trailing precedingText: String,
        engine: Engine = .standard
    ) -> (result: Result, tokenLength: Int, query: String)? {
        guard let token = scanToken(in: precedingText), let result = engine.evaluate(token.query) else { return nil }
        return (result, token.tokenLength, token.query)
    }

    /// Length of the trailing `/query` run (`/` + query), regardless of whether it
    /// evaluates — used to delete it on accept.
    static func trailingTokenLength(in precedingText: String) -> Int? {
        scanToken(in: precedingText)?.tokenLength
    }

    /// The raw query after a boundary `/` at the caret (testable scan), or nil.
    static func trailingQuery(in precedingText: String) -> String? {
        scanToken(in: precedingText)?.query
    }

    private struct Token { let query: String; let tokenLength: Int }

    private static let sigil: Character = "/"
    private static let maxQueryLength = 48

    /// Walks back from the caret collecting the query until a boundary `/` (the
    /// sigil). An internal `/` preceded by a non-space (division, `5/2`) stays in
    /// the query; a newline or an over-long run aborts.
    private static func scanToken(in text: String) -> Token? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        var collected: [Character] = []
        var index = chars.count - 1
        while index >= 0 {
            let char = chars[index]
            if char.isNewline { return nil }
            if char == sigil, index == 0 || chars[index - 1].isWhitespace {
                let query = String(collected.reversed())
                guard !query.isEmpty else { return nil }
                return Token(query: query, tokenLength: query.count + 1)
            }
            collected.append(char)
            if collected.count > maxQueryLength { return nil }
            index -= 1
        }
        return nil
    }

    // MARK: - Engine

    /// Aggregates the macro families and tries them in priority order (date and
    /// random are keyword-specific; unit and currency both key off the conversion
    /// separator but reject each other's tokens; arithmetic is the catch-all).
    /// The clock, RNG, and rate table are injected so the engine is deterministic.
    struct Engine {
        var now: () -> Date = Date.init
        var calendar: Calendar = .current
        var locale: Locale = .current
        var random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
        var uuid: () -> String = { UUID().uuidString }
        var rates: CurrencyRateTable = .bundled

        static let standard = Engine()

        /// Result for the typed `/query` (without the `/`), or nil.
        func evaluate(_ rawQuery: String) -> Result? {
            let query = rawQuery.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return nil }
            return evaluateDate(query)
                ?? evaluateRandom(query)
                ?? Engine.evaluateUnit(query)
                ?? evaluateCurrency(query)
                ?? Engine.evaluateArithmetic(query)
        }

        // MARK: Date / time

        private func evaluateDate(_ query: String) -> Result? {
            let lower = query.lowercased()
            let (rawBase, argument) = Engine.splitArgument(lower)
            let base = Engine.canonicalBase(rawBase)

            if let relative = relativeDate(base) {
                return Result(formatDate(relative, style: dateStyle(for: argument)))
            }
            switch base {
            case "today", "date":
                return Result(formatDate(now(), style: dateStyle(for: argument)))
            case "tomorrow":
                return offsetDays(1).map { Result(formatDate($0, style: dateStyle(for: argument))) }
            case "yesterday":
                return offsetDays(-1).map { Result(formatDate($0, style: dateStyle(for: argument))) }
            case "now", "time":
                return Result(formatTime(now(), use24Hour: argument == "24h"))
            case "datetime":
                return Result(formatDateTime(now()))
            case "noon":
                return timeOfDay(hour: 12).map { Result(formatTime($0, use24Hour: argument == "24h")) }
            case "midnight":
                return timeOfDay(hour: 0).map { Result(formatTime($0, use24Hour: argument == "24h")) }
            default:
                break
            }
            if let weekday = weekdayDate(base) {
                return Result(formatDate(weekday, style: dateStyle(for: argument)))
            }
            return nil
        }

        private func offsetDays(_ days: Int) -> Date? {
            calendar.date(byAdding: .day, value: days, to: now())
        }
        private func timeOfDay(hour: Int) -> Date? {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now())
        }

        /// Relative offsets like `+3d`, `-5d`, `+2w`, `+1mo`, `+1y`.
        private func relativeDate(_ base: String) -> Date? {
            guard let sign = base.first, sign == "+" || sign == "-" else { return nil }
            let rest = base.dropFirst()
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, let magnitude = Int(digits) else { return nil }
            let unit = String(rest.dropFirst(digits.count))
            let value = (sign == "-" ? -1 : 1) * magnitude
            switch unit {
            case "d", "day", "days": return calendar.date(byAdding: .day, value: value, to: now())
            case "w", "wk", "wks", "week", "weeks": return calendar.date(byAdding: .weekOfYear, value: value, to: now())
            case "mo", "month", "months": return calendar.date(byAdding: .month, value: value, to: now())
            case "y", "yr", "yrs", "year", "years": return calendar.date(byAdding: .year, value: value, to: now())
            default: return nil
            }
        }

        /// `next-<weekday>` (strictly after today), `this-<weekday>` (incl. today),
        /// `last-<weekday>` (strictly before today).
        private func weekdayDate(_ base: String) -> Date? {
            let parts = base.split(separator: "-", maxSplits: 1).map(String.init)
            guard parts.count == 2, let target = Engine.weekdays[parts[1]] else { return nil }
            let todayWeekday = calendar.component(.weekday, from: now())
            let forward = (target - todayWeekday + 7) % 7
            let delta: Int
            switch parts[0] {
            case "this": delta = forward
            case "next": delta = forward == 0 ? 7 : forward
            case "last": delta = forward == 0 ? -7 : forward - 7
            default: return nil
            }
            return calendar.date(byAdding: .day, value: delta, to: now())
        }

        private enum Style { case iso, short, medium, long }

        private func dateStyle(for argument: String?) -> Style {
            switch argument {
            case "iso": return .iso
            case "long": return .long
            case "short": return .short
            default: return .medium
            }
        }

        private func formatDate(_ date: Date, style: Style) -> String {
            if style == .iso {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.timeStyle = .none
            switch style {
            case .short: formatter.dateStyle = .short
            case .long: formatter.dateStyle = .long
            default: formatter.dateStyle = .medium
            }
            return formatter.string(from: date)
        }

        private func formatTime(_ date: Date, use24Hour: Bool) -> String {
            let formatter = DateFormatter()
            formatter.timeZone = calendar.timeZone
            if use24Hour {
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "HH:mm"
            } else {
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            }
            return formatter.string(from: date)
        }

        private func formatDateTime(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        private static func splitArgument(_ string: String) -> (String, String?) {
            guard let open = string.firstIndex(of: "("), string.hasSuffix(")") else { return (string, nil) }
            let base = String(string[string.startIndex..<open])
            let argument = String(string[string.index(after: open)..<string.index(before: string.endIndex)])
            return (base, argument.isEmpty ? nil : argument)
        }

        /// Short forms / misspellings mapped to a canonical keyword.
        private static let baseAliases: [String: String] = [
            "tdy": "today", "tod": "today", "tody": "today", "2day": "today",
            "tmr": "tomorrow", "tmrw": "tomorrow", "tmw": "tomorrow", "tom": "tomorrow", "tomo": "tomorrow",
            "tomorow": "tomorrow", "2moro": "tomorrow", "2mrw": "tomorrow",
            "yest": "yesterday", "yday": "yesterday", "ystdy": "yesterday", "yesty": "yesterday", "yesterdy": "yesterday",
            "rn": "now", "rightnow": "now", "atm": "now",
            "midday": "noon", "noontime": "noon", "midnite": "midnight",
            "dt": "datetime",
        ]

        /// Applies `baseAliases`, then rewrites a `next`/`this`/`last` weekday prefix
        /// written with a space or no separator into the dash form (`next-fri`).
        private static func canonicalBase(_ base: String) -> String {
            if let alias = baseAliases[base] { return alias }
            for prefix in ["next", "this", "last"] where base.hasPrefix(prefix) && base.count > prefix.count {
                let rest = base.dropFirst(prefix.count).drop { $0 == " " || $0 == "-" || $0 == "_" }
                if !rest.isEmpty { return "\(prefix)-\(rest)" }
            }
            return base
        }

        private static let weekdays: [String: Int] = [
            "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
            "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
            "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
        ]

        // MARK: Random

        private func evaluateRandom(_ query: String) -> Result? {
            let lower = query.lowercased()
            switch lower {
            case "uuid", "guid": return Result(uuid())
            case "dice", "die", "roll": return Result(String(random(1...6)))
            case "coin", "flip", "coinflip", "coin-flip": return Result(random(0...1) == 0 ? "Heads" : "Tails")
            case "random", "rand", "rnd": return Result(String(random(0...100)))
            default:
                if let sides = Engine.diceSides(lower) { return Result(String(random(1...sides))) }
                return parameterizedRandom(lower)
            }
        }

        private static func diceSides(_ lower: String) -> Int? {
            guard lower.hasPrefix("d"), lower.count > 1, let sides = Int(lower.dropFirst()), sides >= 1 else { return nil }
            return sides
        }

        private func parameterizedRandom(_ lower: String) -> Result? {
            let prefixes = ["random(", "rand(", "rnd("]
            guard prefixes.contains(where: { lower.hasPrefix($0) }),
                  lower.hasSuffix(")"), let open = lower.firstIndex(of: "(") else { return nil }
            let inner = String(lower[lower.index(after: open)..<lower.index(before: lower.endIndex)])
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let values = parts.compactMap { Int($0) }
            guard values.count == parts.count, !values.isEmpty else { return nil }
            switch values.count {
            case 1:
                guard values[0] >= 1 else { return nil }
                return Result(String(random(1...values[0])))
            case 2:
                return Result(String(random(min(values[0], values[1])...max(values[0], values[1]))))
            default:
                return nil
            }
        }

        // MARK: Unit conversion (offline, Foundation Measurement)

        private enum Quantity {
            case length(UnitLength), mass(UnitMass), temperature(UnitTemperature), volume(UnitVolume)
        }

        private static func evaluateUnit(_ query: String) -> Result? {
            guard let (lhsRaw, rhsRaw) = splitConversion(query) else { return nil }
            let lhs = lhsRaw.trimmingCharacters(in: .whitespaces)
            let toToken = rhsRaw.trimmingCharacters(in: .whitespaces).lowercased()
            let numberPart = lhs.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
            let fromToken = lhs.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces).lowercased()
            guard let value = Double(numberPart), !fromToken.isEmpty, !toToken.isEmpty,
                  let from = units[fromToken], let to = units[toToken],
                  let converted = convert(value, from: from, to: to) else { return nil }
            return Result("\(unitFormat(converted)) \(toToken)")
        }

        private static func convert(_ value: Double, from: Quantity, to: Quantity) -> Double? {
            switch (from, to) {
            case let (.length(s), .length(t)): return Measurement(value: value, unit: s).converted(to: t).value
            case let (.mass(s), .mass(t)): return Measurement(value: value, unit: s).converted(to: t).value
            case let (.temperature(s), .temperature(t)): return Measurement(value: value, unit: s).converted(to: t).value
            case let (.volume(s), .volume(t)): return Measurement(value: value, unit: s).converted(to: t).value
            default: return nil
            }
        }

        private static func unitFormat(_ value: Double) -> String {
            if value == value.rounded(), value.magnitude < 1e12 { return String(Int64(value)) }
            return String(format: "%.4g", value)
        }

        private static let units: [String: Quantity] = [
            "mm": .length(.millimeters), "millimeter": .length(.millimeters), "millimeters": .length(.millimeters),
            "cm": .length(.centimeters), "centimeter": .length(.centimeters), "centimeters": .length(.centimeters),
            "m": .length(.meters), "meter": .length(.meters), "meters": .length(.meters),
            "metre": .length(.meters), "metres": .length(.meters),
            "km": .length(.kilometers), "kilometer": .length(.kilometers), "kilometers": .length(.kilometers),
            "in": .length(.inches), "inch": .length(.inches), "inches": .length(.inches),
            "ft": .length(.feet), "foot": .length(.feet), "feet": .length(.feet),
            "yd": .length(.yards), "yard": .length(.yards), "yards": .length(.yards),
            "mi": .length(.miles), "mile": .length(.miles), "miles": .length(.miles),
            "mg": .mass(.milligrams), "milligram": .mass(.milligrams), "milligrams": .mass(.milligrams),
            "g": .mass(.grams), "gram": .mass(.grams), "grams": .mass(.grams),
            "kg": .mass(.kilograms), "kgs": .mass(.kilograms), "kilo": .mass(.kilograms), "kilos": .mass(.kilograms),
            "kilogram": .mass(.kilograms), "kilograms": .mass(.kilograms),
            "oz": .mass(.ounces), "ounce": .mass(.ounces), "ounces": .mass(.ounces),
            "lb": .mass(.pounds), "lbs": .mass(.pounds), "pound": .mass(.pounds), "pounds": .mass(.pounds),
            "st": .mass(.stones), "stone": .mass(.stones), "stones": .mass(.stones),
            "c": .temperature(.celsius), "celsius": .temperature(.celsius), "centigrade": .temperature(.celsius),
            "f": .temperature(.fahrenheit), "fahrenheit": .temperature(.fahrenheit),
            "k": .temperature(.kelvin), "kelvin": .temperature(.kelvin),
            "ml": .volume(.milliliters), "milliliter": .volume(.milliliters), "milliliters": .volume(.milliliters),
            "l": .volume(.liters), "liter": .volume(.liters), "liters": .volume(.liters),
            "litre": .volume(.liters), "litres": .volume(.liters),
            "cup": .volume(.cups), "cups": .volume(.cups),
            "tbsp": .volume(.tablespoons), "tablespoon": .volume(.tablespoons), "tablespoons": .volume(.tablespoons),
            "tsp": .volume(.teaspoons), "teaspoon": .volume(.teaspoons), "teaspoons": .volume(.teaspoons),
            "floz": .volume(.fluidOunces),
            "gal": .volume(.gallons), "gallon": .volume(.gallons), "gallons": .volume(.gallons),
            "pt": .volume(.pints), "pint": .volume(.pints), "pints": .volume(.pints),
            "qt": .volume(.quarts), "quart": .volume(.quarts), "quarts": .volume(.quarts),
        ]

        // MARK: Currency (bundled offline rates — never touches the network)

        private func evaluateCurrency(_ query: String) -> Result? {
            guard let (lhsRaw, rhsRaw) = Engine.splitConversion(query),
                  let (amount, fromToken) = Engine.parseAmount(lhsRaw),
                  let fromCode = Engine.resolveCode(fromToken),
                  let toCode = Engine.resolveCode(rhsRaw.trimmingCharacters(in: .whitespaces)),
                  let fromRate = rates.rate(for: fromCode),
                  let toRate = rates.rate(for: toCode) else { return nil }
            let converted = (amount / fromRate) * toRate
            return Result(formatCurrency(converted, code: toCode))
        }

        private static func parseAmount(_ lhs: String) -> (amount: Double, token: String)? {
            let trimmed = lhs.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let first = trimmed.first, currencyAliases[String(first)] != nil {
                guard let amount = Double(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) else { return nil }
                return (amount, String(first))
            }
            let numberPart = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
            guard let amount = Double(numberPart) else { return nil }
            return (amount, trimmed.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces))
        }

        private static func resolveCode(_ token: String) -> String? {
            if let code = currencyAliases[token.lowercased()] { return code }
            let upper = token.uppercased()
            return upper.count == 3 ? upper : nil
        }

        private static let currencyAliases: [String: String] = [
            "us": "USD", "usa": "USD", "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD", "$": "USD",
            "euro": "EUR", "euros": "EUR", "€": "EUR",
            "pound": "GBP", "pounds": "GBP", "quid": "GBP", "sterling": "GBP", "£": "GBP",
            "yen": "JPY", "¥": "JPY",
            "yuan": "CNY", "rmb": "CNY", "renminbi": "CNY",
            "rupee": "INR", "rupees": "INR", "₹": "INR",
            "peso": "MXN", "pesos": "MXN",
            "real": "BRL", "reais": "BRL", "r$": "BRL",
            "rand": "ZAR",
            "won": "KRW", "₩": "KRW",
            "ruble": "RUB", "rubles": "RUB", "rouble": "RUB", "₽": "RUB",
            "baht": "THB", "฿": "THB",
            "shekel": "ILS", "shekels": "ILS", "₪": "ILS",
            "forint": "HUF",
            "zloty": "PLN", "zł": "PLN",
            "ringgit": "MYR",
            "rupiah": "IDR",
            "dirham": "AED", "dirhams": "AED",
            "riyal": "SAR", "rial": "SAR",
            "franc": "CHF", "francs": "CHF",
            "₱": "PHP",
            "c$": "CAD", "a$": "AUD", "hk$": "HKD", "nz$": "NZD", "nt$": "TWD", "s$": "SGD",
        ]

        private func formatCurrency(_ value: Double, code: String) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.locale = locale
            return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
        }

        // MARK: Arithmetic (hand-written parser — no NSExpression injection risk)

        private static func evaluateArithmetic(_ query: String) -> Result? {
            let literal = query.hasSuffix("=") ? String(query.dropLast()) : query
            guard !literal.isEmpty else { return nil }
            let normalized = literal
                .replacingOccurrences(of: "x", with: "*")
                .replacingOccurrences(of: "X", with: "*")
                .replacingOccurrences(of: "×", with: "*")
                .replacingOccurrences(of: "÷", with: "/")
            var parser = ArithmeticParser(normalized)
            guard let value = parser.parse(), parser.usedOperator, value.isFinite,
                  let resultText = formatNumber(value) else { return nil }
            return Result(preview: "= \(resultText)", insertion: resultText)
        }

        /// Integers print without a point; others print up to 10 significant digits.
        static func formatNumber(_ value: Double) -> String? {
            guard value.isFinite else { return nil }
            if value == value.rounded(), value.magnitude < 1e15 { return String(Int64(value)) }
            return String(format: "%.10g", value)
        }

        /// Splits a conversion query (`<value><from> <sep> <to>`) on `->`, `→`, or
        /// ` to `. Shared by the unit and currency families.
        private static func splitConversion(_ query: String) -> (left: String, right: String)? {
            for token in ["->", "→"] where query.contains(token) {
                if let range = query.range(of: token) {
                    return (String(query[..<range.lowerBound]), String(query[range.upperBound...]))
                }
            }
            if let range = query.range(of: " to ", options: [.caseInsensitive]) {
                return (String(query[..<range.lowerBound]), String(query[range.upperBound...]))
            }
            return nil
        }

        private struct ArithmeticParser {
            private let characters: [Character]
            private var index = 0
            private(set) var usedOperator = false
            private var valid = true

            init(_ string: String) { characters = Array(string.filter { !$0.isWhitespace }) }

            mutating func parse() -> Double? {
                let value = parseExpression()
                guard valid, index == characters.count else { return nil }
                return value
            }

            private mutating func parseExpression() -> Double {
                var value = parseTerm()
                while let op = peek(), op == "+" || op == "-" {
                    advance(); usedOperator = true
                    let rhs = parseTerm()
                    value = op == "+" ? value + rhs : value - rhs
                }
                return value
            }

            private mutating func parseTerm() -> Double {
                var value = parsePower()
                while let op = peek(), op == "*" || op == "/" {
                    advance(); usedOperator = true
                    let rhs = parsePower()
                    if op == "/" {
                        if rhs == 0 { valid = false; return 0 }
                        value /= rhs
                    } else {
                        value *= rhs
                    }
                }
                return value
            }

            private mutating func parsePower() -> Double {
                let base = parseUnary()
                if peek() == "^" {
                    advance(); usedOperator = true
                    return pow(base, parsePower())   // right associative
                }
                return base
            }

            private mutating func parseUnary() -> Double {
                if peek() == "-" { advance(); return -parsePostfix() }
                if peek() == "+" { advance(); return parsePostfix() }
                return parsePostfix()
            }

            private mutating func parsePostfix() -> Double {
                var value = parsePrimary()
                while peek() == "%" { advance(); usedOperator = true; value /= 100 }
                return value
            }

            private mutating func parsePrimary() -> Double {
                if peek() == "(" {
                    advance()
                    let value = parseExpression()
                    if peek() == ")" { advance() } else { valid = false }
                    return value
                }
                return parseNumber()
            }

            private mutating func parseNumber() -> Double {
                var digits = ""
                while let character = peek(), character.isNumber || character == "." {
                    digits.append(character); advance()
                }
                guard let value = Double(digits) else { valid = false; return 0 }
                return value
            }

            private func peek() -> Character? { index < characters.count ? characters[index] : nil }
            private mutating func advance() { index += 1 }
        }
    }

    /// Bundled, offline, approximate exchange rates (units per USD). Never reaches
    /// the network — in keeping with LokalBot's strictly-local posture.
    struct CurrencyRateTable {
        let asOf: String
        private let ratesPerUSD: [String: Double]

        init(asOf: String, ratesPerUSD: [String: Double]) {
            self.asOf = asOf
            self.ratesPerUSD = ratesPerUSD
        }

        func rate(for code: String) -> Double? { ratesPerUSD[code.uppercased()] }

        static let bundled = CurrencyRateTable(
            asOf: "2026-06",
            ratesPerUSD: [
                "USD": 1.0, "EUR": 0.92, "GBP": 0.79, "JPY": 151.0, "CAD": 1.36, "AUD": 1.51,
                "CHF": 0.90, "CNY": 7.24, "INR": 83.4, "MXN": 17.1, "BRL": 5.05, "ZAR": 18.6,
                "KRW": 1360.0, "SGD": 1.35, "HKD": 7.82, "NZD": 1.63, "SEK": 10.5, "NOK": 10.7,
                "DKK": 6.87, "PLN": 3.95, "TRY": 32.1, "RUB": 90.0, "AED": 3.67, "SAR": 3.75,
                "THB": 36.5, "IDR": 15800.0, "MYR": 4.70, "PHP": 56.5, "CZK": 23.2, "HUF": 360.0,
                "ILS": 3.70, "TWD": 32.3,
            ]
        )
    }
}
