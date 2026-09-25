import Foundation
import os

private let logger = Logger(
    subsystem: AppIdentifiers.appBundleID,
    category: "CLIInstaller")

/// Installs the bundled CLI and skill for shell agents. The binary always
/// stays symlinked into the app so Sparkle updates keep it current; skills can
/// be linked or copied. Both ~/.agents/skills and ~/.claude/skills are served.
struct LokalBotCLIInstaller {
    var home: URL
    var bundledBinary: URL?
    var bundledSkillDir: URL?
    var fileManager: FileManager
    var environment: [String: String]

    static var bundled: LokalBotCLIInstaller {
        let fileManager = FileManager.default
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/lokalbot-cli")
        let skill = Bundle.main.resourceURL?.appending(path: "lokalbot-cli")
        return LokalBotCLIInstaller(
            home: fileManager.homeDirectoryForCurrentUser,
            bundledBinary: fileManager.fileExists(atPath: helper.path) ? helper : nil,
            bundledSkillDir: skill.flatMap {
                fileManager.fileExists(atPath: $0.path) ? $0 : nil
            },
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment)
    }

    /// Resolves the app bundle from the embedded helper's own argv[0].
    static func fromCurrentBinary(
        path: String = CommandLine.arguments[0],
        fileManager: FileManager = .default
    ) -> LokalBotCLIInstaller? {
        let binary = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let contents = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let skill = contents.appending(path: "Resources/lokalbot-cli")
        guard fileManager.fileExists(atPath: binary.path),
              fileManager.fileExists(atPath: skill.path) else {
            return nil
        }
        return LokalBotCLIInstaller(
            home: fileManager.homeDirectoryForCurrentUser,
            bundledBinary: binary,
            bundledSkillDir: skill,
            fileManager: fileManager,
            environment: ProcessInfo.processInfo.environment)
    }

    var binLink: URL { home.appending(path: ".local/bin/lokalbot-cli") }
    var skillLink: URL { home.appending(path: ".agents/skills/lokalbot-cli") }
    var claudeSkillLink: URL { home.appending(path: ".claude/skills/lokalbot-cli") }

    static let copyMarkerName = ".lokalbot-skill-copy"
    static let pathExportLine = #"export PATH="$HOME/.local/bin:$PATH""#

    enum SkillMode {
        case symlink
        case copy
    }

    var isInstalled: Bool {
        guard let binary = bundledBinary, let skill = bundledSkillDir else {
            return false
        }
        return symlink(binLink, resolvesTo: binary)
            && symlink(skillLink, resolvesTo: skill)
    }

    var isBundleLocationStable: Bool {
        guard let binary = bundledBinary else { return false }
        if binary.path.contains("/AppTranslocation/") { return false }
        let bundle = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return false
        }
        return true
    }

    var localBinOnPath: Bool {
        let path = environment["PATH"] ?? ""
        let candidate = "\(home.path)/.local/bin"
        return path.split(separator: ":").contains { $0 == candidate }
    }

    enum InstallError: LocalizedError {
        case bundleNotShipped
        case bundleNotStable
        case conflictingPath(String)
        case fileSystem(String)

        var errorDescription: String? {
            switch self {
            case .bundleNotShipped:
                "This build doesn't ship the lokalbot-cli — install the latest release."
            case .bundleNotStable:
                "The app is running from a translocated or read-only location. Move LokalBot.app to /Applications and relaunch."
            case .conflictingPath(let path):
                "LokalBot did not replace \(path) because it is not owned by this installer. Move it to another location before installing."
            case .fileSystem(let message):
                message
            }
        }
    }

    func install(skillMode: SkillMode = .symlink) throws {
        guard let binary = bundledBinary, let skill = bundledSkillDir else {
            throw InstallError.bundleNotShipped
        }
        guard isBundleLocationStable else { throw InstallError.bundleNotStable }

        let destinations = [binLink, skillLink, claudeSkillLink]
        for destination in destinations {
            try requireOwnedOrMissing(destination)
        }
        // Finish every copy/link before touching any current installation.
        var prepared: [(destination: URL, staged: URL)] = []
        defer {
            for item in prepared { try? fileManager.removeItem(at: item.staged) }
        }
        for destination in destinations {
            try ensureDirectory(destination.deletingLastPathComponent())
            let staged = destination.deletingLastPathComponent()
                .appendingPathComponent(".lokalbot-install-\(UUID().uuidString)")
            prepared.append((destination, staged))
            if destination == binLink || skillMode == .symlink {
                try fileManager.createSymbolicLink(
                    at: staged, withDestinationURL: destination == binLink ? binary : skill)
            } else {
                try fileManager.copyItem(at: skill, to: staged)
                try Data().write(to: staged.appendingPathComponent(Self.copyMarkerName))
            }
        }
        for item in prepared { try installPrepared(item.staged, at: item.destination) }
        logger.info("CLI installed at \(binLink.path) -> \(binary.path)")
    }

    /// Removes only LokalBot links and copies stamped by this installer.
    func uninstall() throws {
        for link in [binLink, skillLink, claudeSkillLink] {
            if isOwned(link) {
                try fileManager.removeItem(at: link)
            }
        }
        logger.info("CLI uninstalled")
    }

    func addLocalBinToPath() throws {
        let zshrc = home.appending(path: ".zshrc")
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains(Self.pathExportLine) else { return }
        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += "\n# Added by LokalBot / lokalbot-cli\n\(Self.pathExportLine)\n"
        do {
            try updated.write(to: zshrc, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.fileSystem(
                "Could not write to ~/.zshrc: \(error.localizedDescription)")
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw InstallError.fileSystem(
                "Could not create \(url.path): \(error.localizedDescription)")
        }
    }

    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isOwned(_ url: URL) -> Bool {
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            let target = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
                .standardizedFileURL.path
            let suffix = url == binLink ? "/Contents/Helpers/lokalbot-cli" : "/Contents/Resources/lokalbot-cli"
            return ["LokalBot.app", "LokalBotV3.app"].contains {
                target.hasSuffix("/\($0)\(suffix)")
            }
        }
        return url != binLink && isExistingDirectory(url)
            && fileManager.fileExists(atPath: url.appendingPathComponent(Self.copyMarkerName).path)
    }

    private func requireOwnedOrMissing(_ url: URL) throws {
        if exists(url), !isOwned(url) { throw InstallError.conflictingPath(url.path) }
    }

    private func installPrepared(_ staged: URL, at destination: URL) throws {
        try requireOwnedOrMissing(destination)
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".lokalbot-previous-\(UUID().uuidString)")
        let hadPrevious = exists(destination)
        if hadPrevious { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            if hadPrevious {
                do {
                    try fileManager.moveItem(at: backup, to: destination)
                } catch {
                    throw InstallError.fileSystem("Installation failed. Your previous installation is preserved at \(backup.path).")
                }
            }
            throw InstallError.fileSystem(
                "Could not install at \(destination.path): \(error.localizedDescription)")
        }
        if hadPrevious { try fileManager.removeItem(at: backup) }
    }

    private func symlink(_ link: URL, resolvesTo target: URL) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else {
            return false
        }
        return fileManager.fileExists(atPath: target.path)
            && link.resolvingSymlinksInPath().path
                == target.resolvingSymlinksInPath().path
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
