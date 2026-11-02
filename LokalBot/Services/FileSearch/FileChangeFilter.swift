import CoreServices
import DigUpKit
import Foundation
import UniformTypeIdentifiers

/// Which changes FSEvents reports can alter what a sync finds. Every sync walks
/// the chosen folders again (on a developer's Mac 459,000 entries and 18 s of
/// CPU to find nothing), so a change the crawl would leave out never starts one:
/// in a place it doesn't walk, of a type it doesn't read, or inside a code
/// project, where it keeps only screenshots.
///
/// When in doubt it says yes: an extra sync costs seconds, a missed one leaves a
/// new file out of search until something else changes.
struct FileChangeFilter: Sendable {
    struct Change: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    /// Each chosen folder as chosen and as FSEvents reports it (/private/var where the chosen path says /var).
    private let roots: [String]
    private let options: IndexOptions
    private let home: String

    init(folders: [String], options: IndexOptions, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        var seen = Set<String>()
        roots = folders.flatMap { [$0, FolderSelection.realPath($0)] }.filter { seen.insert($0).inserted }
        self.options = options
        self.home = home
    }

    /// The first change in a batch that can alter what a sync finds. A build reports thousands at a time, so what a
    /// batch learns about a folder or a type is asked of the file system once, for each chosen folder (nested ones
    /// answer differently: one's project can be the other's whole).
    func firstThatMatters(_ changes: [Change]) -> String? {
        var batches = roots.map { _ in Batch() }
        return changes.first { matters($0, &batches) }?.path
    }

    private func matters(_ change: Change, _ batches: inout [Batch]) -> Bool {
        // FSEvents lost track of what happened here, or doesn't say what it is: only a sync can tell.
        if change.flags & Self.lostTrack != 0 || change.flags & Self.itemKinds == 0 { return true }
        var placed = false
        for (index, root) in roots.enumerated()
        where change.path == root || FolderSelection.isInside(change.path, root) {
            placed = true
            if matters(change, under: root, &batches[index]) { return true }
        }
        // A spelling of the path that can't be placed in a chosen folder is no reason to miss a change.
        return !placed
    }

    private func matters(_ change: Change, under root: String, _ batch: inout Batch) -> Bool {
        let path = change.path
        // Most of what a busy Mac reports is in hidden folders: no need to ask the file system.
        if path.dropFirst(root.count).contains("/.") { return false }
        let isFolder = change.flags & Self.isFolder != 0
        let parent = (path as NSString).deletingLastPathComponent

        let walked: Bool
        if isFolder {
            walked = Rules.isWalked(path, root: root, home: home, excluded: [])
        } else {
            walked = batch.folderIsWalked(parent) { Rules.isWalked(parent, root: root, home: home, excluded: []) }
        }
        guard walked else { return false }

        // A project's only marker appearing or going decides what the crawl keeps around it, unless a project above
        // it already does. Editing one changes nothing.
        if change.flags & Self.cameOrWent != 0, Rules.decidesProject(path), !inProject(parent, root, &batch) {
            return true
        }
        // A folder's contents report themselves, unless it moved or was cloned: then this is all FSEvents says.
        if isFolder, change.flags & Self.arrivedWhole == 0 { return false }

        let mayMatter: Bool
        if isFolder {
            mayMatter = Rules.changeMayMatter(path, isFolder: true, excludedExtensions: options.excludedExtensions)
        } else {
            let type = (path as NSString).pathExtension.lowercased()
            mayMatter = batch.typeMayMatter(in: parent, type) {
                Rules.changeMayMatter(path, isFolder: false, excludedExtensions: options.excludedExtensions)
            }
        }
        guard mayMatter else { return false }
        if isFolder { return true }

        // Only screenshots count in a code project. A file that's gone goes by its name (the mark went with it); if
        // that's wrong, search still hides a missing file and the next sync drops it.
        guard inProject(path, root, &batch) else { return true }
        let url = URL(fileURLWithPath: path)
        return Rules.classify(url, type: UTType(filenameExtension: url.pathExtension), options: options)
            == .index(.screenshot)
    }

    private func inProject(_ path: String, _ root: String, _ batch: inout Batch) -> Bool {
        batch.isInProject((path as NSString).deletingLastPathComponent) { Rules.isInsideProject(path, root: root) }
    }

    private static let lostTrack = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
    private static let itemKinds = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink)
    private static let isFolder = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    private static let arrivedWhole = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCloned)
    private static let cameOrWent = arrivedWhole | FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved)

    /// Answers kept for one batch: folders and markers can change between batches.
    private struct Batch {
        private var walked: [String: Bool] = [:]
        private var types: [String: Bool] = [:]
        private var projects: [String: Bool] = [:]

        mutating func folderIsWalked(_ folder: String, ask: () -> Bool) -> Bool {
            Self.remembered(&walked, folder, ask)
        }

        mutating func typeMayMatter(in folder: String, _ type: String, ask: () -> Bool) -> Bool {
            Self.remembered(&types, folder + "\u{0}" + type, ask)
        }

        mutating func isInProject(_ folder: String, ask: () -> Bool) -> Bool {
            Self.remembered(&projects, folder, ask)
        }

        private static func remembered(_ answers: inout [String: Bool], _ key: String, _ ask: () -> Bool) -> Bool {
            if let known = answers[key] { return known }
            let answer = ask()
            answers[key] = answer
            return answer
        }
    }
}
