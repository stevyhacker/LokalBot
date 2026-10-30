import DigUpKit
import Foundation

/// DigUpKit's `Embedder`, served by the media llama-server: EmbeddingGemma 2
/// with its image and audio projector (`LlamaServer.mediaEmbedder`). DigUp's
/// indexer calls it from its own thread, one call at a time, and waits, so the
/// requests here are synchronous.
///
/// Inputs travel the way the 30 October parity run qualified them
/// (Benchmarks/EmbeddingGemma2/2026-10-30-media-embedder): texts as given,
/// images as PNG sized for their budget (`FileImageSizing`), audio as WAV, each
/// medium as a typed content part. That run reproduced DigUp's reference
/// vectors at cosine ≥ 0.9997.
final class FileMediaEmbedder: Embedder {
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
            let made = try post(Self.requestBody(inputs: slice))
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

    /// The server answered, but not with vectors for this input (HTTP 4xx).
    private struct RejectedInput: Error, CustomStringConvertible {
        let description: String
    }

    private func post(_ body: [String: Any]) throws -> [[Float]] {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/embeddings"))
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

        let (data, http) = try result.get()
        switch http.statusCode {
        case 200:
            return try Self.vectors(fromResponse: data)
        case 400..<500 where http.statusCode != 401 && http.statusCode != 408 && http.statusCode != 429:
            throw RejectedInput(description: "HTTP \(http.statusCode): "
                + String(decoding: data.prefix(200), as: UTF8.self))
        default:
            throw WorkerError.died("HTTP \(http.statusCode) from the media embedder")
        }
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
