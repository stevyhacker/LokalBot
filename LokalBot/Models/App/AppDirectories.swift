import Foundation

enum AppDirectories {

    static var userApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var applicationSupport: URL {
        applicationSupport(for: AppIdentifiers.identity, under: userApplicationSupport)
    }

    static func applicationSupport(for identity: AppIdentifiers.Identity, under parent: URL) -> URL {
        parent.appendingPathComponent(identity.bundleID, isDirectory: true)
    }

    static var localServerSupport: URL {
        localServerSupport(for: LocalRuntimeOwner.current, under: userApplicationSupport)
    }

    static func localServerSupport(for owner: LocalRuntimeOwner, under parent: URL) -> URL {
        switch owner {
        case .release: applicationSupport(for: .release, under: parent)
        case .development: applicationSupport(for: .development, under: parent)
        case .uiTestHost: applicationSupport(for: .uiTestHost, under: parent)
        case .unitTests:
            parent.appendingPathComponent(AppIdentifiers.appBundleID + ".unit-tests", isDirectory: true)
        }
    }

    static var fluidAudioRoot: URL {
        userApplicationSupport.appendingPathComponent("FluidAudio", isDirectory: true)
    }

    static var whisperKitDownloadRoot: URL {
        applicationSupport.appendingPathComponent("whisperkit", isDirectory: true)
    }

    static var whisperKitRepoRoot: URL {
        whisperKitDownloadRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

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

    static var agentWorkspace: URL { agentWorkspace(forLibraryRoot: libraryRoot) }

    static func agentWorkspace(forLibraryRoot root: URL) -> URL {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        return resolvedRoot.deletingLastPathComponent()
            .appendingPathComponent(resolvedRoot.lastPathComponent + ".agent-workspace", isDirectory: true)
    }
}
