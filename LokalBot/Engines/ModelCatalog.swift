import Foundation

/// Built-in LLM backend, part 1 of 3: the model catalog + on-disk validation.
/// A bundled llama.cpp `llama-server` (Metal) speaks the OpenAI-compatible API
/// on localhost. Users choose and download GGUF models on demand into
/// Application Support. No Ollama / LM Studio required.
///
/// Runtime split (mirrors the lifecycle/prompt/lifecycle separation): catalog
/// here, download orchestration in `ModelDownloadManager.swift`, the server
/// subprocess in `LlamaServer.swift`.
struct ModelCatalog {

    struct Entry: Codable, Identifiable, Hashable {
        let id: String
        let displayName: String
        let fileName: String
        let url: String
        let sha256: String?
        let sizeBytes: Int64?
        let sizeGB: Double
        let blurb: String
        /// Legacy persisted hint from the pre-high-reasoning runtime. Retained
        /// so existing custom-model settings keep decoding; the Main LLM now
        /// applies one explicit reasoning policy at the server/request layer.
        let disablesThinking: Bool

        init(id: String, displayName: String, fileName: String, url: String,
             sha256: String? = nil, sizeBytes: Int64? = nil,
             sizeGB: Double, blurb: String,
             disablesThinking: Bool) {
            self.id = id
            self.displayName = displayName
            self.fileName = fileName
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.sizeGB = sizeGB
            self.blurb = blurb
            self.disablesThinking = disablesThinking
        }

        /// Built-ins store the digest directly. Older custom entries carried it
        /// in the URL fragment, so preserve that migration path as well.
        var expectedSHA256: String? {
            if let digest = Self.normalizedSHA256(sha256) { return digest }
            guard let fragment = URLComponents(string: url)?.fragment,
                  fragment.hasPrefix("sha256=") else { return nil }
            return Self.normalizedSHA256(String(fragment.dropFirst("sha256=".count)))
        }

        /// New entries persist the exact byte count. Entries saved by the
        /// previous build can recover it from the round-trippable decimal GB
        /// value that was originally derived from Hugging Face's byte count.
        var expectedSizeBytes: Int64? {
            if let sizeBytes, sizeBytes > 0 { return sizeBytes }
            guard expectedSHA256 != nil, sizeGB > 0, sizeGB.isFinite else { return nil }
            let recovered = (sizeGB * 1_000_000_000).rounded()
            guard recovered > 0, recovered <= Double(Int64.max) else { return nil }
            return Int64(recovered)
        }

        private static func normalizedSHA256(_ candidate: String?) -> String? {
            guard let digest = candidate?.lowercased(),
                  digest.count == 64,
                  digest.allSatisfy(\.isHexDigit) else { return nil }
            return digest
        }
    }

    static let compactFallbackID = "qwen3.5-0.8b"
    static let recommendedSummarizationID = "qwen3.6-35b-a3b"
    static let recommendedCotypingID = "lfm2.5-1.2b-instruct"
    static let recommendedCotypingLicenseURL = URL(
        string: "https://docs.liquid.ai/lfm/help/model-license")!
    /// Main LLM preselected for every fresh install. Larger models remain
    /// available in Settings → Models for users who prefer maximum quality.
    static let defaultSummarizationID = "qwen3.5-4b"

    /// Ceiling for models offered in the cotyping pickers. Cotyping runs at
    /// keystroke latency; the heavyweight summarization models above this
    /// size are counterproductive there (and still selectable for the Main
    /// LLM, where they belong).
    static let keystrokeScaleMaxGB = 7.0

    /// Models hidden from new cotyping picks. A deny-set rather than an
    /// `Entry` field: `Entry` is Codable and persisted in
    /// `AppSettings.customBuiltInModels`, so its stored shape must not churn.
    /// The 2.6B LFM is an always-reasoning Main LLM candidate, not a
    /// keystroke-latency completion model.
    private static let excludedCotypingIDs: Set<String> = [
        "gemma4-e4b",
        "granite-4.1-3b",
        "lfm2.5-2.6b",
        "ministral-3-3b-instruct-2512",
    ]

