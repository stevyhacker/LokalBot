// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import Foundation

enum CotypingAXHelper {
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

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

    private static let acceptanceMessageTimeoutSeconds: Float = 0.008
    private static let acceptanceDeadlineMilliseconds: UInt64 = 50

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private final class CacheState: @unchecked Sendable {
        let lock = NSLock()
        let fieldStyles = CotypingFieldContextCache<CotypingFieldStyle>(label: "field-style", maxAge: 5)
        let learningScopes = CotypingFieldContextCache<String?>(label: "learning-scope", maxAge: 30)
        let fileDialogs = CotypingFieldContextCache<Bool>(label: "file-dialog", maxAge: 30)
        let codeFields = CotypingFieldContextCache<Bool>(label: "code-field", maxAge: 2)
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
        var markerStyleMisses: [pid_t: TimeInterval] = [:]
        var chromiumEnhancedAccessibility = true
        var enhancedAccessibilityPIDs: Set<pid_t> = []
        var latchedSecureFieldKeys: [String: TimeInterval] = [:]
        var webAreaStates: [String: Bool] = [:]

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

    static func forgetVisibleContext(exceptFor focusIdentityKey: String? = nil, field: CotypingField? = nil) {
        cacheState.visibleContexts.removeAll(except: focusIdentityKey)
        guard focusIdentityKey != nil, let field else {
            CotypingWindowTextCapture.shared.removeAll()
            return
        }
        CotypingWindowTextCapture.shared.forget(
            unlessForProcess: field.processID, role: field.role, fieldFrame: field.inputFrameRect)
    }

    private static var appReadPolicy: CotypingAppReadPolicy {
        cacheState.withLock { cacheState.appReadPolicy }
    }

    private static let domainURLCaptureMaximumAgeSeconds: TimeInterval = 0.25

    static let surfaceCaptureMaximumAgeSeconds: TimeInterval = 1

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

    static func selectedTextForSelectionAction(
        source: SelectionSource, excludedApps: [String], maxCharacters: Int
    ) -> String? {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 400 * 1_000_000
        guard let element = selectionActionElement(source: source, excludedApps: excludedApps),
              DispatchTime.now().uptimeNanoseconds <= deadline else { return nil }
        var text = stringAttribute(element, kAXSelectedTextAttribute as String) ?? ""
        if text.isEmpty,
           Set(parameterizedAttributeNames(on: element)).contains(stringForMarkerRangeAttribute as String),
           let range = copyOpaqueAttribute(selectedTextMarkerRangeAttribute, on: element),
           let current = selectionActionElement(source: source, excludedApps: excludedApps),
           CFEqual(current, element), DispatchTime.now().uptimeNanoseconds <= deadline {
            text = stringForMarkerRange(range, on: element) ?? ""
        }
        guard let current = selectionActionElement(source: source, excludedApps: excludedApps),
              CFEqual(current, element), DispatchTime.now().uptimeNanoseconds <= deadline,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.count > maxCharacters ? String(text.prefix(maxCharacters)) : text
    }

    static func selectionActionFocusIsAllowed(source: SelectionSource, excludedApps: [String]) -> Bool {
        selectionActionElement(source: source, excludedApps: excludedApps) != nil
    }

    private static func selectionActionElement(source: SelectionSource, excludedApps: [String]) -> AXUIElement? {
        func sourceIsAllowed() -> Bool {
            guard isTrusted, source.processID > 0,
                  let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.processIdentifier == source.processID,
                  frontmost.bundleIdentifier == source.bundleID else { return false }
            return !CotypingAvailability.isExcluded(
                appName: frontmost.localizedName ?? "", bundleID: frontmost.bundleIdentifier, excluded: excludedApps)
        }
        guard sourceIsAllowed(), let element = focusedElementForAcceptance(processID: source.processID),
              processID(of: element) == source.processID else { return nil }
        let isSecure = CotypingSecureFieldDetector.isSecure(
            role: stringAttribute(element, kAXRoleAttribute as String),
            subrole: stringAttribute(element, kAXSubroleAttribute as String),
            roleDescription: stringAttribute(element, kAXRoleDescriptionAttribute as String),
            title: stringAttribute(element, kAXTitleAttribute as String),
            descriptionLabel: stringAttribute(element, kAXDescriptionAttribute as String))
        guard !isSecure, sourceIsAllowed() else { return nil }
        return element
    }

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
                cachedField.selectionSkipsParagraphBreaks
                    ? paragraphAlignedAcceptanceContent(on: element, withinDeadline: withinDeadline)
                    : boundedAcceptanceContent(on: element, withinDeadline: withinDeadline)
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
        requestChromiumEnhancedAccessibilityIfNeeded(application: frontmost)
        guard let element = focusedElement(), let owner = owningApp(of: element),
              owner.pid == frontmost.processIdentifier,
              appReadPolicy.allows(appName: owner.name, bundleID: owner.bundleID) else { return .none }
        let appName = owner.name
        let bundleID = owner.bundleID
        let pid = owner.pid

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String)
        let axIdentifier = stringAttribute(element, kAXIdentifierAttribute as String)
        let focusIdentityKey = CotypingAXFocusIdentityKey.make(
            processID: pid, bundleID: bundleID, role: role, subrole: subrole,
            axIdentifier: axIdentifier, elementHash: CFHash(element))
        let latchKey = secureLatchKey(
            processID: pid, bundleID: bundleID, axIdentifier: axIdentifier, elementHash: CFHash(element))

