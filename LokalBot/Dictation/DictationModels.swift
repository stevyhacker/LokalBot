import CoreGraphics
import Foundation

enum DictationIntent: String, Codable, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case compose = "Compose"
    var id: String { rawValue }
    var detail: String {
        self == .transcribe
            ? "Keep the recognized speech. No rewriting or screen context."
            : "Rewrite the spoken request with your writing profile and optional screen context."
    }
}

enum DictationTriggerMode: String, Codable, CaseIterable, Identifiable {
    case pushToTalk = "Push to talk"
    case toggle = "Toggle"
    /// A quick tap starts and a second tap finishes; holding past the tap
    /// threshold works like push to talk.
    case tapOrHold = "Tap or hold"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .toggle: "Toggle"
        case .tapOrHold: "Tap or hold"
        }
    }
}

enum DictationOutputMode: String, Codable, CaseIterable, Identifiable {
    case pasteIntoFocusedApp = "Paste into focused app"
    case copyToClipboard = "Copy to clipboard"
    case showInLokalBot = "Show in LokalBot"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pasteIntoFocusedApp: "Paste into focused app"
        case .copyToClipboard: "Copy to clipboard"
        case .showInLokalBot: "Show in LokalBot"
        }
    }
}

struct DictationLiveTranscript: Equatable, Sendable {
    private static let sentenceBoundaryCharacters = Set(".!?。！？؟۔｡።।॥")

    var committed: String = ""
    var tentative: String = ""

    var isEmpty: Bool {
        committed.isEmpty && tentative.isEmpty
    }

    var displayText: String {
        [committed, tentative]
            .filter { !$0.isEmpty }
            .joined(separator: committed.isEmpty || tentative.isEmpty ? "" : " ")
    }

    static func preview(from text: String) -> Self {
        let normalized = Transcript.normalizedText(text)
        guard !normalized.isEmpty else { return .init() }

        if let last = normalized.last, sentenceBoundaryCharacters.contains(last) {
            return .init(committed: normalized, tentative: "")
        }

        if let boundary = lastSentenceBoundary(in: normalized) {
            let committed = normalized[..<normalized.index(after: boundary)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tentative = normalized[normalized.index(after: boundary)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(committed: committed, tentative: tentative)
        }

        let words = normalized.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 8 else {
            return .init(committed: "", tentative: normalized)
        }
        let committed = words.dropLast(6).joined(separator: " ")
        let tentative = words.suffix(6).joined(separator: " ")
        return .init(committed: committed, tentative: tentative)
    }

    private static func lastSentenceBoundary(in text: String) -> String.Index? {
        text.indices
            .filter { sentenceBoundaryCharacters.contains(text[$0]) }
            .last
    }
}

/// The app/field that owned focus when dictation began. Final transcription
/// may take long enough for focus to move; insertion is allowed only when the
/// same destination still owns focus, otherwise the text is copied safely.
struct DictationDeliveryTarget: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String?
    let focusIdentityKey: String?
    /// Text the person selected before dictating. Pasting replaces exactly that
    /// selection, the way typing would; any other selection blocks the paste.
    var selection: DictationTextSelection?

    init(processID: pid_t, bundleID: String?, focusIdentityKey: String?,
         selection: DictationTextSelection? = nil) {
        self.processID = processID
        self.bundleID = bundleID
        self.focusIdentityKey = focusIdentityKey
        self.selection = selection
    }

    func matches(processID currentProcessID: pid_t,
                 bundleID currentBundleID: String?,
                 focusIdentityKey currentFocusIdentityKey: String?) -> Bool {
        guard processID == currentProcessID else { return false }
        if let bundleID, let currentBundleID, bundleID != currentBundleID { return false }
        if let focusIdentityKey, !focusIdentityKey.isEmpty {
            return focusIdentityKey == currentFocusIdentityKey
        }
        return true
    }

    /// A blocked snapshot always wins over the app-only fallback. In
    /// particular, a target captured before AX exposed a field must never
    /// become permission to paste into a same-app password field later.
    func check(_ snapshot: DictationFocusSnapshot) -> DictationDeliveryCheck {
        guard !snapshot.isSecureOrBlocked else { return .secureField }
        guard matches(
            processID: snapshot.processID,
            bundleID: snapshot.bundleID,
            focusIdentityKey: snapshot.focusIdentityKey) else { return .focusMoved }
        if let current = snapshot.selection, current != selection { return .selectionChanged }
        return .deliverable
    }

    func matches(_ snapshot: DictationFocusSnapshot) -> Bool {
        check(snapshot) == .deliverable
    }

    static func captured(from snapshot: DictationFocusSnapshot) -> Self? {
        guard !snapshot.isSecureOrBlocked else { return nil }
        return Self(
            processID: snapshot.processID,
            bundleID: snapshot.bundleID,
            focusIdentityKey: snapshot.focusIdentityKey,
            selection: snapshot.selection)
    }
}

/// Why a finished dictation may or may not be pasted where it began.
enum DictationDeliveryCheck: Equatable, Sendable {
    case deliverable
    case focusMoved
    case selectionChanged
    case secureField
    /// The field could not be read: Accessibility access is missing, or the
    /// app did not answer in time.
    case fieldUnreadable

