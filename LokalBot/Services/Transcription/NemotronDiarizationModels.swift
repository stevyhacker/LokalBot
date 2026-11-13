import Foundation

/// The v2 CoreML export fixes ANE compilation on M3 while retaining the GA
/// checkpoint weights. Keep an immutable, integrity-checked cache rather than
/// following the upstream downloader's mutable `main` revision.
enum NemotronDiarizationModels {
    static let repository = "FluidInference/nemotron-3-diarization-coreml"
    static let revision = "25a90f97f254428d4b30374b76af9c74fdee8327"

    struct Artifact: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String

        var remoteURL: URL {
            let remotePath = path.hasPrefix("Nemotron3Diarizer_") ? "monolithic/v2/\(path)" : path
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remotePath)")!
        }
    }

    static let artifacts: [Artifact] = [
        .init(path: "learnable_sil_emb.bin", bytes: 2048,
              sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "491594df92282a4f2cef65e96d236e210a5c4627063e37e822ec858aaaad416d"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/coremldata.bin", bytes: 758,
              sha256: "8b790c919c65744648c17290a26d3371e0e55db655310e7f8445080757b0bf08"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/model.mil", bytes: 505274,
              sha256: "ea5673d9e9ec785e7c8fb628acd82f9f86214c46b6584eaacdb6faddcb3f0277"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/weights/weight.bin", bytes: 198654080,
              sha256: "bab76e5f190d0e4a4e174e7fcb1e9beea58c6b2be56e665e2cac8fba6d10f7f1"),
    ]

    static func prepare(appSupport: URL = AppDirectories.applicationSupport) async throws -> URL {
        let directory = appSupport.appendingPathComponent("Models/NemotronDiarization/\(revision)")
        for artifact in artifacts {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(artifact.path)
            if await DownloadIntegrity.verifiedExisting(at: destination, expectedBytes: artifact.bytes,
                                                       expectedSHA256: artifact.sha256) { continue }
            let stashed = try await ModelDownloadRouting.download(
                from: artifact.remoteURL, session: .shared,
                expectedSHA256: artifact.sha256, expectedBytes: artifact.bytes) { _ in }
            defer { DownloadIntegrity.removeFileAndMarker(at: stashed) }
            try Task.checkCancellation()
            try await DownloadIntegrity.verifyDownloaded(at: stashed, expectedBytes: artifact.bytes,
                                                         expectedSHA256: artifact.sha256)
            try DownloadFileRescuer.install(stashed: stashed, to: destination)
            try DownloadIntegrity.markInstalled(at: destination, expectedBytes: artifact.bytes, expectedSHA256: artifact.sha256)
        }
        try Task.checkCancellation()
        return directory
    }
}