    /// Local GGUF catalog, roughly ordered from tiny fallbacks to higher-quality
    /// meeting-summary and cotyping options.
    static let entries: [Entry] = [
        Entry(id: compactFallbackID, displayName: "Qwen 3.5 · 0.8B",
              fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf",
              sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
              sizeBytes: 532_517_120,
              sizeGB: 0.53, blurb: "Tiny downloadable fallback for short meetings and cotyping.",
              disablesThinking: true),
        Entry(id: recommendedCotypingID, displayName: "LFM2.5 1.2B Instruct",
              fileName: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/LFM2.5-1.2B-Instruct-GGUF/resolve/bf1ebe055f24ddd24f3622d933a63b42606773f3/LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
              sha256: "856aeee6d85ac684b1db8dee48795b44fc06731ecda03aee36ece682413a9b9a",
              sizeBytes: 730_895_584,
              sizeGB: 0.73, blurb: "Recommended fast, English-first cotyping model. Under 1 GB.",
              disablesThinking: false),
        Entry(id: "qwen3.5-2b", displayName: "Qwen3.5 2B",
              fileName: "Qwen3.5-2B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf",
              sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
              sizeBytes: 1_280_835_840,
              sizeGB: 1.28, blurb: "Lightweight multilingual cotyping option. Any Apple Silicon Mac.",
              disablesThinking: true),
        Entry(id: "qwen3.5-4b", displayName: "Qwen3.5 4B",
              fileName: "Qwen3.5-4B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf",
              sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
              sizeBytes: 2_740_937_888,
              sizeGB: 2.8, blurb: "Default Think model with balanced local summaries and long context. 16 GB Macs.",
              disablesThinking: true),
        Entry(id: "lfm2.5-2.6b", displayName: "LFM2.5 2.6B Reasoning",
              fileName: "LFM2.5-2.6B-Q4_K_M.gguf",
              url: "https://huggingface.co/LiquidAI/LFM2.5-2.6B-GGUF/resolve/b22e29ebf6249a8c9fcdda36914743e9980595c4/LFM2.5-2.6B-Q4_K_M.gguf",
              sha256: "79fdf00351b46cf26f020aead28d01889886be87c55fa0eb907e6f9b00bfee14",
              sizeBytes: 1_674_454_848,
              sizeGB: 1.67, blurb: "Experimental compact reasoning model for summaries and extraction. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "granite-4.1-3b", displayName: "Granite 4.1 3B (Experimental)",
              fileName: "granite-4.1-3b-Q4_K_M.gguf",
              url: "https://huggingface.co/ibm-granite/granite-4.1-3b-GGUF/resolve/ab4701481089b58a082ef63cc1cee738887293ff/granite-4.1-3b-Q4_K_M.gguf",
              sha256: "662b0626cd58f443baea23559b469df6576a81d349649c59413b36a9fb32eb29",
              sizeBytes: 2_099_501_664,
              sizeGB: 2.10, blurb: "Experimental 3B Think model for summaries, extraction, and JSON. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "ministral-3-3b-instruct-2512",
              displayName: "Ministral 3 3B Instruct (Experimental)",
              fileName: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
              url: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/eb599d408350ea2bb60452cb86be7c7b2fc28227/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
              sha256: "9ed150d4367e68df0ac8e1540f6ddc65b42d0ee26378329d1ecbca60f93fc5f8",
              sizeBytes: 2_147_023_008,
              sizeGB: 2.15, blurb: "Experimental 3B Think model with native JSON and long context. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "gemma4-e4b", displayName: "Gemma 4 E4B (Legacy)",
              fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/0720adb23527c2cd5ea01d1db067cd960327fdac/gemma-4-E4B-it-Q4_K_M.gguf",
              sha256: "519b9793ed6ce0ff530f1b7c96e848e08e49e7af4d57bb97f76215963a54146d",
              sizeBytes: 4_977_169_568,
              sizeGB: 4.98, blurb: "Legacy edge-optimized option. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "gemma4-e4b-q5-xl", displayName: "Gemma 4 · E4B",
              fileName: "gemma-4-E4B-it-UD-Q5_K_XL.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/0720adb23527c2cd5ea01d1db067cd960327fdac/gemma-4-E4B-it-UD-Q5_K_XL.gguf",
              sha256: "5fb55145c335edd0c2e0cdd7505ed1557cd346787449479be65094c6f5b016c6",
              sizeBytes: 6_656_152_736,
              sizeGB: 6.66, blurb: "Higher-capacity cotyping option (Q5 XL quant). 16 GB+ Macs.",
              disablesThinking: false),
        Entry(id: "lfm2.5-8b-a1b", displayName: "LFM2.5 8B (MoE)",
              fileName: "LFM2.5-8B-A1B-Q4_K_M.gguf",
              url: "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/dfd5fdcad7a1c0d31473fb4ca443b8befbacddf0/LFM2.5-8B-A1B-Q4_K_M.gguf",
              sha256: "4923ec14f06b968b74d663e5949867d2d9c3bf13a20b8be1a9f9af39989b2bb0",
              sizeBytes: 5_155_564_768,
              sizeGB: 5.16, blurb: "Fast meeting summaries; ~1B active. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: recommendedSummarizationID, displayName: "Qwen 3.6 · 35B-A3B",
              fileName: "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              sha256: "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3",
              sizeBytes: 17_730_509_792,
              sizeGB: 17.73, blurb: "Higher-quality long-meeting option; ~3B active. 32 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "qwen3.6-27b", displayName: "Qwen3.6 27B",
              fileName: "Qwen3.6-27B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/82d411acf4a06cfb8d9b073a5211bf410bfc29bf/Qwen3.6-27B-Q4_K_M.gguf",
              sha256: "5ed60d0af4650a854b1755bd392f9aef4872643dc25a254bc68043fa638392a0",
              sizeBytes: 16_817_244_384,
              sizeGB: 16.8, blurb: "Maximum-quality dense summaries. Best on 32 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "gemma4-12b", displayName: "Gemma 4 12B",
              fileName: "gemma-4-12b-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-12B-it-GGUF/resolve/d997c805aafe035a8024f961c6e1afd6b30d79a5/gemma-4-12b-it-Q4_K_M.gguf",
              sha256: "43fec98c5102b1c446b4ddd0a9439f1db3a2e1f2e0b8cd143ce1ea619a9403d6",
              sizeBytes: 7_121_860_000,
              sizeGB: 7.5, blurb: "Multimodal-family summary option for screenshot/slide workflows.",
              disablesThinking: false),
    ]