    var clipboardMessage: String? {
        switch self {
        case .deliverable:
            nil
        case .focusMoved:
            "Dictation finished after focus moved, so the text was copied to the clipboard instead of being inserted into another app."
        case .selectionChanged:
            "The selected text changed while you were dictating, so the text was copied to the clipboard instead of replacing it."
        case .secureField:
            "Dictation does not type into password fields, so the text was copied to the clipboard."
        case .fieldUnreadable:
            "LokalBot could not confirm which field to paste into, so the text was copied to the clipboard. Check that LokalBot has Accessibility access."
        }
    }
}

/// A non-empty text selection, as UTF-16 offsets reported by Accessibility.
struct DictationTextSelection: Equatable, Sendable {
    let location: Int
    let length: Int

    init?(location: Int, length: Int) {
        guard length > 0, location >= 0 else { return nil }
        self.location = location
        self.length = length
    }
}

/// The minimum Accessibility state needed to bind and later validate a
/// dictation destination. It intentionally carries no field text or geometry.
struct DictationFocusSnapshot: Equatable, Sendable {
    let processID: pid_t
    let bundleID: String?
    let focusIdentityKey: String?
    /// A secure (password) field.
    let isSecureOrBlocked: Bool
    /// The field's non-empty selection, if any.
    var selection: DictationTextSelection?

    init(processID: pid_t, bundleID: String?, focusIdentityKey: String?,
         isSecureOrBlocked: Bool, selection: DictationTextSelection? = nil) {
        self.processID = processID
        self.bundleID = bundleID
        self.focusIdentityKey = focusIdentityKey
        self.isSecureOrBlocked = isSecureOrBlocked
        self.selection = selection
    }

    /// Screen and nearby-text context are never read from a secure field or
    /// while text is selected.
    var blocksContextCapture: Bool { isSecureOrBlocked || selection != nil }
}

struct DictationFocusCaptureResult: Equatable, Sendable {
    let snapshot: DictationFocusSnapshot?
    let timedOut: Bool

    static let timeout = Self(snapshot: nil, timedOut: true)
}

/// Serializes lightweight dictation focus reads on a background queue and
/// gives every caller one wall-clock deadline. A wedged target app therefore
/// fails closed without blocking the main actor or accumulating AX workers.
final class DictationFocusSnapshotExecutor: @unchecked Sendable {
    typealias Resolver = @Sendable () -> DictationFocusSnapshot?

    static let shared = DictationFocusSnapshotExecutor()
    static let defaultDeadlineMilliseconds = 120

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<DictationFocusCaptureResult, Never>
    }

    private struct Batch {
        let id: UInt64
        var waiters: [UInt64: Waiter]
    }

