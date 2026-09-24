import Foundation

/// Single source of truth for LokalBot's on-disk roots. Compiled into both the
/// app and the embedded `lokalbot-cli`, so every binary resolves the same
/// paths — nothing else in the codebase should rebuild these from
/// `FileManager.urls(for: .applicationSupportDirectory, ...)`.
enum AppDirectories {

    /// `~/Library/Application Support` (temp-directory fallback keeps this
    /// total; the URL is always present in practice).
    static var userApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// The app identity's Application Support home. Development builds use
    /// `me.dotenv.LokalBot.dev`; their retention settings cannot affect release
    /// data. Identity-scoped runtimes and mutable process markers are separate too.
    ///
    /// Deliberately NOT redirected by the storage-root override: the installed
    /// llama-server binary, its PID markers, transcription model stores, and
    /// the agent runtime live here even under `LOKALBOT_STORAGE_ROOT`
    /// isolation, so fixture runs share them only with their app identity.
    /// Catalog GGUFs are the exception — they download under the overridable
    /// library root (`ModelCatalog.localURL`); `Scripts/e2e.sh` symlinks the
    /// real models/ into its temp root to keep those shared too.
    static var applicationSupport: URL {
        applicationSupport(for: AppIdentifiers.identity, under: userApplicationSupport)
    }

    static func applicationSupport(for identity: AppIdentifiers.Identity, under parent: URL) -> URL {
        parent.appendingPathComponent(identity.bundleID, isDirectory: true)
    }

    /// FluidAudio's own cache root (`~/Library/Application Support/FluidAudio`)
    /// — the package's convention, not ours; Parakeet/Cohere models land here.
    static var fluidAudioRoot: URL {
        userApplicationSupport.appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// WhisperKit's Hugging Face cache base. Passing this explicitly keeps the
    /// 1.6 GB Core ML model out of `~/Documents`, which may be redirected to a
    /// managed cloud provider, and alongside LokalBot's other local runtimes.
    static var whisperKitDownloadRoot: URL {
        applicationSupport.appendingPathComponent("whisperkit", isDirectory: true)
    }

    /// Repository layout created by WhisperKit below `downloadBase`.
    static var whisperKitRepoRoot: URL {
        whisperKitDownloadRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// The meeting-library root — all user data (meetings, indexes, journal,
    /// logs) lives under it. Honors the `LOKALBOT_STORAGE_ROOT` override so UI
    /// tests, hermetic e2e runs, and the CLI all resolve the same isolated
    /// library as the app.
    static var libraryRoot: URL {
        resolveLibraryRoot(applicationSupport: applicationSupport,
                           storageOverride: UITestRuntime.storageRoot)
    }

    static func resolveLibraryRoot(applicationSupport: URL, storageOverride: String?) -> URL {
        if let storageOverride, !storageOverride.isEmpty {
            return URL(fileURLWithPath: storageOverride, isDirectory: true)
        }
        return applicationSupport
    }

    /// Agent tools start in an empty workspace beside the private library, so
    /// selecting the default workspace does not expose recordings or settings.
    static var agentWorkspace: URL { agentWorkspace(forLibraryRoot: libraryRoot) }

    static func agentWorkspace(forLibraryRoot root: URL) -> URL {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        return resolvedRoot.deletingLastPathComponent()
            .appendingPathComponent(resolvedRoot.lastPathComponent + ".agent-workspace", isDirectory: true)
    }
}
