import Foundation

/// Reads only complete top-level array records. It never closes a partial
/// object/string or invents missing fields, and handles escaped quotes/braces.
enum CompleteJSONRecords {
    struct Result {
        var arrays: [String: [[String: Any]]] = [:]
        var complete = false
        var malformedRecords = 0
    }

    static func parse(_ text: String, keys: Set<String>) -> Result {
        let text = strippingReasoning(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 262_144 else { return Result() }
        if let json = ChatPrompt.extractJSONObject(text),
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result = Result(complete: keys.allSatisfy { object[$0] is [Any] })
            for key in keys {
                let values = object[key] as? [Any] ?? []
                result.arrays[key] = values.compactMap { $0 as? [String: Any] }
                result.malformedRecords += values.count - (result.arrays[key]?.count ?? 0)
            }
            return result
        }

        // The strict envelope starts with an object, not arbitrary prose.
        let chars = Array(text)
        guard chars.first == "{" else { return Result() }
        var result = Result()
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var stringStart = 0
        var pendingKey: String?
        var arrayKey: String?
        var recordStart: Int?
        for (index, char) in chars.enumerated() {
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" {
                    inString = false
                    if stack == ["{"] {
                        let raw = String(chars[stringStart...index])
                        pendingKey = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8)))
                    }
                }
                continue
            }
            if char == "\"" { inString = true; stringStart = index; continue }
            if char == "{" || char == "[" {
                if char == "[", stack == ["{"] {
                    arrayKey = pendingKey.flatMap { keys.contains($0) ? $0 : nil }
                    pendingKey = nil
                }
                if char == "{", stack == ["{", "["], arrayKey != nil { recordStart = index }
                stack.append(char)
            } else if char == "}" || char == "]" {
                guard stack.last == (char == "}" ? "{" : "[") else { break }
                if char == "}", stack == ["{", "[", "{"], let start = recordStart, let key = arrayKey {
                    let data = Data(String(chars[start...index]).utf8)
                    if let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        result.arrays[key, default: []].append(record)
                    } else { result.malformedRecords += 1 }
                    recordStart = nil
                }
                stack.removeLast()
                if char == "]", stack == ["{"] { arrayKey = nil }
            }
        }
        return result
    }
}