    private let stateQueue = DispatchQueue(label: "me.dotenv.LokalBot.dictation.ax-snapshot-state")
    private let workerQueue = DispatchQueue(
        label: "me.dotenv.LokalBot.dictation.ax-snapshot-worker",
        qos: .userInitiated)
    private let deadlineMilliseconds: Int
    private let resolver: Resolver
    private var nextIdentifier: UInt64 = 0
    private var active: Batch?
    private var pending: Batch?

    init(
        deadlineMilliseconds: Int = defaultDeadlineMilliseconds,
        resolver: @escaping Resolver = { CotypingAXHelper.resolveDictationFocusSnapshot() }
    ) {
        self.deadlineMilliseconds = max(1, deadlineMilliseconds)
        self.resolver = resolver
    }

    /// `deadlineMilliseconds` lengthens the wait for callers that are not on
    /// the shortcut's critical path, such as the check before pasting.
    func capture(deadlineMilliseconds deadlineOverride: Int? = nil) async -> DictationFocusCaptureResult {
        let deadline = max(1, deadlineOverride ?? deadlineMilliseconds)
        return await withCheckedContinuation { continuation in
            stateQueue.async { [self] in
                nextIdentifier &+= 1
                let waiterID = nextIdentifier
                let waiter = Waiter(id: waiterID, continuation: continuation)
                enqueue(waiter)
                stateQueue.asyncAfter(
                    deadline: .now() + .milliseconds(deadline)
                ) { [weak self] in
                    self?.expire(waiterID: waiterID)
                }
            }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        guard active != nil else {
            nextIdentifier &+= 1
            start(Batch(id: nextIdentifier, waiters: [waiter.id: waiter]))
            return
        }
        if var pending {
            pending.waiters[waiter.id] = waiter
            self.pending = pending
        } else {
            nextIdentifier &+= 1
            pending = Batch(id: nextIdentifier, waiters: [waiter.id: waiter])
        }
    }

    private func start(_ batch: Batch) {
        active = batch
        let batchID = batch.id
        workerQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = resolver()
            stateQueue.async { [weak self] in
                self?.finish(batchID: batchID, snapshot: snapshot)
            }
        }
    }

    private func finish(batchID: UInt64, snapshot: DictationFocusSnapshot?) {
        guard let completed = active, completed.id == batchID else { return }
        active = nil
        let result = DictationFocusCaptureResult(snapshot: snapshot, timedOut: false)
        for waiter in completed.waiters.values {
            waiter.continuation.resume(returning: result)
        }
        startPendingIfNeeded()
    }

    private func expire(waiterID: UInt64) {
        if var active, let waiter = active.waiters.removeValue(forKey: waiterID) {
            self.active = active
            waiter.continuation.resume(returning: .timeout)
            return
        }
        if var pending, let waiter = pending.waiters.removeValue(forKey: waiterID) {
            self.pending = pending.waiters.isEmpty ? nil : pending
            waiter.continuation.resume(returning: .timeout)
        }
    }

    private func startPendingIfNeeded() {
        guard active == nil, let pending else { return }
        self.pending = nil
        guard !pending.waiters.isEmpty else { return }
        start(pending)
    }
}

struct DictationPreviewAudioRange: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
}

/// Pure planning for the rolling dictation preview. Each pass starts slightly
/// before the last completed pass so the ASR model hears enough context to
/// finish a word that crossed the boundary, without decoding the whole growing
/// recording again.
enum DictationPreviewWindowPlanner {
    static let defaultOverlapSeconds: TimeInterval = 2.5
    static let defaultMaximumNewAudioSeconds: TimeInterval = 6

    static func range(previousEnd: TimeInterval,
                      currentEnd: TimeInterval) -> DictationPreviewAudioRange? {
        range(previousEnd: previousEnd,
              currentEnd: currentEnd,
              overlapSeconds: defaultOverlapSeconds,
              maximumNewAudioSeconds: defaultMaximumNewAudioSeconds)
    }

