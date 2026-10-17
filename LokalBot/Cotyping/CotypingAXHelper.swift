import AppKit
import ApplicationServices
import Foundation

/// The Accessibility boundary for cotyping. Resolves the system-wide focused
/// element into a value-type `CotypingField` (preceding/trailing text, caret
/// rect in global Cocoa coords, capability). A trimmed port of Cotabby's
/// `AXHelper` + `FocusSnapshotResolver` + `AXTextGeometryResolver`: caret
/// geometry is the zero-length `kAXBoundsForRange` query (exact) with an
/// element-frame estimate fallback.
///
/// All reads go through a system-wide element with a short messaging timeout so a
/// wedged target app degrades to a missed poll, never a beachball.
enum CotypingAXHelper {
    /// Roles we treat as editable text surfaces.
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    /// Bounded context windows so a giant document never ships megabytes into a
    /// prompt or across the actor boundary. `maxPrecedingCharacters` is the
    /// canonical preceding-window limit — session reconciliation
    /// (`CotypingSessionReconciler`) and marker-selection synthesis reference
    /// it so capped-window comparisons can never drift from the AX read path.
    static let maxPrecedingCharacters =
        CotypingAcceptanceContentBounds.maximumPrecedingUTF16Length

    private static let selectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
    private static let markedTextMarkerRangeAttribute = "AXTextInputMarkedTextMarkerRange" as CFString
    private static let startTextMarkerAttribute = "AXStartTextMarker" as CFString
    private static let endTextMarkerAttribute = "AXEndTextMarker" as CFString
    private static let startMarkerForRangeAttribute = "AXStartTextMarkerForTextMarkerRange" as CFString
    private static let endMarkerForRangeAttribute = "AXEndTextMarkerForTextMarkerRange" as CFString
    private static let markerRangeForMarkersAttribute = "AXTextMarkerRangeForUnorderedTextMarkers" as CFString
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString
    private static let textMarkerForIndexAttribute = "AXTextMarkerForIndex" as CFString
    private static let indexForTextMarkerAttribute = "AXIndexForTextMarker" as CFString
    private static let stringForRangeAttribute = "AXStringForRange" as CFString
    private static let numberOfCharactersAttribute = "AXNumberOfCharacters" as CFString
    private static let previousTextMarkerAttribute = "AXPreviousTextMarkerForTextMarker" as CFString
    private static let attributedStringForMarkerRangeAttribute = "AXAttributedStringForTextMarkerRange" as CFString

    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// The accept tap has a much tighter latency budget than background focus
    /// polling. Each individual read is capped and the whole fixed-path snapshot
    /// stops launching new reads at its wall-clock deadline.
    private static let acceptanceMessageTimeoutSeconds: Float = 0.008
    private static let acceptanceDeadlineMilliseconds: UInt64 = 50

    /// True when the process holds the Accessibility grant (no prompt).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Mutable caches are boxed behind a lock because routine reads happen on
    /// the snapshot queue while the event-tap acceptance check remains a
    /// synchronous main-thread read. A field's font, document scope and the
    /// text above it are cached per focused field, so a keystroke reads only
    /// the field itself.
    private final class CacheState: @unchecked Sendable {
        let lock = NSLock()
        let fieldStyles = CotypingFieldContextCache<CotypingFieldStyle>(label: "field-style", maxAge: 5)
        let learningScopes = CotypingFieldContextCache<String?>(label: "learning-scope", maxAge: 30)
        let fileDialogs = CotypingFieldContextCache<Bool>(label: "file-dialog", maxAge: 30)
        /// Nearby text is held for the focused field only.
        let visibleContexts = CotypingFieldContextCache<CotypingVisibleContext.Snapshot?>(
            label: "visible-context", maxAge: 3, maxEntries: 1)
        var appReadPolicy = CotypingAppReadPolicy()
        var visibleContextPolicy = CotypingVisibleContext.Policy()
        let surfaceCaptures = CotypingSurfaceCaptureSingleFlight()
        let urlCaptures = CotypingSurfaceCaptureSingleFlight()
        var primedWebAccessibilityPIDs: Set<pid_t> = []
        var unsupportedWebAccessibilityPIDs: Set<pid_t> = []
        var lastFrontmostPrimePID: pid_t?
        var chromiumHitTest: (element: AXUIElement, pid: pid_t)?

