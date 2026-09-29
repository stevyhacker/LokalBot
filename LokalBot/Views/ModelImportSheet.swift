import SwiftUI

struct ModelImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var hfSearch = HuggingFaceSearchService()
    @State private var hfSelectedModel: String?
    @State private var hfFiles: [HFFile] = []
    let onImport: (ModelCatalog.Entry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a model from Hugging Face").font(.scaled(.headline))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            HStack {
                TextField("Search downloadable models (e.g. Qwen, Llama)…", text: $hfSearch.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await hfSearch.search() } }
                Button("Search") { Task { await hfSearch.search() } }
                    .disabled(hfSearch.query.trimmingCharacters(in: .whitespaces).isEmpty)
                if hfSearch.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            if let error = hfSearch.errorMessage {
                Text(error).font(.scaled(.caption)).foregroundStyle(Brand.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            List {
                ForEach(hfSearch.results) { model in
                    Button {
                        Task {
                            hfSelectedModel = model.id
                            hfFiles = await hfSearch.ggufFiles(for: model.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.id).font(.scaled(.body).weight(.medium))
                                Text("↓ \(model.downloads)   ♥ \(model.likes)")
                                    .font(.scaled(.caption2)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: hfSelectedModel == model.id ? "chevron.down" : "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    if hfSelectedModel == model.id {
                        if hfFiles.isEmpty {
                            Text("No compatible model files in this repository.")
                                .font(.scaled(.caption2)).foregroundStyle(.secondary).padding(.leading, 16)
                        } else {
                            ForEach(hfFiles) { file in
                                HStack(spacing: 8) {
                                    Text(file.fileName).font(.scaled(.caption))
                                    if let size = file.sizeLabel {
                                        Text(size).font(.scaled(.caption2)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Add model") {
                                        let entry = ModelCatalog.Entry(
                                            id: "hf:\(file.modelID)/\(file.id)",
                                            displayName: file.fileName,
                                            fileName: file.fileName,
                                            url: file.downloadURL.absoluteString,
                                            sha256: file.sha256,
                                            sizeBytes: file.sizeBytes.map(Int64.init),
                                            sizeGB: file.sizeBytes.map { Double($0) / 1_000_000_000 } ?? 0,
                                            blurb: "Downloaded from \(file.modelID).",
                                            disablesThinking: false)
                                        onImport(entry)
                                        dismiss()
                                    }
                                    .controlSize(.small)
                                }
                                .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 580, height: 460)
    }

}
