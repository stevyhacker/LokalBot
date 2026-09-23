import Foundation

/// The exact GA CoreML files used in the AMI evaluation. FluidAudio 0.17.1's
/// default Nemotron downloader follows `main`, so use the app's integrity gate
/// and an immutable, separate cache rather than trusting its version marker.
enum NemotronDiarizationModels {
    static let repository = "FluidInference/nemotron-3-diarization-coreml"
    static let revision = "53445f72d5735e33406ccce7b92116bce7ab1ab7"

    struct Artifact: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String

        var remoteURL: URL {
            let remotePath = path.hasPrefix("Nemotron3Diarizer_") ? "monolithic/\(path)" : path
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(remotePath)")!
        }
    }

    static let artifacts: [Artifact] = [
        .init(path: "learnable_sil_emb.bin", bytes: 2048,
              sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/analytics/coremldata.bin", bytes: 243,
              sha256: "013d4b137d9b21ca20d0877dc9c848de12ff2cb98957471d9adcd7e90677cf7d"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/coremldata.bin", bytes: 758,
              sha256: "c20dbb6f4b3ca4aca043b8d04c73a3bc8c112f001c5318ce9c2de1e7dafc3fa7"),
        .init(path: "Nemotron3Diarizer_offline.mlmodelc/model.mil", bytes: 507718,
              sha256: "a29018338c9d07a886e37549b0171cb9379dee21be5934a48c23317582eded88"),
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
            let stashed = try await ParallelRangeDownloader.download(from: artifact.remoteURL, session: .shared) { _ in }
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