        func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }
    }

    private static let cacheState = CacheState()

    @discardableResult
    static func configureAppReadPolicy(_ policy: CotypingAppReadPolicy) -> Bool {
        cacheState.withLock {
            let changed = cacheState.appReadPolicy != policy
            cacheState.appReadPolicy = policy
            return changed
        }
    }

    static func configureVisibleContextPolicy(_ policy: CotypingVisibleContext.Policy) {
        let changed = cacheState.withLock {
            defer { cacheState.visibleContextPolicy = policy }
            return cacheState.visibleContextPolicy != policy
        }
        if changed {
            cacheState.visibleContexts.removeAll()
            CotypingWindowTextCapture.shared.removeAll()
        }
    }

    /// Forgets nearby text read from the screen for any field but the
    /// focused one.
    static func forgetVisibleContext(exceptFor focusIdentityKey: String? = nil) {
        cacheState.visibleContexts.removeAll(except: focusIdentityKey)
        // Window text is keyed by its window; a read for another field or
        // window forgets it, and leaving every field forgets it here.
        if focusIdentityKey == nil { CotypingWindowTextCapture.shared.removeAll() }
    }

    private static var appReadPolicy: CotypingAppReadPolicy {
        cacheState.withLock { cacheState.appReadPolicy }
    }

    /// URL authorization is deliberately much fresher than prompt surface
    /// metadata. It is captured only when site exclusions are configured.
    private static let domainURLCaptureMaximumAgeSeconds: TimeInterval = 0.25

    /// Window title and placeholder are read again once they are a second old. Chat
    /// apps reuse one composer across conversations, so a title kept for as
    /// long as the field stayed focused named the conversation left behind.
    /// A second still lets one suggestion's prediction and validation reads
    /// share a capture.
    static let surfaceCaptureMaximumAgeSeconds: TimeInterval = 1

    /// A bounded-cost identity/privacy snapshot for dictation delivery. Unlike
    /// `resolveFocus`, this never reads the field value, surrounding text,
    /// caret geometry, window surface, URL, or style.
    static func resolveDictationFocusSnapshot() -> DictationFocusSnapshot? {
        guard isTrusted else { return nil }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let element = focusedElement() else {
            return frontmost.map {
                DictationFocusSnapshot(
                    processID: $0.processIdentifier,
                    bundleID: $0.bundleIdentifier,
                    focusIdentityKey: nil,
                    isSecureOrBlocked: false)
            }
        }

        let owner = owningApp(of: element)
        let processID = owner?.pid ?? frontmost?.processIdentifier ?? 0
        guard processID > 0 else { return nil }
        let bundleID = owner?.bundleID ?? frontmost?.bundleIdentifier
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)

        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute as String)
        let title = stringAttribute(element, kAXTitleAttribute as String)
        let descriptionLabel = stringAttribute(element, kAXDescriptionAttribute as String)
        let isSecure = CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            title: title,
            descriptionLabel: descriptionLabel)
        if isSecure {
            return DictationFocusSnapshot(
                processID: processID,
                bundleID: bundleID,
                focusIdentityKey: nil,
                isSecureOrBlocked: true)
        }

        let isEditable = editableRoles.contains(role)
            || isAttributeSettable(element, kAXValueAttribute as String)
        guard isEditable else {
            return DictationFocusSnapshot(
                processID: processID,
                bundleID: bundleID,
                focusIdentityKey: nil,
                isSecureOrBlocked: false)
        }

        let focusIdentityKey = focusIdentityKey(
            for: element,
            processID: processID,
            bundleID: bundleID,
            role: role,
            subrole: subrole)
        let selection = selectionRange(element).flatMap {
            DictationTextSelection(location: $0.location, length: $0.length)
        }
        return DictationFocusSnapshot(
            processID: processID,
            bundleID: bundleID,
            focusIdentityKey: focusIdentityKey,
            isSecureOrBlocked: false,
            selection: selection)
    }

    /// The bounded text before the caret in the field a dictation was pasted
    /// into, to confirm the text arrived. Nil when another field has focus or
    /// the field cannot be read; the caller then makes no claim either way.
    /// The value is compared and dropped, never stored.
    static func dictationTextBeforeCaret(processID: pid_t, focusIdentityKey: String?) -> String? {
        guard isTrusted, processID > 0, processID != ProcessInfo.processInfo.processIdentifier,
              let focusIdentityKey, !focusIdentityKey.isEmpty else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 250 * 1_000_000
        func withinDeadline() -> Bool { DispatchTime.now().uptimeNanoseconds <= deadline }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == processID,
              let element = focusedElementForAcceptance(processID: processID), withinDeadline(),
              self.processID(of: element) == processID else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let isSecure = CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: stringAttribute(element, kAXRoleDescriptionAttribute as String),
            title: stringAttribute(element, kAXTitleAttribute as String),
            descriptionLabel: stringAttribute(element, kAXDescriptionAttribute as String))
        let liveIdentity = self.focusIdentityKey(
            for: element, processID: processID, bundleID: frontmost.bundleIdentifier,
            role: role, subrole: subrole)
        guard withinDeadline(), DictationInsertionCheck.allowsReadBack(
            boundIdentity: focusIdentityKey, liveIdentity: liveIdentity, isSecure: isSecure) else { return nil }
        return boundedAcceptanceContent(on: element, withinDeadline: withinDeadline)?.precedingText
    }

    /// The window title and page address around the field a dictation was just
    /// pasted into, for Learn from my dictation's exclusions. Same guards as
    /// `dictationTextBeforeCaret`: the bound field must still have focus and
    /// must not be secure. Never reads the field's text.
    static func dictationLearningSurface(processID: pid_t, focusIdentityKey: String?) -> DictationLearningSurface? {
        guard isTrusted, processID > 0, processID != ProcessInfo.processInfo.processIdentifier,
              let focusIdentityKey, !focusIdentityKey.isEmpty else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 250 * 1_000_000
        func withinDeadline() -> Bool { DispatchTime.now().uptimeNanoseconds <= deadline }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == processID,
              let element = focusedElementForAcceptance(processID: processID), withinDeadline(),
              self.processID(of: element) == processID else { return nil }
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let isSecure = CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: stringAttribute(element, kAXRoleDescriptionAttribute as String),
            title: stringAttribute(element, kAXTitleAttribute as String),
            descriptionLabel: stringAttribute(element, kAXDescriptionAttribute as String))
        let liveIdentity = self.focusIdentityKey(
            for: element, processID: processID, bundleID: frontmost.bundleIdentifier,
            role: role, subrole: subrole)
        guard withinDeadline(), DictationInsertionCheck.allowsReadBack(
            boundIdentity: focusIdentityKey, liveIdentity: liveIdentity, isSecure: isSecure) else { return nil }
        let title = windowTitle(near: element)
        guard withinDeadline() else { return nil }
        let url = webURL(near: element)
        guard withinDeadline() else { return nil }
        return DictationLearningSurface(windowTitle: title, pageURL: url)
    }

    /// Captures only the focus identity, marked-text state, selection, and bounded
    /// caret-adjacent text needed to validate one accept key. This is synchronous —
    /// the event tap must decide whether to swallow the original key — but its
    /// fixed read count and per-element timeout replace the old full `resolveFocus`
    /// traversal (caret geometry, Chromium walks, context, URL, and style).
    static func resolveAcceptanceSnapshot(
        cachedField: CotypingField?
    ) -> CotypingAXAcceptanceSnapshot {
        let unavailable = CotypingAXAcceptanceSnapshot(
            field: nil,
            markedTextState: .unknown,
            hasLiveContent: false)
        guard isTrusted, let cachedField,
              let cachedIdentity = cachedField.focusIdentityKey else {
            return unavailable
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started &+ acceptanceDeadlineMilliseconds * 1_000_000
        func withinDeadline() -> Bool {
            DispatchTime.now().uptimeNanoseconds <= deadline
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == cachedField.processID,
              appReadPolicy.allows(appName: frontmost.localizedName ?? "", bundleID: frontmost.bundleIdentifier),
              cachedField.bundleID == nil || frontmost.bundleIdentifier == cachedField.bundleID,
              withinDeadline(),
              let element = focusedElementForAcceptance(processID: cachedField.processID),
              withinDeadline(),
              processID(of: element) == cachedField.processID else {
            return unavailable
        }

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        guard withinDeadline() else { return unavailable }
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        guard withinDeadline(), role == cachedField.role else { return unavailable }
        let liveIdentity = focusIdentityKey(
            for: element,
            processID: cachedField.processID,
            bundleID: cachedField.bundleID,
            role: role,
            subrole: subrole)
        guard withinDeadline(), liveIdentity == cachedIdentity else { return unavailable }

        guard let markedTextState = markedTextState(
            on: element,
            withinDeadline: withinDeadline) else {
            return unavailable
        }

        guard let content = appReadPolicy.readIfAllowed(
            appName: frontmost.localizedName ?? "", bundleID: frontmost.bundleIdentifier, {
                boundedAcceptanceContent(on: element, withinDeadline: withinDeadline)
            }), withinDeadline() else {
            return unavailable
        }
        var liveField = cachedField
        liveField.focusIdentityKey = liveIdentity
        liveField.precedingText = content.precedingText
        liveField.trailingText = content.trailingText
        liveField.precedingTextIsTruncated = content.precedingIsTruncated
        liveField.selectionLength = content.selectionLength
        return CotypingAXAcceptanceSnapshot(
            field: liveField,
            markedTextState: markedTextState,
            hasLiveContent: true)
    }

    /// Resolve the current focus into a cotyping snapshot. The AX reads remain
    /// synchronous inside this implementation, but routine callers isolate them
    /// behind `CotypingAXSnapshotExecutor`. Accept-key validation uses the bounded
    /// `resolveAcceptanceSnapshot(cachedField:)` path instead.
    static func resolveFocus(includeSurface: Bool = false, includeURL: Bool = false,
                             includeStyle: Bool = false, includeLearningScope: Bool = false,
                             includeVisibleContext: Bool = false) -> CotypingFocus {
        guard isTrusted else {
            return CotypingFocus(appName: "", bundleID: nil,
                                 capability: .unsupported("Accessibility permission needed."),
                                 field: nil)
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              appReadPolicy.allows(appName: frontmost.localizedName ?? "", bundleID: frontmost.bundleIdentifier)
        else { return .none }
        primeWebAccessibilityIfNeeded(application: frontmost)
        guard let element = focusedElement(), let owner = owningApp(of: element),
              owner.pid == frontmost.processIdentifier,
              appReadPolicy.allows(appName: owner.name, bundleID: owner.bundleID) else { return .none }
        let appName = owner.name
        let bundleID = owner.bundleID
        let pid = owner.pid

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let focusIdentityKey = focusIdentityKey(
            for: element, processID: pid, bundleID: bundleID, role: role, subrole: subrole)

        // Secure fields: never read or suggest into them. Some hosts only
        // expose sensitivity through role description/title/description, so
        // check all cheap metadata before touching AXValue.
        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute as String)
        let title = stringAttribute(element, kAXTitleAttribute as String)
        let descriptionLabel = stringAttribute(element, kAXDescriptionAttribute as String)
        if CotypingSecureFieldDetector.isSecure(
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            title: title,
            descriptionLabel: descriptionLabel) {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Secure field — never read."), field: nil)
        }

        let isEditable = editableRoles.contains(role) || isAttributeSettable(element, kAXValueAttribute as String)
        guard isEditable else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }
        guard !CotypingSearchFieldDetector.isSearchField(role: role, subrole: subrole) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Search field."), field: nil)
        }
        guard !cacheState.fileDialogs.value(forKey: focusIdentityKey, read: {
            isInFileDialog(element)
        }) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Open or save dialog."), field: nil)
        }

        let content = appReadPolicy.readIfAllowed(appName: appName, bundleID: bundleID) {
            let native = selectionRange(element)
            let marker = native == nil ? synthesizeMarkerSelection(on: element) : nil
            return (native: native, marker: marker,
                    value: marker?.text ?? stringAttribute(element, kAXValueAttribute as String))
        }
        guard let content else { return .none }
        let nativeSelection = content.native
        let markerSelection = content.marker
        let usesMarkerSelection = markerSelection != nil

        guard let value = content.value else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }

        guard let selection = markerSelection?.selection ?? nativeSelection else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("No caret in this field."), field: nil)
        }

        if selection.length > 0 {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Text selected."), field: nil,
                                 focusIdentityKey: focusIdentityKey)
        }

        let nsValue = value as NSString
        let caret = max(0, min(selection.location, nsValue.length))
        guard let context = markerSelection?.context ?? CotypingAcceptanceContentBounds.context(
            in: value, selection: NSRange(location: caret, length: 0)) else { return .none }
        let preceding = context.preceding
        let trailing = context.trailing

        let (caretRect, exact) = CotypingAXGeometryResolver.caretRect(
            element,
            caretLocation: caret,
            fieldText: value,
            isRightToLeft: CotypingTextDirectionDetector.isRightToLeft(preceding),
            allowBoundsForRange: !usesMarkerSelection)
        let inputFrameRect = CotypingAXGeometryResolver.elementFrame(element).map {
            CotypingAXGeometryResolver.cocoaRect(fromAX: $0)
        }
        // App/window context — only read when actually building a suggestion (it
        // costs extra AX round-trips), gated by the cotyping setting upstream.
        let surfaceCapture = resolveSurfaceCapture(
            element: element,
            processID: pid,
            bundleID: bundleID,
            role: role,
            subrole: subrole,
            focusIdentityKey: focusIdentityKey,
            inputFrameRect: inputFrameRect,
            includeSurface: includeSurface,
            includeURL: includeURL)
        let surfaceTitle = includeSurface ? surfaceCapture.windowTitle : nil
        let surfacePlaceholder = includeSurface ? surfaceCapture.fieldPlaceholder : nil
        // Per-site rules: read the tab URL only when domains are configured (it
        // costs an extra bounded ancestor walk), gated by the coordinator.
        let host = includeURL ? surfaceCapture.urlString.flatMap(CotypingBrowserDomain.host(fromURLString:)) : nil
        // Host field font/color — read (cached per field) only when matching is
        // enabled, so the overlay can mimic the field instead of a fixed style.
        let resolvedStyle = includeStyle
            ? cacheState.fieldStyles.valueIfReadable(forKey: focusIdentityKey) {
                usesMarkerSelection
                    ? resolveMarkerFieldStyle(for: element)
                    : resolveFieldStyle(for: element, caretLocation: caret, textLength: nsValue.length)
            }
            : nil
        let isIntegratedTerminal = CotypingSurfaceClassifier.isIntegratedTerminal(
            domClassList: stringArrayAttribute(element, "AXDOMClassList"))

        var field = CotypingField(
            appName: appName, bundleID: bundleID, processID: pid, role: role,
            focusIdentityKey: focusIdentityKey,
            precedingText: preceding, trailingText: trailing,
            selectionLength: selection.length, caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            isSecure: false, isIntegratedTerminal: isIntegratedTerminal, caretIsExact: exact,
            windowTitle: surfaceTitle, fieldPlaceholder: surfacePlaceholder, fieldStyle: resolvedStyle,
            precedingTextIsTruncated: context.precedingIsTruncated,
            learningScopeKey: includeLearningScope
                ? cacheState.learningScopes.value(forKey: focusIdentityKey) {
                    learningScopeKey(near: element, bundleID: bundleID)
                } : nil)
        if includeVisibleContext, !isIntegratedTerminal {
            let policy = cacheState.withLock { cacheState.visibleContextPolicy }
            field.visibleContextWasRequested = true
            let excluded = ScreenContextPrivacy.isExcluded(
                appName: appName, bundleIdentifier: bundleID, rules: policy.excludedApps)
            // The whole window, once a background read of it exists, includes
            // everything the column above the field would add.
            if policy.windowText, !excluded {
                field.visibleContext = windowTextSnapshot(
                    element: element, processID: pid, appName: appName, bundleID: bundleID,
                    role: role, policy: policy)
            }
            if field.visibleContext == nil, policy.enabled, !excluded {
                // Walking the window takes tens of milliseconds, so it runs once
                // per field and then in the background, never per keystroke.
                field.visibleContext = cacheState.visibleContexts.value(forKey: focusIdentityKey) {
                    let snapshot = CotypingVisibleContext.capture(
                        from: CotypingVisibleContextAXSource(
                            field: element, processID: pid, appName: appName, bundleID: bundleID,
                            focusIsCurrent: { focusedElement().map { CFEqual($0, element) } ?? false }),
                        policy: policy)
                    return policy == cacheState.withLock({ cacheState.visibleContextPolicy }) ? snapshot : nil
                }
            }
            // A policy revocation during a cross-process read drops its result.
            if policy != cacheState.withLock({ cacheState.visibleContextPolicy }) { field.visibleContext = nil }
        }
        return CotypingFocus(appName: appName, bundleID: bundleID, capability: .supported,
                             field: field, focusIdentityKey: focusIdentityKey, host: host)
    }

    private static func focusIdentityKey(
        for element: AXUIElement,
        processID: pid_t,
        bundleID: String?,
        role: String,
        subrole: String?
    ) -> String {
        let axIdentifier = stringAttribute(element, kAXIdentifierAttribute as String)
        return CotypingAXFocusIdentityKey.make(
            processID: processID,
            bundleID: bundleID,
            role: role,
            subrole: subrole,
            axIdentifier: axIdentifier,
            elementHash: CFHash(element))
    }

    /// Wakes Chromium/Electron web accessibility trees lazily, matching
    /// CoTabby's focus pipeline. Safe to call on every poll: successful and
    /// unsupported PIDs are cached, while named Electron editors get one
    /// re-assertion per activation edge.
    private static func primeWebAccessibilityIfNeeded(application: NSRunningApplication) {
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier
        let decision = cacheState.withLock {
            let isActivationEdge = pid != cacheState.lastFrontmostPrimePID
            cacheState.lastFrontmostPrimePID = pid
            guard pid > 0,
                  needsWebAccessibilityPriming(bundleID: bundleID),
                  !cacheState.unsupportedWebAccessibilityPIDs.contains(pid) else {
                return (isActivationEdge, false)
            }
            let reassertForElectronEditor = isActivationEdge && isElectronEditor(bundleID: bundleID)
            let shouldPrime = !cacheState.primedWebAccessibilityPIDs.contains(pid) || reassertForElectronEditor
            return (isActivationEdge, shouldPrime)
        }
        if decision.0 {
            // Returning to a browser may reveal another tab or a page that
            // navigated while inactive. Never reuse its previous URL as an
            // authorization decision.
            cacheState.urlCaptures.removeAll()
        }
        guard decision.1 else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        let value: CFBoolean = kCFBooleanTrue
        switch AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, value) {
        case .success:
            _ = cacheState.withLock { cacheState.primedWebAccessibilityPIDs.insert(pid) }
        case .attributeUnsupported:
            _ = cacheState.withLock { cacheState.unsupportedWebAccessibilityPIDs.insert(pid) }
        default:
            break
        }
    }

    nonisolated static func needsWebAccessibilityPriming(bundleID: String?) -> Bool {
        isChromiumBrowser(bundleID: bundleID) || isElectronEditor(bundleID: bundleID)
    }

    private nonisolated static func isChromiumBrowser(bundleID: String?) -> Bool {
        hasMatchingPrefix(bundleID, in: [
            "com.google.chrome",
            "company.thebrowser.browser",
            "com.brave.browser",
            "com.microsoft.edgemac",
        ])
    }

    nonisolated static func isElectronEditor(bundleID: String?) -> Bool {
        guard let lowered = bundleID?.lowercased() else { return false }
        return [
            "com.clickup.desktop-app",
            "com.microsoft.vscode",
            "com.microsoft.vscodeinsiders",
            "com.vscodium",
        ].contains(lowered)
    }

    private nonisolated static func hasMatchingPrefix(_ bundleID: String?, in prefixes: [String]) -> Bool {
        guard let lowered = bundleID?.lowercased() else { return false }
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    /// Chromium/WebKit contenteditable fields can expose caret text through the
    /// opaque text-marker API instead of `AXSelectedTextRange`. The marker reads
    /// are best-effort and never cached; nil means the existing native-range
    /// unsupported path remains in force.
    private static func synthesizeMarkerSelection(on element: AXUIElement) -> CotypingMarkerSelection? {
        let parameterized = Set(parameterizedAttributeNames(on: element))
        guard parameterized.contains(startMarkerForRangeAttribute as String),
              parameterized.contains(endMarkerForRangeAttribute as String),
              parameterized.contains(markerRangeForMarkersAttribute as String),
              parameterized.contains(stringForMarkerRangeAttribute as String)
        else {
            return nil
        }

        guard let selectionRange = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
              let documentStart = copyOpaqueAttribute(startTextMarkerAttribute, on: element),
              let documentEnd = copyOpaqueAttribute(endTextMarkerAttribute, on: element),
              let selectionStart = copyOpaqueParameterized(
                startMarkerForRangeAttribute, parameter: selectionRange, on: element),
              let selectionEnd = copyOpaqueParameterized(
                endMarkerForRangeAttribute, parameter: selectionRange, on: element)
        else {
            return nil
        }

        guard let preRange = markerRange(from: documentStart, to: selectionStart, on: element),
              let beforeText = stringForMarkerRange(preRange, on: element) else {
            return nil
        }

        let selectedText = stringForMarkerRange(selectionRange, on: element) ?? ""
        let afterText: String
        if let postRange = markerRange(from: selectionEnd, to: documentEnd, on: element),
           let trailing = stringForMarkerRange(postRange, on: element) {
            afterText = trailing
        } else {
            afterText = ""
        }

        return CotypingMarkerSelectionSynthesizer.make(
            beforeCaret: beforeText,
            selected: selectedText,
            afterCaret: afterText)
    }

    private static func markerRange(
        from start: CFTypeRef,
        to end: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        let markers = [start, end] as CFArray
        return copyOpaqueParameterized(markerRangeForMarkersAttribute, parameter: markers, on: element)
    }

    private static func stringForMarkerRange(_ range: CFTypeRef, on element: AXUIElement) -> String? {
        copyOpaqueParameterized(stringForMarkerRangeAttribute, parameter: range, on: element) as? String
    }

    /// Reads the focused field's own font + text color (cached per element) so
    /// the ghost overlay can match it. Best-effort: nil on any miss → overlay
    /// defaults. The parameterized attributed-string read is a synchronous
    /// cross-process call, so it is cached and gated behind `includeStyle`.
    private static func resolveFieldStyle(for element: AXUIElement, caretLocation: Int, textLength: Int) -> CotypingFieldStyle? {
        guard textLength > 0 else { return nil }
        // Prefer the character just before the caret (what the user is extending),
        // then the first character; clamp so an off-by-one caret never reads OOB.
        let clampedCaret = min(max(caretLocation - 1, 0), textLength - 1)
        let candidateIndices = clampedCaret == 0 ? [0] : [clampedCaret, 0]
        var resolved: CotypingFieldStyle?
        for index in candidateIndices {
            guard let attributed = attributedString(forRange: NSRange(location: index, length: 1), on: element),
                  attributed.length > 0,
                  let style = extractFieldStyle(from: attributed.attributes(at: 0, effectiveRange: nil)) else { continue }
            resolved = style
            break
        }
        return resolved
    }

    /// The font and color of the character before the caret in a web field,
    /// which exposes text only through opaque text markers.
    private static func resolveMarkerFieldStyle(for element: AXUIElement) -> CotypingFieldStyle? {
        guard let selection = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
              let caret = copyOpaqueParameterized(startMarkerForRangeAttribute, parameter: selection, on: element),
              let previous = copyOpaqueParameterized(
                previousTextMarkerAttribute, parameter: caret, on: element),
              let range = markerRange(from: previous, to: caret, on: element),
              let attributed = copyOpaqueParameterized(
                attributedStringForMarkerRangeAttribute, parameter: range, on: element) as? NSAttributedString,
              attributed.length > 0 else { return nil }
        return extractFieldStyle(from: attributed.attributes(at: attributed.length - 1, effectiveRange: nil))
    }

    private static func attributedString(forRange range: NSRange, on element: AXUIElement) -> NSAttributedString? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXAttributedStringForRange" as CFString, axRange, &value) == .success else { return nil }
        return value as? NSAttributedString
    }

    /// Extracts a `CotypingFieldStyle` from one character's attributes, handling
    /// both the AppKit `.font`/`.foregroundColor` shapes and the AX font-dict /
    /// CGColor shapes AX returns from web content.
    private static func extractFieldStyle(from attributes: [NSAttributedString.Key: Any]) -> CotypingFieldStyle? {
        var fontName: String?
        var fontPointSize: CGFloat?
        if let font = attributes[.font] as? NSFont {
            fontName = font.fontName
            fontPointSize = font.pointSize
        } else if let fontInfo = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
            fontName = fontInfo["AXFontName"] as? String
            if let size = fontInfo["AXFontSize"] as? NSNumber { fontPointSize = CGFloat(size.doubleValue) }
        }
        let foregroundHex = colorAttribute(in: attributes, forKey: .foregroundColor)
            ?? colorAttribute(in: attributes, forKey: NSAttributedString.Key("AXForegroundColor"))
        // Web/AX content sometimes reports the fill under an `AXBackgroundColor`
        // run attribute rather than the AppKit `.backgroundColor` key.
        let backgroundHex = colorAttribute(in: attributes, forKey: .backgroundColor)
            ?? colorAttribute(in: attributes, forKey: NSAttributedString.Key("AXBackgroundColor"))
        let style = CotypingFieldStyle(
            fontName: fontName, fontPointSize: fontPointSize,
            colorHex: foregroundHex, backgroundColorHex: backgroundHex)
        return style.isEmpty ? nil : style
    }

    /// Extracts a 6-digit hex color from a run attribute, handling both the
    /// AppKit `NSColor` shape and the `CGColor` shape AX returns from web content
    /// (a conditional `as?` to `CGColor` does not compile against `Any`, so the CF
    /// type id is verified before the force-cast).
    private static func colorAttribute(in attributes: [NSAttributedString.Key: Any],
                                       forKey key: NSAttributedString.Key) -> String? {
        guard let value = attributes[key] else { return nil }
        if let nsColor = value as? NSColor {
            return CotypingTextColorCodec.hexString(from: nsColor)
        }
        if CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
           let nsColor = NSColor(cgColor: value as! CGColor) {
            return CotypingTextColorCodec.hexString(from: nsColor)
        }
        return nil
    }

    /// Text recognized in the focused field's window, read in the background.
    /// A keystroke reads only the field's frame and window title here; the
    /// Accessibility walk for the privacy checks runs with the read itself.
    private static func windowTextSnapshot(
        element: AXUIElement, processID: pid_t, appName: String, bundleID: String?,
        role: String, policy: CotypingVisibleContext.Policy
    ) -> CotypingVisibleContext.Snapshot? {
        guard let fieldFrame = CotypingAXGeometryResolver.elementFrame(element) else { return nil }
        let key = CotypingWindowText.key(
            processID: processID, role: role, windowTitle: windowTitle(near: element) ?? "",
            fieldFrame: fieldFrame)
        let field = UncheckedElement(element: element)
        let snapshot = CotypingWindowTextCapture.shared.snapshot(forKey: key) {
            guard CGPreflightScreenCaptureAccess() else {
                CotypingWindowTextCapture.log("Screen Recording is not granted")
                return nil
            }
            let source = CotypingVisibleContextAXSource(
                field: field.element, processID: processID, appName: appName, bundleID: bundleID,
                focusIsCurrent: { focusedElement().map { CFEqual($0, field.element) } ?? false })
            guard let target = source.target(requiringScope: false) else {
                CotypingWindowTextCapture.log("could not resolve the focused field's window")
                return nil
            }
            guard policy.permits(target, source: .windowText) else {
                CotypingWindowTextCapture.log("not read: excluded app or site, private window, or unknown page")
                return nil
            }
            return .init(key: key, processID: processID, target: target)
        }
        // Checked again for every use: the grant or an exclusion may have changed.
        return snapshot.flatMap { policy.permits($0) ? $0 : nil }
    }

    /// Accessibility elements are safe to read from any thread.
    private struct UncheckedElement: @unchecked Sendable {
        let element: AXUIElement
    }

    /// Best-effort title of the window containing `element`: `kAXWindowAttribute`
    /// → `kAXTitleAttribute`. One bounded round-trip; nil on miss. Carries the
    /// email subject, document name, channel, or page title.
    private static func windowTitle(near element: AXUIElement) -> String? {
        guard let raw = copyAttribute(element, kAXWindowAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return stringAttribute(raw as! AXUIElement, kAXTitleAttribute as String)
    }

    /// Whether `element` is in an app's own open or save panel: its window, or
    /// the window a sheet such as Go to Folder hangs from. Cached per field.
    private static func isInFileDialog(_ element: AXUIElement) -> Bool {
        guard let raw = copyAttribute(element, kAXWindowAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let window = raw as! AXUIElement
        var identifiers = [stringAttribute(window, kAXIdentifierAttribute as String)]
        if !CotypingFileDialogDetector.isFileDialog(windowIdentifiers: identifiers),
           stringAttribute(window, kAXRoleAttribute as String) == kAXSheetRole as String,
           let parent = parentElement(of: window) {
            identifiers.append(stringAttribute(parent, kAXIdentifierAttribute as String))
        }
        return CotypingFileDialogDetector.isFileDialog(windowIdentifiers: identifiers)
    }

    private static func learningScopeKey(near element: AXUIElement, bundleID: String?) -> String? {
        let documentURL: String?
        if CotypingLearningScope.nativeDocumentApps.contains(bundleID?.lowercased() ?? "") {
            guard let raw = copyAttribute(element, kAXWindowAttribute as String),
                  CFGetTypeID(raw) == AXUIElementGetTypeID(),
                  let value = copyAttribute(raw as! AXUIElement, kAXDocumentAttribute as String) else { return nil }
            documentURL = (value as? URL)?.absoluteString ?? (value as? String)
        } else if CotypingSurfaceClassifier.classify(bundleID: bundleID) == .browser {
            documentURL = learningDocumentURL(near: element)
        } else {
            return nil
        }
        return CotypingLearningScope.key(bundleID: bundleID, documentURLString: documentURL)
    }

    /// A link's AXURL is not the containing document's identity. Only a web
    /// area's own URL can authorize learned text for a browser document.
    private static func learningDocumentURL(near element: AXUIElement) -> String? {
        var current = element
        for _ in 0...6 {
            if stringAttribute(current, kAXRoleAttribute as String) == "AXWebArea" {
                return urlString(on: current)
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    private static func resolveSurfaceCapture(
        element: AXUIElement,
        processID: pid_t,
        bundleID: String?,
        role: String,
        subrole: String?,
        focusIdentityKey: String?,
        inputFrameRect: CGRect?,
        includeSurface: Bool,
        includeURL: Bool
    ) -> CotypingSurfaceCapture {
        guard includeSurface || includeURL else { return .empty }
        var capture = CotypingSurfaceCapture.empty
        if includeSurface {
            let surfaceKey = CotypingSurfaceCaptureCache.key(
                processID: processID,
                bundleID: bundleID,
                role: role,
                subrole: subrole,
                focusIdentityKey: focusIdentityKey,
                inputFrameRect: inputFrameRect,
                includeSurface: true,
                includeURL: false)
            capture = cachedSurfaceCapture(in: cacheState.surfaceCaptures, forKey: surfaceKey) {
                CotypingSurfaceCapture(
                    windowTitle: windowTitle(near: element),
                    fieldPlaceholder: stringAttribute(element, kAXPlaceholderValueAttribute as String),
                    urlString: nil)
            }
        }
        if includeURL {
            let urlKey = CotypingSurfaceCaptureCache.key(
                processID: processID,
                bundleID: bundleID,
                role: role,
                subrole: subrole,
                focusIdentityKey: focusIdentityKey,
                inputFrameRect: inputFrameRect,
                includeSurface: false,
                includeURL: true)
            let urlCapture = cacheState.urlCaptures.capture(
                forKey: urlKey,
                maxAge: domainURLCaptureMaximumAgeSeconds
            ) {
                CotypingSurfaceCapture(
                    windowTitle: nil,
                    fieldPlaceholder: nil,
                    urlString: webURL(near: element))
            }
            capture.urlString = urlCapture.urlString
        }
        return capture
    }

    /// The field's window title and placeholder from `store`, read again with
    /// `read` once the cached pair is older than `surfaceCaptureMaximumAgeSeconds`.
    static func cachedSurfaceCapture(
        in store: CotypingSurfaceCaptureSingleFlight,
        forKey key: String,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: () -> CotypingSurfaceCapture
    ) -> CotypingSurfaceCapture {
        store.capture(forKey: key, maxAge: surfaceCaptureMaximumAgeSeconds, clock: clock, resolve: read)
    }

    /// Best-effort, fail-safe read of the focused tab's URL near `element`, for
    /// per-site rules. Browsers expose `kAXURLAttribute` on the web area or window
    /// rather than the focused field, so walk up a bounded number of ancestors.
    /// Nil on any miss (non-browser, attribute absent, climb exhausted). When
    /// site exclusions are configured, availability treats that uncertainty as
    /// blocked for browsers rather than bypassing the user's rule. Never mutates
    /// AX state.
    private static func webURL(near element: AXUIElement, maxClimb: Int = 6) -> String? {
        var current = element
        for _ in 0...maxClimb {
            if let url = urlString(on: current) { return url }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    /// Reads `kAXURLAttribute` as a string, tolerating a `URL`/`NSURL` (the usual
    /// case) or an already-string value.
    private static func urlString(on element: AXUIElement) -> String? {
        guard let value = copyAttribute(element, kAXURLAttribute as String) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return value as? String
    }

    private static func parentElement(of element: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(element, kAXParentAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    // MARK: - Element + owner

    /// Focus lookup for the consuming event tap. No Chromium hit-test fallback:
    /// pointer hit-testing does not prove keyboard focus, and the normal helper's
    /// ancestor climb is too expensive for a synchronous global event callback.
    private static func focusedElementForAcceptance(processID: pid_t) -> AXUIElement? {
        guard processID > 0 else { return nil }
        let systemRoot = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemRoot, acceptanceMessageTimeoutSeconds)
        if let element = focusedElementForAcceptance(from: systemRoot) {
            return element
        }

        let appRoot = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appRoot, acceptanceMessageTimeoutSeconds)
        return focusedElementForAcceptance(from: appRoot)
    }

    private static func focusedElementForAcceptance(from root: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(root, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, acceptanceMessageTimeoutSeconds)
        return element
    }

    /// Returns nil when the wall-clock acceptance budget expires between AX
    /// reads. That is different from `.unknown`, which means the reads completed
    /// but the host exposes neither marked-text representation.
    private static func markedTextState(
        on element: AXUIElement,
        withinDeadline: () -> Bool
    ) -> CotypingMarkedTextState? {
        let attributes = Set(attributeNames(on: element))
        guard withinDeadline() else { return nil }
        let nativeAttribute = NSAccessibility.Attribute.textInputMarkedRangeAttribute.rawValue
        let supportsNativeRange = attributes.contains(nativeAttribute)
        let supportsMarkerRange = attributes.contains(markedTextMarkerRangeAttribute as String)

        if supportsNativeRange {
            let range = rangeAttribute(element, nativeAttribute)
            guard withinDeadline() else { return nil }
            if let range, range.location != NSNotFound, range.length > 0 {
                return .active
            }
        }
        if supportsMarkerRange {
            let marker = copyOpaqueAttribute(markedTextMarkerRangeAttribute, on: element)
            guard withinDeadline() else { return nil }
            if marker != nil {
                return .active
            }
        }
        return supportsNativeRange || supportsMarkerRange ? .inactive : .unknown
    }

    private struct BoundedAcceptanceContent {
        let precedingText: String
        let trailingText: String
        let selectionLength: Int
        let precedingIsTruncated: Bool

        init(context: CotypingTextContext) {
            precedingText = context.preceding
            trailingText = context.trailing
            selectionLength = 0
            precedingIsTruncated = context.precedingIsTruncated
        }
    }

    /// Reads only the text windows needed for exact accept-time reconciliation.
    /// Native AX ranges are preferred. Marker-only web editors use index-addressed
    /// text markers. A host that supports neither path fails open unless it first
    /// proves that its entire value is itself bounded to the combined window.
    private static func boundedAcceptanceContent(
        on element: AXUIElement,
        withinDeadline: () -> Bool
    ) -> BoundedAcceptanceContent? {
        if let selection = selectionRange(element) {
            guard withinDeadline() else { return nil }
            return boundedNativeAcceptanceContent(
                on: element,
                selection: selection,
                withinDeadline: withinDeadline)
        }
        guard withinDeadline() else { return nil }
        return boundedMarkerAcceptanceContent(
            on: element,
            withinDeadline: withinDeadline)
    }

    private static func boundedNativeAcceptanceContent(
        on element: AXUIElement,
        selection: NSRange,
        withinDeadline: () -> Bool
    ) -> BoundedAcceptanceContent? {
        guard selection.length == 0,
              let totalLength = acceptanceNumberOfCharacters(on: element),
              withinDeadline(),
              let ranges = CotypingAcceptanceContentBounds.ranges(
                  selection: selection,
                  totalUTF16Length: totalLength) else {
            return nil
        }

        if let preceding = boundedNativeString(
            for: ranges.preceding,
            on: element,
            withinDeadline: withinDeadline),
           let trailing = boundedNativeString(
               for: ranges.trailing,
               on: element,
               withinDeadline: withinDeadline),
           CotypingAcceptanceContentBounds.returnedTextMatchesRequestedRanges(
               precedingText: preceding,
               trailingText: trailing,
               ranges: ranges) {
            return BoundedAcceptanceContent(context: CotypingAcceptanceContentBounds.context(
                precedingText: preceding, trailingText: trailing,
                ranges: ranges, totalUTF16Length: totalLength))
        }

        // Some short native controls expose AXValue + AXSelectedTextRange but
        // not AXStringForRange. Read AXValue only after AXNumberOfCharacters has
        // proven that the complete value is no larger than our bounded windows.
        guard withinDeadline(),
              CotypingAcceptanceContentBounds.allowsWholeValueFallback(
                  totalUTF16Length: totalLength),
              let value = stringAttribute(element, kAXValueAttribute as String),
              withinDeadline() else {
            return nil
        }
        let nsValue = value as NSString
        guard nsValue.length == totalLength,
              CotypingAcceptanceContentBounds.allowsWholeValueFallback(
                  totalUTF16Length: nsValue.length) else {
            return nil
        }
        return BoundedAcceptanceContent(context: CotypingAcceptanceContentBounds.context(
            precedingText: nsValue.substring(with: ranges.preceding),
            trailingText: nsValue.substring(with: ranges.trailing),
            ranges: ranges, totalUTF16Length: totalLength))
    }

    private static func boundedNativeString(
        for range: NSRange,
        on element: AXUIElement,
        withinDeadline: () -> Bool
    ) -> String? {
        guard range.length > 0 else { return "" }
        guard withinDeadline() else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange),
              let value = copyOpaqueParameterized(
                  stringForRangeAttribute,
                  parameter: parameter,
                  on: element) as? String,
              withinDeadline() else {
            return nil
        }
        return value
    }

    private static func acceptanceNumberOfCharacters(on element: AXUIElement) -> Int? {
        guard let value = copyAttribute(element, numberOfCharactersAttribute as String) else {
            return nil
        }
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func boundedMarkerAcceptanceContent(
        on element: AXUIElement,
        withinDeadline: () -> Bool
    ) -> BoundedAcceptanceContent? {
        guard let selectionRange = copyOpaqueAttribute(
            selectedTextMarkerRangeAttribute,
            on: element),
              withinDeadline(),
              let selectionStart = copyOpaqueParameterized(
                  startMarkerForRangeAttribute,
                  parameter: selectionRange,
                  on: element),
              withinDeadline(),
              let selectionEnd = copyOpaqueParameterized(
                  endMarkerForRangeAttribute,
                  parameter: selectionRange,
                  on: element),
              withinDeadline(),
              let selectionStartIndex = textMarkerIndex(
                  selectionStart,
                  on: element),
              withinDeadline(),
              let selectionEndIndex = textMarkerIndex(
                  selectionEnd,
                  on: element),
              withinDeadline(),
              selectionStartIndex >= 0,
              selectionEndIndex == selectionStartIndex,
              let documentEnd = copyOpaqueAttribute(
                  endTextMarkerAttribute,
                  on: element),
              withinDeadline(),
              let documentLength = textMarkerIndex(documentEnd, on: element),
              withinDeadline(),
              let ranges = CotypingAcceptanceContentBounds.ranges(
                  selection: NSRange(location: selectionStartIndex, length: 0),
                  totalUTF16Length: documentLength) else {
            return nil
        }

        let precedingStart: CFTypeRef
        if ranges.preceding.length == 0 {
            precedingStart = selectionStart
        } else {
            guard let marker = textMarker(
                at: ranges.preceding.location,
                on: element),
                  withinDeadline() else {
                return nil
            }
            precedingStart = marker
        }

        let trailingEnd: CFTypeRef
        if ranges.trailing.length == 0 {
            trailingEnd = selectionEnd
        } else if NSMaxRange(ranges.trailing) == documentLength {
            trailingEnd = documentEnd
        } else {
            guard let marker = textMarker(
                at: NSMaxRange(ranges.trailing),
                on: element),
                  withinDeadline() else {
                return nil
            }
            trailingEnd = marker
        }

        guard let preceding = boundedMarkerString(
            from: precedingStart,
            to: selectionStart,
            expectedUTF16Length: ranges.preceding.length,
            on: element,
            withinDeadline: withinDeadline),
              let trailing = boundedMarkerString(
                  from: selectionEnd,
                  to: trailingEnd,
                  expectedUTF16Length: ranges.trailing.length,
                  on: element,
                  withinDeadline: withinDeadline),
              CotypingAcceptanceContentBounds.returnedTextMatchesRequestedRanges(
                  precedingText: preceding,
                  trailingText: trailing,
                  ranges: ranges) else {
            return nil
        }
        return BoundedAcceptanceContent(context: CotypingAcceptanceContentBounds.context(
            precedingText: preceding, trailingText: trailing,
            ranges: ranges, totalUTF16Length: documentLength))
    }

    private static func textMarkerIndex(
        _ marker: CFTypeRef,
        on element: AXUIElement
    ) -> Int? {
        let value = copyOpaqueParameterized(
            indexForTextMarkerAttribute,
            parameter: marker,
            on: element)
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func textMarker(
        at index: Int,
        on element: AXUIElement
    ) -> CFTypeRef? {
        copyOpaqueParameterized(
            textMarkerForIndexAttribute,
            parameter: NSNumber(value: index),
            on: element)
    }

    private static func boundedMarkerString(
        from start: CFTypeRef,
        to end: CFTypeRef,
        expectedUTF16Length: Int,
        on element: AXUIElement,
        withinDeadline: () -> Bool
    ) -> String? {
        guard expectedUTF16Length > 0 else { return "" }
        guard withinDeadline(),
              let range = markerRange(from: start, to: end, on: element),
              withinDeadline(),
              let value = stringForMarkerRange(range, on: element),
              withinDeadline(),
              (value as NSString).length == expectedUTF16Length else {
            return nil
        }
        return value
    }

    static func focusedElement() -> AXUIElement? {
        if let element = focusedElement(from: systemWide) {
            return element
        }
        // Some Chromium/Electron fields are missed by the system-wide focused
        // element query but still resolve through the app-scoped AX object.
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        if let element = focusedElement(forApplicationPID: frontmost.processIdentifier) {
            cacheState.withLock { cacheState.chromiumHitTest = nil }
            return element
        }
        return chromiumHitTestFallback(for: frontmost)
    }

    private static func focusedElement(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        return focusedElement(from: appElement)
    }

    private static func focusedElement(from root: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(root, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = raw as! AXUIElement
        // Pin the timeout on the focused element too so a wedged target app can
        // never block the main-thread reads in `resolveFocus` past 50 ms.
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }

    private static func chromiumHitTestFallback(for application: NSRunningApplication) -> AXUIElement? {
        let pid = application.processIdentifier
        guard pid > 0,
              needsWebAccessibilityPriming(bundleID: application.bundleIdentifier) else {
            cacheState.withLock { cacheState.chromiumHitTest = nil }
            return nil
        }

        if let cache = cacheState.withLock({ cacheState.chromiumHitTest }),
           cache.pid == pid,
           isUsableHitTestCandidate(cache.element, expectedProcessID: pid) {
            return cache.element
        }
        cacheState.withLock { cacheState.chromiumHitTest = nil }

        guard let hit = element(atCocoaPoint: NSEvent.mouseLocation) else {
            return nil
        }
        guard let editable = nearestEditable(from: hit),
              isUsableHitTestCandidate(editable, expectedProcessID: pid) else {
            return nil
        }
        cacheState.withLock { cacheState.chromiumHitTest = (editable, pid) }
        return editable
    }

    private static func element(atCocoaPoint point: CGPoint) -> AXUIElement? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return nil
        }
        let axPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(axPoint.x), Float(axPoint.y), &element) == .success else {
            return nil
        }
        if let element {
            AXUIElementSetMessagingTimeout(element, 0.05)
        }
        return element
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        boolAttribute(element, kAXFocusedAttribute as String) ?? false
    }

    private static func isUsableHitTestCandidate(
        _ element: AXUIElement,
        expectedProcessID: pid_t
    ) -> Bool {
        CotypingAXHitTestFocusValidator.canUseCandidate(
            frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            expectedProcessID: expectedProcessID,
            candidateProcessID: processID(of: element),
            isEditable: isEditableElement(element),
            isFocused: isFocused(element))
    }

    private static func isEditableElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let attributes = Set(attributeNames(on: element))
        let explicitEditable = attributes.contains("AXEditable")
            ? boolAttribute(element, "AXEditable")
            : nil
        return editableRoles.contains(role)
            || explicitEditable == true
            || attributes.contains(selectedTextMarkerRangeAttribute as String)
    }

    /// Climb from a Chromium hit-test leaf to the nearest likely editable
    /// container. Nil is safer than returning an arbitrary hit-test leaf: event
    /// insertion is global and would target the actually focused element.
    private static func nearestEditable(from element: AXUIElement, maxClimb: Int = 5) -> AXUIElement? {
        var current = element
        for _ in 0...maxClimb {
            if isEditableElement(current) {
                return current
            }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    private static func owningApp(of element: AXUIElement) -> (name: String, bundleID: String?, pid: pid_t)? {
        guard let pid = processID(of: element) else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return (name: "", bundleID: nil, pid: pid)
        }
        return (name: app.localizedName ?? "", bundleID: app.bundleIdentifier, pid: pid)
    }

    static func owningApplication(of element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// Locates the host app's Paste command by its Cmd-V key equivalent rather
    /// than localized title. Used only by dictation delivery; cotyping's
    /// consuming event tap never walks host menus or touches the pasteboard.
    static func pasteMenuItem(forApplicationPID pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        guard let menuBarValue = copyAttribute(appElement, kAXMenuBarAttribute as String),
              CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let menuBar = menuBarValue as! AXUIElement
        AXUIElementSetMessagingTimeout(menuBar, 0.05)

        for topLevelItem in childElements(of: menuBar) {
            AXUIElementSetMessagingTimeout(topLevelItem, 0.05)
            for menu in childElements(of: topLevelItem) {
                AXUIElementSetMessagingTimeout(menu, 0.05)
                for item in childElements(of: menu) where isCommandVMenuItem(item) {
                    return item
                }
            }
        }
        return nil
    }

    // MARK: - Attribute readers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func copyOpaqueAttribute(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private static func copyOpaqueParameterized(
        _ attribute: CFString,
        parameter: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &value) == .success else {
            return nil
        }
        return value
    }

    private static func attributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private static func parameterizedAttributeNames(on element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    private static func stringArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [String] {
        copyAttribute(element, attribute) as? [String] ?? []
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyAttribute(element, attribute) as? Bool
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        if let value = copyAttribute(element, attribute) as? Int {
            return value
        }
        return (copyAttribute(element, attribute) as? NSNumber)?.intValue
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        guard let values = copyAttribute(element, kAXChildrenAttribute as String) as? [AnyObject] else {
            return []
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    private static func isCommandVMenuItem(_ item: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(item, 0.05)
        guard let cmdChar = stringAttribute(item, kAXMenuItemCmdCharAttribute as String),
              cmdChar.uppercased() == "V",
              let modifiers = intAttribute(item, kAXMenuItemCmdModifiersAttribute as String) else {
            return false
        }
        return modifiers == 0
    }

    private static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    /// The caret/selection as an NSRange (UTF-16). `length == 0` is a caret.
    private static func selectionRange(_ element: AXUIElement) -> NSRange? {
        rangeAttribute(element, kAXSelectedTextRangeAttribute as String)
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }


    // MARK: - Coordinate conversion compatibility

    static func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        CotypingAXGeometryResolver.cocoaRect(fromAX: axRect)
    }

    static func cocoaRect(
        fromAX axRect: CGRect,
        displayBounds: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        CotypingAXGeometryResolver.cocoaRect(
            fromAX: axRect,
            displayBounds: displayBounds,
            screenFrame: screenFrame)
    }
}