        let roleDescription = stringAttribute(element, kAXRoleDescriptionAttribute as String)
        let title = stringAttribute(element, kAXTitleAttribute as String)
        let descriptionLabel = stringAttribute(element, kAXDescriptionAttribute as String)
        let detectedSecure = CotypingSecureFieldDetector.isSecureRole(role: role, subrole: subrole)
            || CotypingSecureFieldDetector.hasSecureLabel(
                roleDescription: roleDescription,
                title: title,
                descriptionLabel: descriptionLabel)
        if detectedSecure {
            latchSecureField(latchKey)
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Secure field — never read."), field: nil)
        }
        if isSecureFieldLatched(latchKey) {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Secure field — never read."), field: nil)
        }

        let isEditable = editableRoles.contains(role) || isAttributeSettable(element, kAXValueAttribute as String)
        guard isEditable else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }
        let extraLabels = extraFieldLabels(of: element)
        if CotypingSecureFieldDetector.hasSecureLabel(
            roleDescription: nil,
            title: nil,
            descriptionLabel: nil,
            extraLabels: extraLabels) {
            latchSecureField(latchKey)
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .blocked("Secure field — never read."), field: nil)
        }
        let inspectSingleLineField = CotypingSearchFieldDetector.mightBeSearchField(role: role)
            || CotypingCredentialFieldDetector.mightBeCredentialField(role: role)
        let singleLineDOMIdentifier = inspectSingleLineField ? stringAttribute(element, "AXDOMIdentifier") : nil
        let singleLineLabels = inspectSingleLineField
            ? [title, descriptionLabel] + extraLabels
            : []
        let searchSignal = CotypingSearchFieldDetector.signal(
            role: role,
            subrole: subrole,
            labels: singleLineLabels,
            domIdentifier: singleLineDOMIdentifier)
        guard !CotypingSearchFieldDetector.isSearchField(
            signal: searchSignal,
            isBrowser: CotypingSurfaceClassifier.classify(bundleID: bundleID) == .browser,
            isInWebPage: { isInWebArea(element, focusIdentityKey: focusIdentityKey) }) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Search field."), field: nil)
        }
        guard !cacheState.fileDialogs.value(forKey: focusIdentityKey, read: {
            isInFileDialog(element)
        }) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Open or save dialog."), field: nil)
        }
        guard !CotypingCodeFieldDetector.isCodeField(labels: [title, descriptionLabel]),
              !cacheState.codeFields.value(forKey: focusIdentityKey, read: {
                  CotypingCodeFieldDetector.isCodeField(
                      labels: extraLabels + [singleLineDOMIdentifier ?? stringAttribute(element, "AXDOMIdentifier")])
              }) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Verification code field."), field: nil)
        }
        guard !CotypingCredentialFieldDetector.isCredentialField(
            role: role,
            labels: singleLineLabels,
            domIdentifier: singleLineDOMIdentifier,
            text: nil) else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Sign-in or verification field."), field: nil)
        }

        let content = appReadPolicy.readIfAllowed(appName: appName, bundleID: bundleID) {
            let native = selectionRange(element)
            let marker = native == nil ? synthesizeMarkerSelection(on: element) : nil
            let value = marker?.text ?? stringAttribute(element, kAXValueAttribute as String)
            let aligned = native.flatMap { selection in
                value.map { paragraphAlignedSelection(selection, value: $0, on: element) }
            }
            return (native: aligned?.selection ?? native, marker: marker, value: value,
                    skipsBreaks: aligned?.skipsBreaks ?? false)
        }
        guard let content else { return .none }
        let nativeSelection = content.native
        let markerSelection = content.marker
        let usesMarkerSelection = markerSelection != nil

        guard let value = content.value else {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Not an editable text field."), field: nil)
        }
        if CotypingCredentialFieldDetector.mightBeCredentialField(role: role),
           CotypingCredentialFieldDetector.looksLikeAddressEntry(value) {
            return CotypingFocus(appName: appName, bundleID: bundleID,
                                 capability: .unsupported("Sign-in or verification field."), field: nil)
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
            allowBoundsForRange: !usesMarkerSelection && !content.skipsBreaks)
        let inputFrameRect = CotypingAXGeometryResolver.elementFrame(element).map {
            CotypingAXGeometryResolver.cocoaRect(fromAX: $0)
        }
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
        let host = includeURL ? surfaceCapture.urlString.flatMap(CotypingBrowserDomain.host(fromURLString:)) : nil
        let resolvedStyle = includeStyle
            ? cacheState.fieldStyles.valueIfReadable(forKey: focusIdentityKey) {
                usesMarkerSelection
                    ? resolveMarkerFieldStyle(for: element)
                    : resolveFieldStyle(for: element, caretLocation: caret, textLength: nsValue.length)
                        ?? markerFieldStyleUnlessMissed(for: element, processID: pid, caretLocation: caret)
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
        field.selectionSkipsParagraphBreaks = content.skipsBreaks
        if includeVisibleContext, !isIntegratedTerminal,
           CotypingSurfaceClassifier.classify(bundleID: bundleID) != .terminal {
            let policy = cacheState.withLock { cacheState.visibleContextPolicy }
            field.visibleContextWasRequested = true
            let excluded = ScreenContextPrivacy.isExcluded(
                appName: appName, bundleIdentifier: bundleID, rules: policy.excludedApps)
            if policy.windowText, !excluded {
                field.visibleContext = windowTextSnapshot(
                    element: element, processID: pid, appName: appName, bundleID: bundleID,
                    role: role, policy: policy)
            }
            if field.visibleContext == nil, policy.enabled, !excluded {
                field.visibleContext = cacheState.visibleContexts.value(forKey: focusIdentityKey) {
                    let snapshot = CotypingVisibleContext.capture(
                        from: CotypingVisibleContextAXSource(
                            field: element, processID: pid, appName: appName, bundleID: bundleID,
                            focusIsCurrent: { focusedElement().map { CFEqual($0, element) } ?? false }),
                        policy: policy)
                    return policy == cacheState.withLock({ cacheState.visibleContextPolicy }) ? snapshot : nil
                }
            }
            if policy != cacheState.withLock({ cacheState.visibleContextPolicy }) { field.visibleContext = nil }
        }
        return CotypingFocus(appName: appName, bundleID: bundleID, capability: .supported,
                             field: field, focusIdentityKey: focusIdentityKey, host: host)
    }

    static func secureLatchKey(
        processID: pid_t,
        bundleID: String?,
        axIdentifier: String?,
        elementHash: UInt
    ) -> String {
        CotypingAXFocusIdentityKey.make(
            processID: processID,
            bundleID: bundleID,
            role: "",
            subrole: nil,
            axIdentifier: axIdentifier,
            elementHash: elementHash)
    }

    private static func latchSecureField(_ latchKey: String) {
        cacheState.withLock {
            if cacheState.latchedSecureFieldKeys[latchKey] == nil,
               cacheState.latchedSecureFieldKeys.count >= 64,
               let oldest = cacheState.latchedSecureFieldKeys.min(by: { $0.value < $1.value })?.key {
                cacheState.latchedSecureFieldKeys.removeValue(forKey: oldest)
            }
            cacheState.latchedSecureFieldKeys[latchKey] = ProcessInfo.processInfo.systemUptime
        }
    }

    private static func isSecureFieldLatched(_ latchKey: String) -> Bool {
        cacheState.withLock { cacheState.latchedSecureFieldKeys[latchKey] != nil }
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

    static func configureChromiumEnhancedAccessibility(_ enabled: Bool) {
        let turnedOff = cacheState.withLock {
            defer { cacheState.chromiumEnhancedAccessibility = enabled }
            return cacheState.chromiumEnhancedAccessibility && !enabled
        }
        if turnedOff { releaseChromiumEnhancedAccessibility() }
    }

    private static func requestChromiumEnhancedAccessibilityIfNeeded(application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard pid > 0, isChromiumBrowser(bundleID: application.bundleIdentifier),
              cacheState.withLock({
                  cacheState.chromiumEnhancedAccessibility && !cacheState.enhancedAccessibilityPIDs.contains(pid)
              }) else { return }
        let result = setEnhancedAccessibility(true, processID: pid)
        guard CotypingEnhancedAccessibilityRequest.wasDelivered(result) else { return }
        _ = cacheState.withLock { cacheState.enhancedAccessibilityPIDs.insert(pid) }
        _ = releaseOnTermination
        lokalbotLog("cotyping enhanced accessibility: on app=\(application.bundleIdentifier ?? "unknown") "
            + "result=\(result.rawValue)")
    }

    static func releaseChromiumEnhancedAccessibility() {
        let pids = cacheState.withLock {
            defer { cacheState.enhancedAccessibilityPIDs.removeAll() }
            return cacheState.enhancedAccessibilityPIDs
        }
        for pid in pids { _ = setEnhancedAccessibility(false, processID: pid) }
    }

    private static let releaseOnTermination: Void = {
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                releaseChromiumEnhancedAccessibility()
            }
    }()

    private static func setEnhancedAccessibility(_ enabled: Bool, processID: pid_t) -> AXError {
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        return AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
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
            "com.anthropic.claudefordesktop",
            "com.clickup.desktop-app",
            "com.microsoft.vscode",
            "com.microsoft.vscodeinsiders",
            "com.vscodium",
            "md.obsidian",
            "org.whispersystems.signal-desktop",
        ].contains(lowered)
    }

    private nonisolated static func hasMatchingPrefix(_ bundleID: String?, in prefixes: [String]) -> Bool {
        guard let lowered = bundleID?.lowercased() else { return false }
        return prefixes.contains { lowered.hasPrefix($0) }
    }

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

    private static func paragraphAlignedSelection(
        _ selection: NSRange, value: String, on element: AXUIElement
    ) -> (selection: NSRange, skipsBreaks: Bool) {
        let nsValue = value as NSString
        guard nsValue.length > 0, value.contains("\n") else { return (selection, false) }
        let lastCharacter = NSRange(location: nsValue.length - 1, length: 1)
        guard rangeString(lastCharacter, on: element) != nsValue.substring(with: lastCharacter) else {
            return (selection, false)
        }
        guard selection.location > 0,
              let before = rangeString(NSRange(location: 0, length: selection.location), on: element),
              (before as NSString).length == selection.location,
              let location = CotypingParagraphBreakAlignment.caretLocation(in: value, textBeforeCaret: before)
        else { return (selection, true) }
        return (NSRange(location: location, length: selection.length), true)
    }

    private static func rangeString(_ range: NSRange, on element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        return copyOpaqueParameterized(stringForRangeAttribute, parameter: parameter, on: element) as? String
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

    private static func resolveFieldStyle(for element: AXUIElement, caretLocation: Int, textLength: Int) -> CotypingFieldStyle? {
        guard textLength > 0 else { return nil }
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

    private static let markerStyleMissInterval: TimeInterval = 30

    private static func markerFieldStyleUnlessMissed(
        for element: AXUIElement, processID: pid_t, caretLocation: Int
    ) -> CotypingFieldStyle? {
        let now = ProcessInfo.processInfo.systemUptime
        if let missed = cacheState.withLock({ cacheState.markerStyleMisses[processID] }),
           now - missed < markerStyleMissInterval { return nil }
        let style = resolveMarkerFieldStyle(for: element)
        if caretLocation > 0 {
            cacheState.withLock { cacheState.markerStyleMisses[processID] = style == nil ? now : nil }
        }
        return style
    }

    private static func attributedString(forRange range: NSRange, on element: AXUIElement) -> NSAttributedString? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXAttributedStringForRange" as CFString, axRange, &value) == .success else { return nil }
        return value as? NSAttributedString
    }

    static func extractFieldStyle(from attributes: [NSAttributedString.Key: Any]) -> CotypingFieldStyle? {
        var fontName: String?
        var fontPointSize: CGFloat?
        if let font = attributes[.font] as? NSFont {
            fontName = font.fontName
            fontPointSize = font.pointSize
        } else if let fontInfo = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
            fontName = faceName(fromAXFontDictionary: fontInfo)
            if let size = fontInfo["AXFontSize"] as? NSNumber { fontPointSize = CGFloat(size.doubleValue) }
        }
        let foregroundHex = colorAttribute(in: attributes, forKey: .foregroundColor)
            ?? colorAttribute(in: attributes, forKey: NSAttributedString.Key("AXForegroundColor"))
        let backgroundHex = colorAttribute(in: attributes, forKey: .backgroundColor)
            ?? colorAttribute(in: attributes, forKey: NSAttributedString.Key("AXBackgroundColor"))
        let style = CotypingFieldStyle(
            fontName: fontName, fontPointSize: fontPointSize,
            colorHex: foregroundHex, backgroundColorHex: backgroundHex)
        return style.isEmpty ? nil : style
    }

    static func faceName(fromAXFontDictionary fontInfo: [String: Any]) -> String? {
        let axName = (fontInfo["AXFontName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let family = (fontInfo["AXFontFamily"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let visible = (fontInfo["AXVisibleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let family, let axName {
            let normalizedName = normalizedFontToken(axName)
            let normalizedFamily = normalizedFontToken(family)
            if !normalizedFamily.isEmpty, !normalizedName.contains(normalizedFamily) {
                if let visible, normalizedFontToken(visible).contains(normalizedFamily) {
                    return visible
                }
                return family
            }
        }
        return axName ?? visible ?? family
    }

    private static func normalizedFontToken(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

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
        return snapshot.flatMap { policy.permits($0) ? $0 : nil }
    }

    private struct UncheckedElement: @unchecked Sendable {
        let element: AXUIElement
    }

    private static func windowTitle(near element: AXUIElement) -> String? {
        guard let raw = copyAttribute(element, kAXWindowAttribute as String),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return stringAttribute(raw as! AXUIElement, kAXTitleAttribute as String)
    }

    private static func extraFieldLabels(of element: AXUIElement) -> [String?] {
        var labels = [
            stringAttribute(element, kAXPlaceholderValueAttribute as String),
            stringAttribute(element, kAXHelpAttribute as String),
        ]
        if let raw = copyAttribute(element, kAXTitleUIElementAttribute as String),
           CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let label = raw as! AXUIElement
            labels += [
                stringAttribute(label, kAXValueAttribute as String),
                stringAttribute(label, kAXTitleAttribute as String),
                stringAttribute(label, kAXDescriptionAttribute as String),
            ]
        }
        return labels
    }

    private static func isInWebArea(_ element: AXUIElement, focusIdentityKey: String) -> Bool {
        if let cached = cacheState.withLock({ cacheState.webAreaStates[focusIdentityKey] }) {
            return cached
        }
        var current = element
        var definitive: Bool?
        for _ in 0..<30 {
            guard let parent = parentElement(of: current) else { break }
            let parentRole = stringAttribute(parent, kAXRoleAttribute as String)
            if parentRole == "AXWebArea" {
                definitive = true
                break
            }
            if parentRole == kAXWindowRole as String || parentRole == kAXApplicationRole as String {
                definitive = false
                break
            }
            current = parent
        }
        if let definitive {
            cacheState.withLock {
                if cacheState.webAreaStates.count >= 64 {
                    cacheState.webAreaStates.removeAll()
                }
                cacheState.webAreaStates[focusIdentityKey] = definitive
            }
            return definitive
        }
        return false
    }

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

    static func cachedSurfaceCapture(
        in store: CotypingSurfaceCaptureSingleFlight,
        forKey key: String,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: () -> CotypingSurfaceCapture
    ) -> CotypingSurfaceCapture {
        store.capture(forKey: key, maxAge: surfaceCaptureMaximumAgeSeconds, clock: clock, resolve: read)
    }

    private static func webURL(near element: AXUIElement, maxClimb: Int = 6) -> String? {
        var current = element
        for _ in 0...maxClimb {
            if let url = urlString(on: current) { return url }
            guard let parent = parentElement(of: current) else { break }
            current = parent
        }
        return nil
    }

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

    private static func paragraphAlignedAcceptanceContent(
        on element: AXUIElement,
        withinDeadline: () -> Bool
    ) -> BoundedAcceptanceContent? {
        guard let selection = selectionRange(element), selection.length == 0, withinDeadline(),
              let value = stringAttribute(element, kAXValueAttribute as String), withinDeadline() else {
            return nil
        }
        let aligned = paragraphAlignedSelection(selection, value: value, on: element).selection
        let caret = max(0, min(aligned.location, (value as NSString).length))
        guard withinDeadline(), let context = CotypingAcceptanceContentBounds.context(
            in: value, selection: NSRange(location: caret, length: 0)) else { return nil }
        return BoundedAcceptanceContent(context: context)
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

        guard let hit = element(atCocoaPoint: NSEvent.mouseLocation),
              processID(of: hit) == pid else {
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

    private static func selectionRange(_ element: AXUIElement) -> NSRange? {
        rangeAttribute(element, kAXSelectedTextRangeAttribute as String)
    }

    static func validatedTextRange(_ range: CFRange) -> NSRange? {
        guard range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        guard let raw = copyAttribute(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return validatedTextRange(range)
    }


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