    static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    static func selectableEntries(custom: [Entry]) -> [Entry] {
        entries + custom.filter { customEntry in
            !entries.contains { $0.id == customEntry.id || $0.fileName == customEntry.fileName }
        }
    }

    /// The cotyping pickers' catalog: keystroke-scale built-ins plus every
    /// custom entry, always keeping the currently selected model visible so
    /// an existing choice never silently disappears from its own picker.
    static func keystrokeScaleEntries(custom: [Entry],
                                      keeping selectedID: String? = nil) -> [Entry] {
        let customIDs = Set(custom.map(\.id))
        return selectableEntries(custom: custom).filter { entry in
            if entry.id == selectedID { return true }
            if customIDs.contains(entry.id) { return true }
            return entry.sizeGB < keystrokeScaleMaxGB
                && !excludedCotypingIDs.contains(entry.id)
        }
    }

    static func entry(id: String, custom: [Entry]) -> Entry? {
        selectableEntries(custom: custom).first { $0.id == id }
    }

    /// Downloads live in <storage>/models/.
    static func localURL(for entry: Entry, storage: StorageManager) -> URL? {
        let downloaded = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
        if ModelFileValidator.looksLikeGGUF(downloaded) { return downloaded }
        return nil
    }
}

enum ModelFileValidator {
    static func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}
