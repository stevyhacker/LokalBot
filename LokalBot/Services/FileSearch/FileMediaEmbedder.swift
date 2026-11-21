import DigUpKit
import Foundation

final class FileMediaEmbedder: Embedder, @unchecked Sendable {
    static let vectorVersion = 1
    static let workerInfo = WorkerInfo(
        model: "google/embeddinggemma-2",
        revision: "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
        runtime: "lokalbot-llama-server-vectors\(vectorVersion)",
        dtype: "text-q8_0+mmproj-q8_0", dim: 768, textOnly: false, loadSeconds: nil)
    static let textsPerRequest = 16
    static let maxInputTokens = 2_048
    static let requestTimeout: TimeInterval = 120

    struct Endpoint: Sendable {
        let baseURL: URL
        let token: String
    }

    let info = FileMediaEmbedder.workerInfo
    private let endpoint: Endpoint
    private let session: URLSession

    init(endpoint: Endpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.textsPerRequest) {
            let slice = Array(texts[start..<min(start + Self.textsPerRequest, texts.count)])
            let made = try post(Self.requestBody(inputs: try slice.map(fitted)))
            guard made.count == slice.count else {
                throw WorkerError.died("the media embedder returned \(made.count) of \(slice.count) vectors")
            }
            vectors += made
        }
        return vectors
    }

    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        try paths.map { path in
            try embedding {
                let png = try FileImageSizing.png(ofImageAt: URL(fileURLWithPath: path), budget: budget)
                return Self.imagePart(png: png)
            }
        }
    }

    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        try paths.map { path in
            try embedding { Self.audioPart(wav: try Data(contentsOf: URL(fileURLWithPath: path))) }
        }
    }

    func close() {}

    func embedImage(png: Data) throws -> [Float] {
        guard let vector = try post(Self.requestBody(inputs: [Self.imagePart(png: png)])).first else {
            throw WorkerError.died("the media embedder returned no vector")
        }
        return vector
    }

    private func embedding(_ makeInput: () throws -> [String: Any]) throws -> Embedding {
        let input: [String: Any]
        do {
            input = try makeInput()
        } catch {
            return Embedding(vector: nil, error: String("\(error)".prefix(300)))
        }
        do {
            return Embedding(vector: try post(Self.requestBody(inputs: [input])).first, error: nil)
        } catch let error as RejectedInput {
            return Embedding(vector: nil, error: error.description)
        }
    }

    private func fitted(_ text: String) throws -> Any {
        guard text.utf8.count + 2 > Self.maxInputTokens else { return text }
        let tokens = try tokens(of: text)
        guard tokens.count > Self.maxInputTokens, let eos = tokens.last else { return text }
        return Array(tokens.prefix(Self.maxInputTokens - 1)) + [eos]
    }

    private func tokens(of text: String) throws -> [Int] {
        let (data, http) = try send("tokenize", ["content": text, "add_special": true])
        guard http.statusCode == 200 else {
            throw WorkerError.died("HTTP \(http.statusCode) from the media embedder's tokenizer")
        }
        guard let tokens = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [Int]
        else { throw WorkerError.died("unexpected /tokenize payload") }
        return tokens
    }

    private struct RejectedInput: Error, CustomStringConvertible {
        let description: String
    }

    private func post(_ body: [String: Any]) throws -> [[Float]] {
        let (data, http) = try send("v1/embeddings", body)
        switch http.statusCode {
        case 200:
            return try Self.vectors(fromResponse: data)
        case 400..<500 where http.statusCode != 401 && http.statusCode != 408 && http.statusCode != 429,
             500 where Self.isTooLarge(data):
            throw RejectedInput(description: "HTTP \(http.statusCode): "
                + String(decoding: data.prefix(200), as: UTF8.self))
        default:
            throw WorkerError.died("HTTP \(http.statusCode) from the media embedder")
        }
    }

    static func isTooLarge(_ data: Data) -> Bool {
        String(decoding: data.prefix(300), as: UTF8.self).contains("too large to process")
    }

    private func send(_ path: String, _ body: [String: Any]) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(WorkerError.died("no response"))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(WorkerError.died(error.localizedDescription))
            } else if let data, let http = response as? HTTPURLResponse {
                result = .success((data, http))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }

    static func requestBody(inputs: [Any]) -> [String: Any] {
        ["input": inputs, "model": EmbeddingIndex.modelID, "cache_prompt": false]
    }

    static func imagePart(png: Data) -> [String: Any] {
        ["content": [["type": "image_url",
                      "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]]]]
    }

    static func audioPart(wav: Data) -> [String: Any] {
        ["content": [["type": "input_audio",
                      "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]]]
    }

    static func vectors(fromResponse data: Data) throws -> [[Float]] {
        do {
            return try EmbeddingIndex.embeddingVectors(fromResponse: data)
        } catch {
            throw WorkerError.died("unexpected /v1/embeddings payload")
        }
    }
}