    static func range(previousEnd: TimeInterval,
                      currentEnd: TimeInterval,
                      overlapSeconds: TimeInterval,
                      maximumNewAudioSeconds: TimeInterval = defaultMaximumNewAudioSeconds)
        -> DictationPreviewAudioRange? {
        let previous = max(0, previousEnd)
        guard currentEnd > previous else { return nil }
        let end = min(currentEnd, previous + max(0.5, maximumNewAudioSeconds))
        return .init(
            start: max(0, previous - max(0, overlapSeconds)),
            end: end
        )
    }

    static func frameBounds(
        for range: DictationPreviewAudioRange,
        sampleRate: Double,
        totalFrameCount: Int64
    ) -> Range<Int64>? {
        guard range.start.isFinite,
              range.end.isFinite,
              sampleRate.isFinite,
              sampleRate > 0,
              totalFrameCount > 0 else { return nil }
        let start = min(Int64(max(0, range.start) * sampleRate), totalFrameCount)
        let end = min(Int64(max(0, range.end) * sampleRate), totalFrameCount)
        guard end > start else { return nil }
        return start..<end
    }
}

/// Deterministically joins overlapping ASR windows. The newest window replaces
/// the matched suffix so revised capitalization or punctuation at the boundary
/// wins, while a window with no trustworthy two-word overlap is appended rather
/// than risking the loss of already-visible speech.
enum DictationPreviewTextStitcher {
    private static let maximumOverlapGraphemes = 64
    private static let minimumOverlapGraphemes = 4

    static func stitch(previous: String,
                       incoming: String,
                       maximumOverlapWords: Int = 32,
                       minimumOverlapWords: Int = 2) -> String {
        let oldText = Transcript.normalizedText(previous)
        let newText = Transcript.normalizedText(incoming)
        guard !oldText.isEmpty else { return newText }
        guard !newText.isEmpty else { return oldText }

        let oldWords = oldText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let newWords = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let upperBound = min(max(0, maximumOverlapWords), oldWords.count, newWords.count)
        let lowerBound = max(1, minimumOverlapWords)

        if upperBound >= lowerBound {
            for count in stride(from: upperBound, through: lowerBound, by: -1) {
                let oldStart = oldWords.count - count
                let matches = (0..<count).allSatisfy { offset in
                    wordKey(oldWords[oldStart + offset]) == wordKey(newWords[offset])
                        && !wordKey(newWords[offset]).isEmpty
                }
                if matches {
                    return (oldWords.dropLast(count) + newWords).joined(separator: " ")
                }
            }
        }

        // Keep the character fallback for unsegmented scripts. Applying it to
        // ordinary text can mistake an English word suffix for the beginning
        // of an unrelated word (for example, broadcast/cast iron), even when
        // only one side contains whitespace.
        if oldWords.count == 1 || newWords.count == 1,
           containsUnsegmentedScript(in: oldText),
           containsUnsegmentedScript(in: newText),
           let stitched = stitchByGrapheme(previous: oldText, incoming: newText) {
            return stitched
        }

        return oldText + " " + newText
    }

    /// Languages such as Chinese and Japanese generally do not put spaces
    /// between words, so whitespace tokenization turns an entire ASR window
    /// into one token. Fall back to a conservative grapheme match, retaining
    /// the incoming window's latest punctuation and capitalization just as the
    /// word-based path does.
    private static func stitchByGrapheme(previous: String, incoming: String) -> String? {
        let oldGraphemes = semanticGraphemes(in: previous)
        let newGraphemes = semanticGraphemes(in: incoming)
        let upperBound = min(
            maximumOverlapGraphemes,
            oldGraphemes.count,
            newGraphemes.count)
        guard upperBound >= minimumOverlapGraphemes else { return nil }

        for count in stride(
            from: upperBound,
            through: minimumOverlapGraphemes,
            by: -1
        ) {
            let oldStart = oldGraphemes.count - count
            let matches = (0..<count).allSatisfy { offset in
                oldGraphemes[oldStart + offset].key == newGraphemes[offset].key
            }
            let overlapsUnsegmentedScript = (0..<count).contains { offset in
                oldGraphemes[oldStart + offset].isUnsegmentedScript
            }
            if matches && overlapsUnsegmentedScript {
                let prefixEnd = oldGraphemes[oldStart].startIndex
                return Transcript.normalizedText(previous[..<prefixEnd] + incoming)
            }
        }
        return nil
    }

