import Foundation

struct PiJSONLFrameSplitter {
    static let defaultMaximumFrameBytes = 4 * 1_024 * 1_024

    private var buffer = Data()
    private var discardingOversizedFrame = false
    let maximumFrameBytes: Int

    init(maximumFrameBytes: Int = Self.defaultMaximumFrameBytes) {
        self.maximumFrameBytes = max(1_024, maximumFrameBytes)
    }

    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        if discardingOversizedFrame {
            guard let lf = buffer.firstIndex(of: 0x0A) else {
                buffer.removeAll(keepingCapacity: true)
                return []
            }
            buffer.removeSubrange(buffer.startIndex...lf)
            discardingOversizedFrame = false
        }
        while let lf = buffer.firstIndex(of: 0x0A) {
            var record = buffer[buffer.startIndex..<lf]
            if record.last == 0x0D { record = record.dropLast() }
            if record.count > maximumFrameBytes {
                lines.append(Self.oversizedFrameError)
            } else if let line = String(data: record, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            } else if !record.isEmpty {
                lines.append(Self.invalidUTF8FrameError)
            }
            buffer.removeSubrange(buffer.startIndex...lf)
        }
        if buffer.count > maximumFrameBytes {
            buffer.removeAll(keepingCapacity: true)
            discardingOversizedFrame = true
            lines.append(Self.oversizedFrameError)
        }
        return lines
    }

    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        guard !discardingOversizedFrame else {
            discardingOversizedFrame = false
            return nil
        }
        guard buffer.count <= maximumFrameBytes else { return Self.oversizedFrameError }
        guard !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
              !line.isEmpty else {
            return buffer.isEmpty ? nil : Self.invalidUTF8FrameError
        }
        return line
    }

    private static let oversizedFrameError =
        #"{"type":"extension_error","error":"pi RPC frame exceeded the 4 MiB safety limit"}"#
    private static let invalidUTF8FrameError =
        #"{"type":"extension_error","error":"pi RPC frame was not valid UTF-8"}"#
}
