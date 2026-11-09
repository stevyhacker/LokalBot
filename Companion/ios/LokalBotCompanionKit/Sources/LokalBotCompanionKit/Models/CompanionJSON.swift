import Foundation

/// JSON coding for companion records: camelCase keys, ISO 8601 instants with
/// milliseconds (`2026-10-30T09:30:00.000Z`), unknown keys ignored.
public enum CompanionJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseInstant(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected an ISO 8601 instant, got \(text)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatInstant(date))
        }
        return encoder
    }

    public static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder().decode(type, from: Data(json.utf8))
    }

    public static func encodeString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    public static func parseInstant(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Self.fractional) { return date }
        return try? Date(text, strategy: Self.whole)
    }

    public static func formatInstant(_ date: Date) -> String {
        date.formatted(Self.fractional)
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
}
