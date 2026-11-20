import CryptoKit
import Foundation

struct HuggingFaceAPIClient {

    enum APIError: LocalizedError {
        case invalidURL
        case rateLimited
        case http(status: Int)
        case decoding(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Couldn't build the HuggingFace request URL."
            case .rateLimited:
                return "HuggingFace is rate-limiting requests — wait a moment and try again."
            case .http(let status):
                return "HuggingFace returned an unexpected response (HTTP \(status))."
            case .decoding:
                return "Couldn't read HuggingFace's response."
            case .transport(let error):
                return error.localizedDescription
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = HuggingFaceAPIClient.defaultSession()) {
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func searchModels(query: String, limit: Int = 20) async throws -> [HFModelSummary] {
        guard var components = URLComponents(string: "https://huggingface.co/api/models") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        return try await fetch([HFModelSummary].self, from: url)
    }

    func files(modelID: String) async throws -> [HFFile] {
        guard Self.validModelID(modelID) else { throw APIError.invalidURL }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(modelID)"
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components.url else { throw APIError.invalidURL }

        let record = try await fetch(ModelRecord.self, from: url)
        return record.siblings
            .filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
            .map {
                HFFile(
                    id: $0.rfilename,
                    modelID: modelID,
                    sizeBytes: $0.lfs?.size ?? $0.size,
                    revision: record.sha ?? "main",
                    sha256: Self.normalizedSHA256($0.lfs?.sha256 ?? $0.lfs?.oid))
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw APIError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private static let userAgent = AppIdentifiers.bundleID

    private static func validModelID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    private static func normalizedSHA256(_ oid: String?) -> String? {
        guard var oid = oid?.lowercased() else { return nil }
        if oid.hasPrefix("sha256:") { oid.removeFirst("sha256:".count) }
        guard oid.count == 64, oid.allSatisfy({ $0.isHexDigit }) else { return nil }
        return oid
    }

    private struct ModelRecord: Decodable {
        let sha: String?
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int?
            let lfs: LFS?
        }

        struct LFS: Decodable {
            let sha256: String?
            let oid: String?
            let size: Int?
        }
    }
}

struct HFModelSummary: Decodable, Identifiable, Hashable {
    let id: String
    let downloads: Int
    let likes: Int

    init(id: String, downloads: Int, likes: Int) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, downloads, likes
    }
}

struct HFFile: Identifiable, Hashable {
    let id: String
    let modelID: String
    let sizeBytes: Int?
    let revision: String
    let sha256: String?

    init(id: String, modelID: String, sizeBytes: Int?,
         revision: String = "main", sha256: String? = nil) {
        self.id = id
        self.modelID = modelID
        self.sizeBytes = sizeBytes
        self.revision = revision
        self.sha256 = sha256
    }

    var downloadURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(modelID)/resolve/\(revision)/\(id)"
        if let sha256 { components.fragment = "sha256=\(sha256)" }
        return components.url ?? URL(string: "https://huggingface.co")!
    }

    var fileName: String {
        let leaf = (id as NSString).lastPathComponent
            .map { character -> Character in
                character.isLetter || character.isNumber || "-_.".contains(character)
                    ? character : "_"
            }
        let digest = SHA256.hash(data: Data("\(modelID)/\(id)".utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        return "hf-\(digest)-\(String(leaf).suffix(180))"
    }

    var sizeLabel: String? {
        guard let sizeBytes else { return nil }
        return Int64(sizeBytes).formatted(.byteCount(style: .file))
    }
}
