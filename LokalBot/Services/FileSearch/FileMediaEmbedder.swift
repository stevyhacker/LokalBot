import DigUpKit
import Foundation

/// DigUpKit's `Embedder`, served by the media llama-server: EmbeddingGemma 2
/// with its image and audio projector (`LlamaServer.mediaEmbedder`). DigUp's
/// indexer calls it from its own thread, one call at a time, and waits, so the
/// requests here are synchronous.
///
/// Inputs travel the way the 30 October parity run qualified them
/// (Benchmarks/EmbeddingGemma2/2026-10-30-media-embedder): texts as given
/// (cut to one batch when longer, `fitted`), images as PNG sized for their budget (`FileImageSizing`), audio as WAV, each
/// medium as a typed content part. That run reproduced DigUp's reference
/// vectors at cosine ≥ 0.9997.
/// Immutable after init (an endpoint and a URLSession), so it can cross threads.
final class FileMediaEmbedder: Embedder, @unchecked Sendable {
    /// Which vectors this pipeline makes: the model files, the llama.cpp build,
    /// the image sizing and the request shapes. Bump it when any of them changes
    /// the vectors (the reference-vector check says when); every file index then
    /// embeds again.
    static let vectorVersion = 1
    static let workerInfo = WorkerInfo(
        model: "google/embeddinggemma-2",
        revision: "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
        runtime: "lokalbot-llama-server-vectors\(vectorVersion)",
        dtype: "text-q8_0+mmproj-q8_0", dim: 768, textOnly: false, loadSeconds: nil)
    /// Texts per request. One request is one llama-server batch; this keeps a
    /// long document from becoming a single multi-minute request.
    static let textsPerRequest = 16
    /// The most tokens one input may have, `<bos>` and `<eos>` included: the
    /// server's batch (`-ub 2048`; an embedding must fit in one), and where
    /// DigUp's own embedder cuts a text.
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

    /// One picture already sized and encoded (`FileImageSizing.png(of:budget:)`),
    /// for screen captures that are decrypted in memory. Throws `WorkerError`
    /// when the server can't answer and any other error when it rejects the
    /// picture.
    func embedImage(png: Data) throws -> [Float] {
        guard let vector = try post(Self.requestBody(inputs: [Self.imagePart(png: png)])).first else {
            throw WorkerError.died("the media embedder returned no vector")
        }
        return vector
    }

    // MARK: - Requests

    /// One file's vector, or why it has none. A file the server cannot read
    /// (a broken picture) must not sink its neighbours. A server that cannot
    /// answer throws `WorkerError`: DigUp's indexer then stops the pass and
    /// leaves the files pending for the next one, where any other error would
    /// mark the whole batch failed for good.
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

    /// A text as it is sent: itself when it fits one batch, otherwise its
    /// tokens cut the way DigUp's embedder (and transformers) cuts, the first
    /// `maxInputTokens - 1` and `<eos>`. llama-server refuses a longer input
    /// with HTTP 500 instead of cutting it, and a dense page of Cyrillic or
    /// figures passes 2,048 tokens well within the 4,000 characters DigUp
    /// sends. No token is shorter than a byte, so shorter texts skip the
    /// tokenizer; tokens and text make the same vector.
    private func fitted(_ text: String) throws -> Any {
        guard text.utf8.count + 2 > Self.maxInputTokens else { return text }
        let tokens = try tokens(of: text)
        guard tokens.count > Self.maxInputTokens, let eos = tokens.last else { return text }
        return Array(tokens.prefix(Self.maxInputTokens - 1)) + [eos]
    }

    /// The server's tokens for a text, with the `<bos>` and `<eos>` it embeds.
    private func tokens(of text: String) throws -> [Int] {
        let (data, http) = try send("tokenize", ["content": text, "add_special": true])
        guard http.statusCode == 200 else {
            throw WorkerError.died("HTTP \(http.statusCode) from the media embedder's tokenizer")
        }
        guard let tokens = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tokens"] as? [Int]
        else { throw WorkerError.died("unexpected /tokenize payload") }
        return tokens
    }

    /// The server answered, but not with vectors for this input (HTTP 4xx, or
    /// an input too large for its batch).
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

    /// llama-server's answer to an input longer than its batch: HTTP 500,
    /// though the server is fine. Texts are cut to fit first (`fitted`); a
    /// picture or recording that still doesn't fit fails alone instead of
    /// stopping every pass at the same file.
    static func isTooLarge(_ data: Data) -> Bool {
        String(decoding: data.prefix(300), as: UTF8.self).contains("too large to process")
    }

    /// One synchronous request to the server.
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

    // MARK: - Request and response shapes

    static func requestBody(inputs: [Any]) -> [String: Any] {
        ["input": inputs, "model": EmbeddingIndex.modelID, "cache_prompt": false]
    }

    /// A typed content part nested one level inside the input item; a flat
    /// `input: [{type: image_url}]` is rejected (ggml-org/llama.cpp#30082).
    static func imagePart(png: Data) -> [String: Any] {
        ["content": [["type": "image_url",
                      "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]]]]
    }

    static func audioPart(wav: Data) -> [String: Any] {
        ["content": [["type": "input_audio",
                      "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]]]]
    }

    /// L2-normalized vectors in input order (rows are ordered by `index`).
    static func vectors(fromResponse data: Data) throws -> [[Float]] {
        do {
            return try EmbeddingIndex.embeddingVectors(fromResponse: data)
        } catch {
            throw WorkerError.died("unexpected /v1/embeddings payload")
        }
    }
}