    private struct SemanticGrapheme {
        let key: String
        let startIndex: String.Index
        let isUnsegmentedScript: Bool
    }

    /// Ignore punctuation and spacing while matching, but retain each
    /// grapheme's original index so the stitched output preserves the newest
    /// window verbatim from the overlap onward.
    private static func semanticGraphemes(in text: String) -> [SemanticGrapheme] {
        text.indices.compactMap { index in
            let key = wordKey(String(text[index]))
            guard !key.isEmpty else { return nil }
            return SemanticGrapheme(
                key: key,
                startIndex: index,
                isUnsegmentedScript: isUnsegmentedScript(text[index]))
        }
    }

    private static func containsUnsegmentedScript(in text: String) -> Bool {
        text.contains(where: isUnsegmentedScript)
    }

    /// Scripts whose orthography commonly omits spaces between words. Keep
    /// this deliberately narrower than "non-Latin" because Arabic, Cyrillic,
    /// Devanagari, and many other scripts still use word separators.
    private static func isUnsegmentedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0E00...0x0EFF, // Thai and Lao
                 0x1000...0x109F, // Myanmar
                 0x1780...0x17FF, // Khmer
                 0x3040...0x30FF, // Hiragana and Katakana
                 0x31F0...0x31FF, // Katakana phonetic extensions
                 0x3400...0x4DBF, // CJK extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xA9E0...0xA9FF, // Myanmar extended-B
                 0xAA60...0xAA7F, // Myanmar extended-A
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xFF66...0xFF9F, // Halfwidth Katakana
                 0x20000...0x2FA1F, // CJK extensions and compatibility supplement
                 0x30000...0x323AF: // CJK extensions G through I
                true
            default:
                false
            }
        }
    }

    private static func wordKey(_ word: String) -> String {
        word
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}

/// The global dictation shortcut: a key plus modifiers, or modifiers alone
/// (⌃⌥, the way Wispr Flow and similar apps are often set up). The event tap
/// consumes a key shortcut system-wide, so it must not be something people
/// type; a modifier-only shortcut is observed without consuming anything.
/// The system-wide Ask shortcut uses the same type, but always with a key.
struct DictationShortcut: Equatable, Sendable {
    /// Nil for a modifier-only shortcut.
    var keyCode: CGKeyCode?
    var modifiers: CGEventFlags

    init(keyCode: CGKeyCode?, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.dictationRelevantModifiers
    }

    static let handyDefault = DictationShortcut(keyCode: 49, modifiers: .maskAlternate)
    /// ⌃⇧ Space opens Ask.
    static let quickRecallDefault = DictationShortcut(keyCode: 49, modifiers: [.maskControl, .maskShift])
    /// ⌃⇧ W ("write") opens selection actions.
    static let selectionActionsDefault = DictationShortcut(keyCode: 13, modifiers: [.maskControl, .maskShift])

    var isModifierOnly: Bool { keyCode == nil }

    func matches(_ event: CGEvent) -> Bool {
        matchesKeyCode(event) && event.flags.dictationRelevantModifiers == modifiers
    }

    func matchesKeyCode(_ event: CGEvent) -> Bool {
        guard let keyCode else { return false }
        return CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
    }

    /// "⌥ Space", "⌃⇧ D", "F5", "⌃⌥".
    var displayLabel: String {
        let symbols = Self.modifierSymbols(modifiers)
        guard let keyCode else { return symbols }
        let key = DictationShortcutKeyNames.name(for: keyCode)
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }

