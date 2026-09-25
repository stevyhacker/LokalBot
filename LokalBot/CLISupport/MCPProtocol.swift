import Foundation

/// Minimal JSON model for JSON-RPC params, results, and tool schemas.
/// Codable so a whole response tree encodes in one pass; the literal
/// conformances keep dispatcher code and tool schemas readable.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self,
           abs(value) <= 9_007_199_254_740_991 {
            // JSON numbers use Double here. Reject the range where decoding
            // can silently change an integer's identity, and never trap.
            return Int(exactly: value)
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(nilLiteral: ()) { self = .null }
}

enum MCPTransportLimits {
    static let maximumRecordBytes = 1_048_576
}

/// Incremental newline-delimited stdin reader for the MCP helper. Its buffer
/// never grows with an unterminated record: once the byte limit is crossed it
/// reports one rejection and discards bytes until LF/EOF without constructing
/// an oversized `String`.
struct MCPStdioLineReader {
    enum Record: Equatable {
        case line(String)
        case oversized
        case end
    }

    private let input: FileHandle
    private let maximumRecordBytes: Int
    private let chunkBytes: Int
    private var pending = Data()
    private var reachedEOF = false
    private var discardingOversizedRecord = false

    init(
        input: FileHandle = .standardInput,
        maximumRecordBytes: Int = MCPTransportLimits.maximumRecordBytes,
        chunkBytes: Int = 64 * 1_024
    ) {
        self.input = input
        self.maximumRecordBytes = max(1, maximumRecordBytes)
        self.chunkBytes = max(1, chunkBytes)
    }

    mutating func next() throws -> Record {
        while true {
            if discardingOversizedRecord {
                if let newline = pending.firstIndex(of: 0x0A) {
                    pending.removeSubrange(pending.startIndex...newline)
                    discardingOversizedRecord = false
                    continue
                }
                pending.removeAll(keepingCapacity: true)
                if reachedEOF {
                    discardingOversizedRecord = false
                    return .end
                }
            } else {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let byteCount = pending.distance(from: pending.startIndex, to: newline)
                    guard byteCount <= maximumRecordBytes else {
                        pending.removeSubrange(pending.startIndex...newline)
                        return .oversized
                    }
                    var data = pending.prefix(upTo: newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    if data.last == 0x0D { data.removeLast() }
                    return .line(String(decoding: data, as: UTF8.self))
                }

                if pending.count > maximumRecordBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedRecord = true
                    return .oversized
                }

                if reachedEOF {
                    guard !pending.isEmpty else { return .end }
                    var data = pending
                    pending.removeAll(keepingCapacity: true)
                    if data.last == 0x0D { data.removeLast() }
                    return .line(String(decoding: data, as: UTF8.self))
                }
            }

            let chunk = try input.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                pending.append(chunk)
            }
        }
    }
}

/// One decoded JSON-RPC 2.0 message from an MCP client.
struct MCPRequest: Equatable {
    static let maximumLineBytes = MCPTransportLimits.maximumRecordBytes
    enum RequestID: Equatable {
        case number(Int)
        case string(String)

        var json: JSONValue {
            switch self {
            case .number(let value): .number(Double(value))
            case .string(let value): .string(value)
            }
        }
    }

    /// nil means a notification and the server must not answer it.
    var id: RequestID?
    var method: String
    var params: JSONValue?

    enum ParseOutcome: Equatable {
        case request(MCPRequest)
        case failure(code: Int, message: String, id: RequestID?)
    }

    static func parse(_ line: String) -> ParseOutcome {
        guard line.utf8.count <= maximumLineBytes else {
            return .failure(code: -32600, message: "Request exceeds the 1 MiB limit", id: nil)
        }
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let object = raw.objectValue else {
            return .failure(code: -32700, message: "Parse error", id: nil)
        }

        let id: RequestID?
        switch object["id"] {
        case .some(.number(let value)):
            guard let integer = JSONValue.number(value).intValue else {
                return .failure(code: -32600, message: "Invalid numeric request id", id: nil)
            }
            id = .number(integer)
        case .some(.string(let value)): id = .string(value)
        default: id = nil
        }

        guard case .some(.string("2.0")) = object["jsonrpc"],
              case .some(.string(let method)) = object["method"] else {
            return .failure(code: -32600, message: "Invalid Request", id: id)
        }
        return .request(MCPRequest(id: id, method: method, params: object["params"]))
    }
}

/// Encodes newline-delimited JSON-RPC 2.0 responses with deterministic keys.
enum MCPResponse {
    static func success(id: MCPRequest.RequestID?, result: JSONValue) -> String {
        encode(.object([
            "jsonrpc": "2.0",
            "id": id?.json ?? .null,
            "result": result,
        ]))
    }

    static func failure(id: MCPRequest.RequestID?, code: Int, message: String) -> String {
        encode(.object([
            "jsonrpc": "2.0",
            "id": id?.json ?? .null,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ]))
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
