import CoreServices
import DigUpKit
import Foundation
import UniformTypeIdentifiers

struct FileChangeFilter: Sendable {
    struct Change: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private let roots: [String]
    private let options: IndexOptions
    private let home: String

    init(folders: [String], options: IndexOptions, home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        var seen = Set<String>()
        roots = folders.flatMap { [$0, FolderSelection.realPath($0)] }.filter { seen.insert($0).inserted }
        self.options = options
        self.home = home
    }

    func firstThatMatters(_ changes: [Change]) -> String? {
        var batches = roots.map { _ in Batch() }
        return changes.first { matters($0, &batches) }?.path
    }

    private func matters(_ change: Change, _ batches: inout [Batch]) -> Bool {
        if change.flags & Self.lostTrack != 0 || change.flags & Self.itemKinds == 0 { return true }
        var placed = false
        for (index, root) in roots.enumerated()
        where change.path == root || FolderSelection.isInside(change.path, root) {
            placed = true
            if matters(change, under: root, &batches[index]) { return true }
        }
        return !placed
    }

    private func matters(_ change: Change, under root: String, _ batch: inout Batch) -> Bool {
        let path = change.path
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

        if change.flags & Self.cameOrWent != 0, Rules.decidesProject(path), !inProject(parent, root, &batch) {
            return true
        }
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