    enum Problem: Equatable {
        case reservedForCancel
        case needsModifier
        case commandOnly
        case needsTwoModifiers
        case needsKey
        case usedByDictation
        case usedByAsk
        case usedBySelectionActions
        case usedBySystem
        case unavailable

        var message: String {
            switch self {
            case .reservedForCancel:
                "Esc cancels recording a shortcut. Choose another key."
            case .needsModifier:
                "Add ⌃, ⌥ or ⌘ so the shortcut does not block typing, or use a function key."
            case .commandOnly:
                "Apps use ⌘ with a single key. Add ⌃, ⌥ or ⇧."
            case .needsTwoModifiers:
                "Hold at least two modifier keys, like ⌃⌥, or add a key."
            case .needsKey:
                "Hold the modifiers and press a key, like ⌃⇧ Space."
            case .usedByDictation:
                "Dictation already uses this shortcut. Choose another."
            case .usedByAsk:
                "Ask already uses this shortcut. Choose another."
            case .usedBySelectionActions:
                "Selection actions already use this shortcut. Choose another."
            case .usedBySystem:
                "macOS already uses this shortcut. Choose another."
            case .unavailable:
                "This shortcut could not be registered. Another app may already use it."
            }
        }
    }

    /// Why this combination cannot be the global shortcut, or nil.
    var problem: Problem? {
        guard let keyCode else {
            // One modifier alone fires whenever it is used for anything else.
            return Self.modifierCount(modifiers) >= 2 ? nil : .needsTwoModifiers
        }
        if keyCode == DictationShortcutKeyNames.escape { return .reservedForCancel }
        if DictationShortcutKeyNames.isFunctionKey(keyCode) { return nil }
        let typingSafe = modifiers.intersection([.maskControl, .maskAlternate, .maskCommand])
        guard !typingSafe.isEmpty else { return .needsModifier }
        if modifiers == .maskCommand, !DictationShortcutKeyNames.isNamedKey(keyCode) {
            return .commandOnly
        }
        return nil
    }

    /// Why this combination cannot be the system-wide Ask or selection actions
    /// shortcut, or nil. Both register a Carbon hot key, which needs a key and
    /// never observes modifiers alone.
    var quickRecallProblem: Problem? {
        isModifierOnly ? .needsKey : problem
    }

    static func modifierCount(_ modifiers: CGEventFlags) -> Int {
        [CGEventFlags.maskControl, .maskAlternate, .maskShift, .maskCommand]
            .filter { modifiers.contains($0) }.count
    }

    private static func modifierSymbols(_ modifiers: CGEventFlags) -> String {
        var symbols = ""
        if modifiers.contains(.maskControl) { symbols += "⌃" }
        if modifiers.contains(.maskAlternate) { symbols += "⌥" }
        if modifiers.contains(.maskShift) { symbols += "⇧" }
        if modifiers.contains(.maskCommand) { symbols += "⌘" }
        return symbols
    }
}

extension DictationShortcut: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }

    private static let modifierNames: [(String, CGEventFlags)] = [
        ("control", .maskControl),
        ("option", .maskAlternate),
        ("shift", .maskShift),
        ("command", .maskCommand),
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode)
        if let keyCode, !(0...Int(UInt16.max)).contains(keyCode) {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode, in: c, debugDescription: "Key code out of range")
        }
        let names = try c.decode([String].self, forKey: .modifiers)
        var modifiers: CGEventFlags = []
        for (name, flag) in Self.modifierNames where names.contains(name) {
            modifiers.insert(flag)
        }
        self.init(keyCode: keyCode.map { CGKeyCode($0) }, modifiers: modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(keyCode.map { Int($0) }, forKey: .keyCode)
        try c.encode(
            Self.modifierNames.filter { modifiers.contains($0.1) }.map(\.0), forKey: .modifiers)
    }
}

extension CGEventFlags {
    var dictationRelevantModifiers: CGEventFlags {
        intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }
}
