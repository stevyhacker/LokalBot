# Autocomplete review and cotabby comparison

Review date: **2026-10-08**. Validated and corrected: **2026-10-09**. This report covers LokalBot's current Autocomplete implementation, named `Cotyping` in source, and compares relevant behavior with [FuJacob/cotabby](https://github.com/FuJacob/cotabby).

| Item | Revision or scope |
| --- | --- |
| LokalBot, reviewed | [`b85d145d83087bf45dab61606b9026a0cc6c32c7`](https://github.com/stevyhacker/lokalbot/tree/b85d145d83087bf45dab61606b9026a0cc6c32c7) |
| LokalBot, validated | master `1ade074`; no file under `LokalBot/Cotyping` changed between the two revisions |
| cotabby | [`8cdbea2d2619b0f89a73d46eb0bb856504d07343`](https://github.com/FuJacob/cotabby/tree/8cdbea2d2619b0f89a73d46eb0bb856504d07343) |
| Review scope | Saved-memory lookup, writing-session identity, context freshness, caret capture, generation and presentation, continuation state, and selected native-cache behavior |
| Fixes | F04 and F05 are fixed in the change that added this report, and F02's surface-metadata cache is now bounded to 1 s. F01 and F03 remain open, as does F02's writing-session identity. |
| Executed validation | Review: 112 focused non-UI tests and isolated Swift probes for four of the five findings. Validation: every cited range re-read, an independent F04 timing reproduction, new regression tests confirmed to fail with each fix undone, and 733 Cotyping unit tests on the fixed branch |

Implementation conclusions are tied to these revisions. Source links are immutable GitHub permalinks to the reviewed commit, so they show the code before the F04 and F05 fixes. Recommendations and proposed regression cases for F01–F03 are future work, apart from F02's partial fix.

## Summary

Five actionable findings emerged. Two concern using context from the wrong topic or conversation, and one concerns capturing pixels outside the window that passed the privacy check. Two further defects affected latency and continuation behavior; both are now fixed. F02 is partly fixed: the window title no longer outlives a conversation by more than a second.

Priority indicates remediation urgency for this review: **P1** findings should be addressed first because they affect context correctness or a privacy boundary; **P2** findings affect response time, expected writing behavior, or a narrow and short-lived context error. These are not CVSS scores or claims of observed exploitation.

| ID | Priority | Status | Finding | Trigger and effect | Evidence |
| --- | --- | --- | --- | --- | --- |
| F01 | P2 (corrected from P1) | Open | Saved facts survive a query change | A new topic in the same field can receive the previous topic's facts for one suggestion while replacement retrieval runs | Isolated lookup probe plus production prompt-path inspection |
| F02 | P1 | Partly fixed | Conversation navigation can preserve an old writing session | A reused composer kept the old window title indefinitely (now at most 1 s), nearby text for about 3 s, and cached suggestions for up to 180 s; with identical text an in-flight suggestion also survives | Identity, reconciliation, and cache probes plus coordinator inspection |
| F03 | P1 | Open | Caret OCR capture is not bound to the authorized window | An app switch or overlapping window can put another app's pixels into in-memory OCR | Source-path analysis; no live screen-capture reproduction |
| F04 | P2 | Fixed | Caret timeout did not bound the wait | A slow capture/OCR task delayed presentation beyond the intended 150 ms budget | Extracted production wait method, reproduced twice; regression tests added |
| F05 | P2 | Fixed | Typing through dropped continuation state | Matching typed characters reset `isOpenEnded`, preventing the expected proactive top-up | Direct-typing and published-typing state probes; regression tests added |

The passing tests establish that the selected existing behavior remains green. They do not cover every transition identified here. No fresh, controlled side-by-side latency or model-quality benchmark was performed, so cotabby's architectural differences should not be read as measured speed or quality superiority.

## Corrections after validation

The 2026-10-09 validation confirmed all five findings at source and the recorded test results. It changed the report in these ways:

- **F01** is a deliberate one-suggestion lag, documented in the code, so its priority is lowered to P2. Its first recommended fix (clear the snapshot on any query change) would drop facts from the first suggestion after a newly typed name; the fix below re-filters instead.
- **F02**'s identical-text path is narrower than first described. The broader exposure comes from the surface-metadata cache, the visible-context cache and the suggestion cache, and it compounds with F01.
- **F03**'s practical exposure is narrow, and the capture can include an overlapping window even without a race.
- **F05** also affected the Settings rehearsal. Tab acceptance was not affected.
- **cotabby:** `obtainAutocompleteSequence` does not restore checkpoints; that is native code in a pending upstream patch. Four cited line ranges were corrected, and the window-capture comparison gained a caveat.
- Links to temporary local artifacts were removed; the probe output is kept inline.

## Scope and evidence model

The review followed the path from a focused field through context selection, generation, validation, display, and acceptance. Three sources of context must remain distinct:

1. **Saved facts:** meeting and work-memory snippets behind the separate Autocomplete memory grants.
2. **Visible reply context:** nearby text obtained from Accessibility and associated with the writing target.
3. **Visual caret recovery:** a pixel crop and local OCR used to position the suggestion when Accessibility cannot provide a caret.

F01 concerns relevance of already-authorized saved facts. F02 concerns the lifetime and target of suggestions and their context. F03 concerns the pixels that enter the visual-caret operation. None of these findings demonstrates remote transmission of private content. The current privacy contract describes these distinct boundaries in [saved-memory permissions and relevance][lb-privacy-memory] and [visual-caret capture][lb-privacy-caret].

Evidence is identified throughout as one of:

- **Production source inspection:** the actual call path or state transition at the reviewed revision.
- **Isolated executable probe:** production logic copied into a small Swift harness, with unrelated dependencies replaced by stand-ins where necessary.
- **Existing non-UI test:** a selected repository test run against the reviewed sources.
- **Regression test:** a test added with a fix and confirmed to fail with that fix undone.
- **Proposed regression:** coverage that should accompany a future fix.

The isolated probes establish specific state-machine behavior; they do not simulate an entire host application, private library, live model, or permission interaction. Their output is preserved below.

## F01 — P2: Saved facts are reused after the retrieval query changes

### Trigger and user impact

A user writes about Atlas, receives a saved-memory match, then replaces the draft with one about Borealis in the same composer. Before the Borealis lookup finishes, the next suggestion still receives the Atlas facts. A finished lookup stores its result but does not start a new suggestion, so that suggestion stays on screen until the next keystroke.

The practical effect is an irrelevant or misleading suggestion, potentially bringing a sensitive fact from one topic into writing about another. Retrieval permission may still be valid, but relevance to the current draft is no longer established. A live model was not used to demonstrate that it would repeat the stale fact.

### Source path and cause

[`CotypingMemoryLookup.begin`][lb-memory-lookup] cancels prior lookup work and records the new query, but clears `snapshot` only when the **field anchor** changes:

```swift
if anchor != self.anchor { snapshot = .empty }
self.anchor = anchor
requested = query
```

In [`latestSavedContext`][lb-latest-memory], a changed query starts a replacement lookup asynchronously, and the method immediately returns `memoryLookup.snapshot`. The live generation path then passes that selection's text into `buildRequest`. See [request construction][lb-memory-prompt].

[`Snapshot.isCurrent`][lb-memory-freshness] validates grants, source-file stamps, and source availability. It does not check that the retained selection matches the newly requested query. It therefore cannot reject a valid-on-disk Atlas fact solely because the user is now writing about Borealis.

### Design intent and priority

The lag is deliberate. [`CotypingMemoryLookup`][lb-memory-lookup-intent] documents that a keystroke never waits for a lookup and takes the newest finished one, and `latestSavedContext` notes that the following keystroke picks up a new lookup. The [query][lb-memory-query] is built from distinctive words in the last 500 characters of the finished draft, the window title when app context is on, and selected visible text. It therefore changes at every new distinctive word. In ordinary typing the retained facts were selected for an overlapping query and usually remain relevant. They become irrelevant when the draft is replaced, or when F02's navigation keeps the same field anchor.

Priority is corrected from P1 to P2. The exposure is one suggestion per query change. The facts are already authorized for Autocomplete, and the output is local ghost text that must be accepted. The window closes once the replacement lookup finishes and the user types again.

### Reproduction evidence

The isolated harness used the production `CotypingMemoryLookup` transitions with simplified query and snapshot types:

1. Begin query `Atlas ` under anchor `composer-1`.
2. Finish it with the synthetic fact `Atlas private launch is Thursday`.
3. Begin query `Borealis ` under the same anchor without finishing it.
4. Read the retained snapshot.

Observed output:

```text
MEMORY_QUERY_CHANGED: oldFact=Atlas private launch is Thursday
```

This proves retention across the query transition. Inspection of the real coordinator establishes that the retained selection is supplied to the next generation request. The test did not invoke production retrieval against private files or run a model.

### Recommended fix and regression coverage

Do not simply clear the snapshot on every query change. Because the query changes at every new distinctive word, the first suggestion after the user types a project name would never include that project's facts, which is when they are most useful. Instead:

1. Re-filter the retained items against the new query before use. The selection holds at most two items and [`CotypingMemoryContext.select(items:query:policy:)`][lb-memory-select] is pure, so this is cheap. Items that no longer qualify are dropped at once; items that still qualify keep helping.
2. When a lookup finishes with a different selection while a suggestion built from the old one is visible, generate again, or at least remove the stale ghost.
3. Tie the snapshot to the writing session introduced for F02, so navigation cannot carry it across conversations.

Add a deterministic coordinator test with a controllable memory provider: complete Atlas retrieval, replace the draft in the same field with Borealis, hold Borealis retrieval pending, and inspect the request delivered to the engine. Assert that Atlas facts are absent. Also assert that a draft extended from "Atlas " to "Atlas launch with Borealis " keeps the Atlas fact. Cover an empty/no-match query, cancellation, and an older lookup completing after the new one. The regression should fail with the fix undone.

## F02 — P1: Navigation can retain suggestions and context from another conversation

### Trigger and user impact

Some applications reuse the same Accessibility composer element or field geometry when navigating between conversations. LokalBot can then treat the new conversation as the old writing target, and context read for the old conversation can shape suggestions in the new one.

For example, navigate from an Atlas conversation to a Borealis conversation whose composer also contains `Please `. An old suggestion can still pass the generation-target and continuation checks. Old visible context may accompany it. Actual insertion into a live host application was not exercised in this review.

### Source path and cause

Several mechanisms reinforce the same failure:

1. [`CotypingFieldIdentity`][lb-field-identity] uses the AX focus key when present, otherwise the frame. Window title and placeholder are only fallback identity inputs. Suggestion anchoring and prewarm deduplication share this derivation.
2. [`CotypingAXHelper.resolveSurfaceCapture`][lb-surface-capture] caches title/placeholder under a key derived from the field and calls `capture` without an age limit. [`CotypingSurfaceCaptureSingleFlight`][lb-surface-age] treats a missing maximum age as always fresh. The URL path separately supplies an age limit and is cleared whenever the frontmost app changes; the surface cache has no invalidation call at all ([cache state][lb-ax-cache-state]).
3. [`CotypingSessionReconciler`][lb-reconciliation-identity] validates process, field identity, and relevant text conditions without a distinct navigation-aware session identity.
4. [`handleFocusChange`][lb-focus-change] relies on those continuation decisions. The explicit active-visible-context clearing branch shown there handles a missing field, which does not cover every reused-composer navigation.
5. [`validatedLiveFieldForGeneratedResult`][lb-generation-validation] copies the original field's `visibleContext` into the validated field. The [acceptance privacy check][lb-acceptance-context] checks the retained context target's policy; this alone does not establish that it belongs to the new conversation.

Stable identity while ordinary typing is desirable. It needs to coexist with a separate signal that distinguishes navigation from continued editing.

### How narrow each path is

- **In-flight or visible suggestion.** Generation validation compares a [content signature][lb-content-signature] made of the selection length and the full text before and after the caret. A focus change clears the session unless the new text still extends it. An old suggestion survives navigation only when the new composer holds exactly the same text, as in the probe below. This is the narrowest path.
- **Surface metadata.** At the reviewed revision, the title/placeholder entry was replaced only when another field's surface was read under a different key. While the user stayed in a composer whose AX identity and frame survive navigation, every request carried the old title. It feeds the [prompt preface][lb-engine-surface] when app context is on, and the saved-memory query. The entry is now read again once it is a second old (see Partial fix).
- **Visible reply context.** Nearby text is cached per focus identity for 3 s and returned stale while a background refresh runs ([field context cache][lb-field-context-cache]). The first suggestions after navigation can therefore use the previous conversation's messages.
- **Suggestion cache.** Cached suggestions are restored by field identity and a request fingerprint that includes the rendered preface, for up to 180 s ([anchor cache][lb-anchor-cache]). With a stale title, and visible context unchanged or off, typing the same opening words in the new conversation can restore the old conversation's suggestion without a model call. This was inferred from source and not reproduced. With the title now re-read after a second, this path is limited to the title's 1 s window and the visible context's roughly 3 s window.
- **Interaction with F01.** The stale title is part of the saved-memory query, so an identical draft in the new conversation did not start a new lookup at all. This now lasts at most a second.

The P1 priority rested mainly on the unbounded metadata cache and the suggestion cache, not on the identical-text path. After the partial fix, the remaining exposure is seconds long: the title for up to 1 s, nearby text for about 3 s, and the identical-text path. Reassess whether the session-identity work stays P1 once it has been observed in a real chat app.

### Reproduction evidence

The harness constructed two fields with the same process, bundle, role, AX identity, and text. It changed the window title from `Atlas conversation` to `Borealis conversation` and the placeholder from `Message Atlas` to `Message Borealis`.

Observed production-policy results:

```text
NAVIGATION: sameAnchor=true oldGenerationAccepted=true oldSessionAccepted=true
```

Here, `oldSessionAccepted` means the pure `isAcceptanceContinuation` policy returned true. It is not evidence that the event tap posted text into another application's field.

A second probe populated the surface cache at virtual time zero, then requested the same key at virtual time 86,400 seconds with a resolver that would return Borealis:

```text
SURFACE_CACHE: after24Hours=Atlas conversation
```

This demonstrates the absence of an age bound when that key remains cached and no explicit invalidation occurs. It is a virtual-clock probe, not an observation of a live app left running for 24 hours.

### Why existing coverage misses this case

[`testPrewarmIdentityIgnoresTextCaretAndSurfaceChurnWhenFocusIdentityExists`][lb-prewarm-test] intentionally tolerates surface churn for prewarming. That requirement should not automatically define the lifetime of a context-bearing suggestion.

[`testChangedVisibleContextInvalidatesPendingAndCachedSuggestion`][lb-context-test] calls `handleFocusChange(.none)`. It verifies disappearance of the focused field, not navigation that reuses a populated composer and AX identity.

### cotabby comparison

Cotabby's [`FocusedInputPollingSignature`][ct-polling] compares fresh title, full URL, and placeholder alongside process and field geometry. Its [`FocusedInputSessionIdentity`][ct-session] carries a focus-change sequence and surface facts. Its [visual-context excerpt lookup][ct-visual-context] checks session identity and focus sequence and expires old excerpts.

These are useful design references for a writing-session boundary. They do not prove that cotabby detects every host application's navigation correctly.

### Recommended fix and regression coverage

Separate geometry/prewarm identity from writing-session identity. Use refreshed navigation metadata and a monotonic session generation to invalidate pending predictions, active suggestions, saved-memory selections, visible context, and related caches when the conversation changes. Give surface metadata a bounded freshness policy; a stronger identity cannot help if its inputs remain indefinitely cached. The surface capture now has a maximum age, as the URL path already had (see Partial fix).

Test navigation with unchanged AX identity, unchanged frame, and identical prefix/trailing text. Vary title, placeholder, and URL independently. Verify that delayed model results, already-visible suggestions and suggestion-cache restorations are rejected. Retain controls for ordinary typing and a composer growing as text wraps, so the fix does not discard valid suggestions on every edit.

### Partial fix

`CotypingAXHelper.cachedSurfaceCapture` now reads the window title and placeholder again once the cached pair is older than `surfaceCaptureMaximumAgeSeconds` (1 s). A second covers one suggestion: the prediction read and the validation read after the model returns usually share one capture, so the validation snapshot stays within its deadline. A reused composer picks up the new conversation's title on the next suggestion. The read is three Accessibility attribute calls (window, title, placeholder).

`CotypingSurfaceContextTests/testAComposerReusedAcrossConversationsReadsTheNewTitle` changes the title behind a reused composer key. It checks that a read 0.3 s later reuses the capture and a read 2.3 s later returns the new title. With the age limit removed it failed, still returning `Atlas conversation` after one read.

This does not give LokalBot a navigation signal. The identical-text path, the visible-context window and the session identity remain open.

## F03 — P1: Caret OCR captures a display crop rather than the authorized window

### Trigger and user impact

Screen Recording is already granted, an allowed field lacks an exact Accessibility caret, and visual-caret recovery begins. Before its asynchronous capture completes, the user switches apps or another window overlaps the target rectangle.

The crop can then contain pixels from the new foreground or overlapping window, including an excluded application. Those pixels enter local OCR even though that window did not pass the original authorization check. The same happens without a race when a window already overlaps the field at capture time, such as a notification banner or a floating panel.

This is a source-established capture-scope and timing issue. No private screen was captured to reproduce it, and no remote transmission or persistence was observed or demonstrated.

### Source path and cause

[`prepareVisualCaret`][lb-prepare-caret] performs the initial field/app/domain policy check. [`refreshIfNeeded`][lb-visual-refresh] then schedules asynchronous work using the field's rectangle.

The capture and recognition path receives a `CGRect`, not an immutable authorized PID/window/session target. After awaiting shareable content, [`capture`][lb-visual-capture] selects a display and builds:

```swift
let filter = SCContentFilter(display: display, excludingWindows: [])
return try? await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: config)
```

The rectangle constrains the area, but does not bind the pixels to the authorized window. `recognizeLines` starts detached OCR after capture, and the explicit cancellation check in the outer task occurs only after recognition finishes. Ordinary [focus-change handling][lb-focus-change] does not reset the visual-caret operation; [`visualCaret.reset()`][lb-stop-caret] is present in the stop path.

The [privacy contract][lb-privacy-caret] describes capture of the focused field and exclusion of secure/excluded targets. Checking the original field before suspension is insufficient to enforce that contract for a later display crop.

### Practical exposure

The exposure is narrower than the boundary violation suggests. The image and recognized text stay in memory. [`CotypingVisualCaretLocator.locate`][lb-caret-locate] keeps a result only when a recognized line closely matches the end of the field's own text, and then keeps only the caret's position. Another window's text therefore practically never yields a result, and nothing from it is kept. The priority stays P1 because the privacy contract promises the capture is the focused field's own frame and never covers excluded apps.

### cotabby comparison and its limit

Cotabby's **OCR context screenshot service** identifies a window owned by the focused process, uses `SCContentFilter(desktopIndependentWindow: matchingWindow)`, and checks cancellation after shareable-content retrieval and image capture. See [`WindowScreenshotService.captureSnapshot`][ct-window-capture]. In its default crop mode, that window is the focused process's first active on-screen window, not necessarily the one with the caret.

This comparison is specific to that service. Cotabby's [pixel-caret][ct-pixel-caret] and [baseline][ct-baseline] paths capture with `SCContentFilter(display:excludingApplications:exceptingWindows:)`, excluding only Cotabby itself, cropped by `sourceRect`. This report does not claim every cotabby pixel operation is window-bound or that cancellation checks alone solve all authorization races.

### Recommended fix and regression coverage

Carry an authorized capture target containing PID, window identity, writing-session generation, and the relevant policy state. Capture only that window and intersect the crop with its bounds. Revalidate the target and policy after suspension points and before beginning capture and OCR. Cancel pending work on focus/navigation/policy changes and reject late results from older sessions.

If a trustworthy target cannot be resolved, use the existing popup placement fallback.

Use an injectable screenshot/OCR boundary to test an allowed field followed by an excluded app, overlapping window, session switch, and grant revocation while shareable-content retrieval is suspended. Assert that unauthorized image/OCR work is never started and that late results cannot update the current caret. Host-level UI validation should use hosted CI or a remote runner with synthetic content.

## F04 — P2: The visual-caret timeout waited for the losing task (fixed)

### Trigger and user impact

A completion is ready, but the visual-caret task is still running. The coordinator intends to wait at most 150 ms before continuing with available geometry. Instead, it waited for the entire capture/OCR operation.

This delayed visible suggestions and made the fallback dependent on work that was intended to be optional.

### Source path and cause

The coordinator [awaits caret recovery after validating the generated result][lb-completion-wait], using the [150 ms configured budget][lb-caret-budget], documented as how long a finished suggestion waits for its caret "before it is shown beside the field instead". The implementation in [`waitForPending`][lb-caret-wait] was:

```swift
await withTaskGroup(of: Void.self) { group in
    group.addTask { await task.value }
    group.addTask { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    await group.next()
    group.cancelAll()
}
```

The first child awaits a separately created task. Cancelling that child does not cause `task.value` to stop waiting for the independent task, and leaving the structured task group waits for its children. The timer can finish first without allowing the enclosing method to return at the deadline.

### Reproduction evidence

The exact method body was extracted into a standalone Swift harness. Its pending task slept for 450 ms and the requested wait budget was 30 ms:

```text
VISUAL_CARET_TIMEOUT: budgetMs=30 pendingMs=450 elapsedMs=469
```

An independent harness on 2026-10-09 repeated this at the production budget and compared a deadline-based replacement:

| Budget | Pending work | Original method | Replacement |
| ---: | ---: | ---: | ---: |
| 150 ms | 400 ms | 403 ms | 160 ms |
| 150 ms | 60 ms | 63 ms | 65 ms |
| 30 ms | 450 ms | 468 ms | 33 ms |

These figures are synthetic timeout reproductions, not measured live OCR duration or end-to-end Autocomplete latency.

### Fix

`waitForPending` now delegates to `CotypingBoundedWait.wait(for:milliseconds:)`. It resumes a continuation on whichever comes first: the find finishing, the deadline, or cancellation of the waiting task. The find itself is not cancelled. It keeps running and its result is kept, so a slow find no longer delays this suggestion but still places the next one.

Not changed: the live field is still validated before the wait rather than after. With the wait now bounded to 150 ms, that window is bounded too. Revalidating after the wait would add an Accessibility read to every visual-caret suggestion; it is left for the session work in F02.

### Regression coverage

Added to `CotypingVisualCaretTests`:

- `testTheWaitForASlowFindEndsAtItsDeadline`: a 5 s find with a 50 ms budget returns within 2 s, and the find is not cancelled.
- `testCancellingTheWaiterEndsTheWait`: cancelling the waiting task ends the wait promptly.
- Controls: `testAFindThatFinishesFirstEndsTheWaitAtOnce` and `testWithNoFindRunningThereIsNothingToWaitFor`.

With the original task-group body restored behind the same entry point, the first two failed after about 5.0 s each. The assertions use a wide tolerance rather than exact milliseconds. A late find completing after a focus change is not covered; it only updates the caret calibration, which is keyed by process, role and frame, as before.

## F05 — P2: Typing through a suggestion dropped its extension eligibility (fixed)

### Trigger and user impact

An open-ended suggestion is visible and the user types characters that match its beginning. The remaining text was correctly advanced, but the session lost the flag used to decide whether to generate more words.

The result was inconsistent behavior: accepting a chunk retained proactive top-up, while typing the same chunk prevented it. This conflicted with the [documented flow while accepting or typing through][lb-writing-flow]. It did not stop all future generation; it prevented extension of that active session before exhaustion.

### Source path and cause

[`sessionReconciledByPublishedTyping` and `sessionAdvancedByTypedCharacters`][lb-typing-reconciliation] constructed new `CotypingSession` values but omitted `isOpenEnded`, including the published-typing branch where no newly typed characters remain to consume.

[`CotypingSession`][lb-session-model] defaults that flag to `false`. In contrast, its `advanced(by:)` helper copies the session and changes only `consumedCount`, preserving the flag. [`CotypingSuggestionExtension.shouldExtend`][lb-extension-policy] requires `session.isOpenEnded`.

Also affected: the Settings rehearsal's [`textChanged`][lb-rehearsal-typing] advances through `sessionAdvancedByTypedCharacters`, so typing through the rehearsal ghost lost the top-up too.

Not affected: [Tab acceptance][lb-tab-accept] advances with `advanced(by:)`. It does not pass through the published-typing reconciler, which runs only during [host-publish polling][lb-host-publish] after a keystroke that the typed-character path did not match.

### Reproduction evidence

The probe began with prefix `Please `, suggestion `send the report tomorrow`, and `isOpenEnded = true`. It compared typing `send the ` with advancing by the same character count through `advanced(by:)`:

```text
TYPE_THROUGH: originalOpen=true typedOpen=false typedShouldExtend=false acceptedShouldExtend=true remaining=report tomorrow
PUBLISHED_TYPING: open=false shouldExtend=false
```

Both direct typed-character handling and reconciliation after host publication reset the flag. The harness used the production session and reconciliation logic. An unrelated sentence-boundary dependency was simplified; this case explicitly set `isOpenEnded` before exercising the state transition.

### Related path

The [suggestion-cache restoration path][lb-cache-restore] also constructed a session with the default flag, whereas [fresh generation][lb-fresh-session] sets it. The cache stored only text, so a restored suggestion could never be topped up.

### Fix

Both reconciler functions now return the session itself (host catch-up) or `session.advanced(by:)`, so all session state is preserved exactly as on acceptance. Suggestion-cache entries now store whether their suggestion may be topped up. Fresh generations and top-ups record it, and restoration applies it. Finished sentences stay closed: the flag is carried, never set.

### Regression coverage

- `CotypingContinuationTests/testTypingThroughKeepsTheTopUpThatAcceptingKeeps`: typed characters, published typing, and host catch-up after an optimistic accept must each equal the accepted session and remain eligible for a top-up.
- `CotypingContinuationTests/testTypingThroughAFinishedSuggestionLeavesItFinished`: negative control.
- `CotypingRehearsalTopUpTests/testTypingTheSuggestedWordsAsksForMoreJustAsAcceptingDoes`: the rehearsal asks for a top-up after typing through, as it does after Tab.
- `CotypingSuggestionAnchorCacheTests/testARestoredTailKeepsWhetherItMayBeToppedUp`: open and finished entries restore with their flags.

Each failed with its fix undone. The coordinator's own typing path is not driven in a unit test, because it draws the real overlay panel and samples the screen; it calls the tested reconciler functions directly.

## Comparison with cotabby

### Existing capabilities and meaningful differences

Both projects already contain in-process inference, token healing, adaptive debounce, cancellation, and prompt reuse for supported native state. LokalBot also exposes a streaming engine API. The important distinctions are how these capabilities are used in the live coordinator and how state remains tied to the writing session. See [LokalBot's local engine][lb-local-engine], [debounce policy][lb-debounce], [native reuse][lb-runtime-reuse], and cotabby's [runtime architecture][ct-runtime-architecture] and [debounce policy][ct-debounce].

| Area | LokalBot at reviewed revision | cotabby at reviewed revision | Practical implication |
| --- | --- | --- | --- |
| Live partial presentation | Live coordinator awaits `engine.generate(request)` and presents the normalized result as a whole | Collects partials for typing prediction and can display partials when enabled | Internal progress collection can support reuse even if visible streaming stays off |
| Input arriving during generation | Without a matching visible session, new input schedules replacement work and cancels pending generation | Retains compatible in-flight predictions, records typed appends, and validates their exact AX publication before rebasing output | Potential to reduce repeated decoding while the user types along the prediction |
| Navigation identity | Suggestion and prewarm anchors share AX/frame-first identity; title/placeholder surface cache had no age bound on this path (now 1 s) | Separate polling/session values include fresh navigation metadata and a focus-change sequence | Useful reference for F02 and context invalidation |
| OCR context capture | Visual-caret recovery crops a display rectangle after an initial field policy check | OCR context screenshot service captures a window of the focused process and checks cancellation; its pixel-caret paths crop the display | Useful capture-scope reference for F03, with the caveats above |
| Native cache restoration | Partial reuse is disabled for recurrent/hybrid models; unavailable reuse falls back to a full prefill | The app trims to the shared prefix; native code in a pending upstream patch keeps one bounded checkpoint for recurrent/hybrid or sliding-window state; misses fall back cold | Potential performance improvement that requires runtime compatibility and correctness validation |

### Reusing a prediction while typing

LokalBot's [live generation call][lb-memory-prompt] waits for the whole result, although [`generateStreaming` exists in the engine][lb-local-engine]. [Scheduling new work][lb-input-restart] cancels the pending generation.

Cotabby's [`dispatchGeneration`][ct-dispatch] collects partial output when either visible streaming or internal typing prediction needs it. [`SuggestionCoordinator+TypingPrediction`][ct-typing-coordinator] and [`TypingPredictionCandidate`][ct-typing-candidate] retain compatible direct appends and require the exact edit to appear in the live field before rebasing the result. Retention is off for its OpenAI-compatible engine, secure fields and selections.

A reasonable follow-up is to retain work only while session identity, suffix/selection, and typed-prefix matching remain valid. Measure the effect using the same models, prompts, hardware, typing traces, and permission state. Keep internal prediction reuse independently configurable from visible partial presentation.

### Native checkpoint restoration

LokalBot sets `supportsPartialReuse` to false for recurrent/hybrid models at [model load][lb-runtime-capability]. Its [prefill path][lb-runtime-prefill] skips speculative native prefill for those models, and [generation][lb-runtime-reuse] clears state and decodes the whole prompt when partial reuse is unavailable.

Cotabby's [architecture description][ct-checkpoint-design] specifies one size-capped in-memory checkpoint near the prompt tail, at most eight replay tokens, and a cold fallback on a miss, for recurrent/hybrid or sliding-window models. App-side, [`obtainAutocompleteSequence`][ct-obtain-sequence] computes the shared prefix, asks the engine to trim the cache to it, and rebuilds cold when that fails. The checkpoint save and restore are native code in [a pending upstream patch][ct-checkpoint-patch] to its inference package (8 tail tokens, 128 MiB cap). This review did not check whether cotabby's pinned inference package includes that patch.

This is an architectural opportunity, not a finding that LokalBot's conservative fallback is incorrect. Do not enable partial reuse simply by removing its model-family check. First verify the pinned native runtime's restoration contract, cancellation behavior, context-window edge cases, and output equivalence against a cold run.

There is no evidence from this review that replacing LokalBot's model is necessary. Correctness and privacy fixes should precede performance experiments.

## Recommended implementation order

| Order | Work | Completion evidence |
| --- | --- | --- |
| 1 | Done: make the caret wait return at its deadline (F04) | Slow-work and cancellation tests establish the deadline |
| 2 | Done: preserve extension state across typing, host publication and cache restoration (F05) | Equivalent typing/acceptance sequences retain equivalent extension behavior |
| 3 | Done: bound surface-metadata freshness (partial F02) | A cached title older than a second is read again; one suggestion's reads share a capture |
| 4 | Introduce navigation-aware writing-session identity (F02) | Identical-text navigation invalidates pending, visible, and cached results while ordinary typing remains stable |
| 5 | Bind caret capture to the authorized window/session; close cancellation and policy races (F03) | Synthetic capture-boundary tests reject unauthorized work; hosted/remote host interaction check |
| 6 | Re-filter saved-memory selections against the current query and session (F01) | Delayed-provider test proves an old topic cannot enter a new topic's request, while a growing draft keeps its facts |
| 7 | Evaluate compatible in-flight prediction reuse and native checkpoint support | Controlled latency/quality results and native-state parity checks |

F04, F05 and the surface-metadata bound went first because each was a small change that unit tests could cover fully. F01–F03 address different boundaries and should all be completed. A stronger session identity will not by itself fix a topic change within the same session, or bind a display crop to an authorized window.

### Regression matrix

| Finding | Status | Test layer | Required scenario | Required assertion |
| --- | --- | --- | --- | --- |
| F01 | Proposed | Lookup/coordinator non-UI test | Atlas completed; Borealis pending under the same anchor | Next prompt contains no Atlas-only facts |
| F01 | Proposed | Lookup/coordinator non-UI test | Draft grows from one topic to two | Still-relevant facts are kept |
| F01 | Proposed | Lookup/coordinator non-UI test | Older lookup finishes after a newer one; new query is empty/no-match | Older selection cannot become current; irrelevant facts stay absent |
| F02 | Added | Surface-cache non-UI test | Same composer key, title changed behind it | Read again after the bound; one suggestion's reads share a capture |
| F02 | Proposed | Identity/coordinator non-UI test | Same AX key/frame/text, changed title, placeholder, or URL | Old generation, active context, suggestion, and cache entry are invalidated |
| F02 | Proposed | Identity control test | Same conversation; normal typing or line-wrap resize | Valid session is retained |
| F02 | Proposed | Hosted/remote UI test | Navigate two synthetic conversations that reuse a composer | Old ghost cannot appear or be accepted in the second conversation |
| F03 | Proposed | Injected capture/OCR test | Allowed target changes to excluded/secure target during an await | No unauthorized capture/OCR starts; late results cannot update caret state |
| F03 | Proposed | Hosted/remote UI test | Overlapping window or app switch during synthetic caret recovery | Only authorized window pixels are eligible; fallback works when target is uncertain |
| F04 | Added | Async non-UI test | Pending operation outlives deadline | Wait returns at the deadline within scheduling tolerance |
| F04 | Added | Async non-UI test | Cancelled caller | Wait ends promptly |
| F04 | Proposed | Async non-UI test | Late completion after navigation | No state mutation in a new session |
| F05 | Added | Session/extension non-UI test | Accept versus type the same prefix; host catch-up; rehearsal; cache restore | Remaining text and extension state stay consistent |
| F05 | Added | Negative control | Finished suggestion typed through | No unwanted extension |

For bugs confirmed to have reached users, follow the repository's [testing requirements][lb-testing]: add the behavioral check that would have caught the issue and demonstrate that it fails with the fix undone. Any changed existing test expectations should be listed with their reason in the implementation PR. Host-level UI tests belong on hosted CI or a remote runner.

## Validation performed

### Review, 2026-10-08

The two completed `.xcresult` bundles report:

| Batch | Selected test classes | Passed | Failed | Skipped |
| --- | --- | ---: | ---: | ---: |
| Coordinator/context | `CotypingCoordinatorTests`, `CotypingSuggestionExtensionTests`, `CotypingMemoryLookupTests`, `CotypingSurfaceContextTests` | 58 | 0 | 0 |
| Continuation/identity | `CotypingContinuationTests`, `CotypingFocusPrewarmIdentityTests`, `CotypingAXFocusIdentityKeyTests`, `CotypingRehearsalTopUpTests` | 54 | 0 | 0 |
| Total | Eight selected classes | **112** | **0** | **0** |

Both bundles reported `Passed`, with zero expected failures and no runtime warnings in their test summaries. These were focused non-UI tests, not the entire repository suite.

The tests built from a temporary source copy with a freshly generated Xcode project because the local project omitted newer source files. All **82 Swift files under `LokalBot/Cotyping`** matched the original checkout by SHA-256. This establishes a tested source snapshot, not installed-app validation.

### Validation, 2026-10-09

- Every cited LokalBot line range was re-read at master `1ade074` and points at the described code.
- The probe's copies of production files were compared by SHA-256. Six were byte-identical to the repository; `CotypingSessionReconciler.swift` differed only by the removed replacement planner, as described.
- Both result bundles were re-read: 58 and 54 passed, 0 failed.
- The cotabby claims were rechecked in a clone at `8cdbea2`. One was wrong and four line ranges were imprecise; both are corrected above.
- F04 was reproduced with an independent harness (table in F04).

### Fix tests, 2026-10-09

- With the fixes undone behind the new entry points, the new regression tests failed as listed under F04 and F05, and their controls passed.
- With the fixes, the seven directly affected test classes ran 121 tests, 0 failures. All 89 Cotyping and local-runtime test classes then ran 733 tests: 731 passed, 2 skipped, 0 failed. `CotypingMemoryRelevanceTests`, `LlamaCotypingRuntimeTests` and `LocalLlamaCotypingEngineTests` were excluded locally because they read repository fixtures or models and hang in local worktree runs; hosted CI runs the full suite.
- `swiftlint lint --strict` on the changed files reported nothing.
- After the F02 partial fix, its new test failed with the age limit removed. All 89 classes then ran 734 tests: 732 passed, 2 skipped, 0 failed.

### Probe output

The following output from the 2026-10-08 probes is retained here because their temporary files are not kept:

```text
TYPE_THROUGH: originalOpen=true typedOpen=false typedShouldExtend=false acceptedShouldExtend=true remaining=report tomorrow
PUBLISHED_TYPING: open=false shouldExtend=false
NAVIGATION: sameAnchor=true oldGenerationAccepted=true oldSessionAccepted=true
SURFACE_CACHE: after24Hours=Atlas conversation
MEMORY_QUERY_CHANGED: oldFact=Atlas private launch is Thursday
UNICODE_INSERT_EVENT: requestedUTF16=53 cgUTF16=53 appKitUTF16=53 appKitText=Please send the complete report to the team tomorrow.
VISUAL_CARET_TIMEOUT: budgetMs=30 pendingMs=450 elapsedMs=469
```

The harness copied the relevant production models and policies. Unrelated dependencies were simplified: field style, visible-context snapshot, memory query/snapshot, a sentence-boundary helper, and the AX prefix-window constant. The reconciler harness excluded the unrelated replacement planner. The timeout probe extracted the method body unchanged into a standalone type with a synthetic pending task.

These substitutions limit the conclusions to the exercised transitions. Production source inspection connects those transitions to the live coordinator; the probes are not a full end-to-end reproduction.

### Investigated hypothesis not promoted to a finding

A synthetic 53-UTF-16-unit insertion string survived both `CGEvent` and `NSEvent` conversion with all 53 units intact. The event was **not posted** to another application. This did not establish a general host insertion guarantee, but it did not support the suspected fixed-length truncation at event construction, so long-insertion truncation was not reported as a confirmed bug.

### Remaining validation limits

- F03 was established by source-path analysis; its app-switch/occlusion scenario was not reproduced against live windows.
- No local UI tests were run. The hosted UI suite runs when the pull request is marked ready for review.
- The F04 and F05 fixes have not been exercised in the installed app. The coordinator's typing path is covered only through the functions it calls.
- No controlled comparative benchmark, installation, or release was performed.
- F01 and F03 remain unimplemented, and F02 is only partly addressed.

## Source references

All references resolve to the reviewed commits rather than moving branches.

[lb-privacy-memory]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/PRIVACY.md#L389-L419
[lb-privacy-caret]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/PRIVACY.md#L379-L387
[lb-memory-lookup]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingMemoryLookup.swift#L23-L36
[lb-memory-lookup-intent]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingMemoryLookup.swift#L3-L5
[lb-latest-memory]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L543-L567
[lb-memory-prompt]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L167-L202
[lb-memory-freshness]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingMemoryContextProvider.swift#L20-L33
[lb-memory-query]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingMemoryContext.swift#L176-L188
[lb-memory-select]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingMemoryContext.swift#L246-L262
[lb-field-identity]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingFieldIdentity.swift#L9-L42
[lb-surface-capture]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingAXHelper.swift#L740-L792
[lb-surface-age]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingSurfaceCaptureSingleFlight.swift#L43-L107
[lb-ax-cache-state]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingAXHelper.swift#L66-L76
[lb-field-context-cache]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingFieldContextCache.swift#L3-L57
[lb-anchor-cache]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingSuggestionAnchorCache.swift#L4-L11
[lb-engine-surface]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingEngine.swift#L43-L49
[lb-content-signature]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingModels.swift#L74-L86
[lb-reconciliation-identity]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingSessionReconciler.swift#L30-L111
[lb-focus-change]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BInput.swift#L43-L85
[lb-generation-validation]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L328-L356
[lb-acceptance-context]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BAcceptance.swift#L7-L35
[lb-tab-accept]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BAcceptance.swift#L102-L129
[lb-host-publish]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BInput.swift#L114-L148
[lb-prewarm-test]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBotTests/CotypingFieldIdentityTests.swift#L30-L40
[lb-context-test]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBotTests/CotypingCoordinatorTests.swift#L87-L100
[lb-prepare-caret]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L475-L483
[lb-visual-refresh]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingVisualCaret.swift#L239-L261
[lb-visual-capture]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingVisualCaret.swift#L307-L327
[lb-caret-locate]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingVisualCaret.swift#L64-L97
[lb-stop-caret]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BLifecycle.swift#L118-L128
[lb-completion-wait]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L218-L235
[lb-caret-budget]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator.swift#L111-L113
[lb-caret-wait]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingVisualCaret.swift#L274-L283
[lb-writing-flow]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/DEVELOPMENT.md#L152-L162
[lb-typing-reconciliation]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingSessionReconciler.swift#L125-L191
[lb-rehearsal-typing]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingContinuationAcceptance.swift#L176-L191
[lb-session-model]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingModels.swift#L208-L230
[lb-extension-policy]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingSuggestionExtension.swift#L29-L45
[lb-cache-restore]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L409-L444
[lb-fresh-session]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BPrediction.swift#L397-L405
[lb-local-engine]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/Llama/LocalLlamaCotypingEngine.swift
[lb-debounce]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingDebouncePolicy.swift
[lb-input-restart]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/CotypingCoordinator%2BInput.swift#L92-L104
[lb-runtime-capability]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift#L201-L210
[lb-runtime-prefill]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift#L273-L288
[lb-runtime-reuse]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/LokalBot/Cotyping/Llama/LlamaCotypingRuntime.swift#L504-L547
[lb-testing]: https://github.com/stevyhacker/lokalbot/blob/b85d145d83087bf45dab61606b9026a0cc6c32c7/DEVELOPMENT.md#L280-L299
[ct-polling]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Support/Focus/FocusedInputPollingSignature.swift#L4-L47
[ct-session]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Models/Focus/FocusModels.swift#L22-L29
[ct-visual-context]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Services/Visual/VisualContextCoordinator.swift#L290-L304
[ct-window-capture]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Services/Visual/WindowScreenshotService.swift#L65-L139
[ct-pixel-caret]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Services/Presentation/PixelCaretLocator.swift#L665-L667
[ct-baseline]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Services/Presentation/HostBaselineCalibrator.swift#L520-L522
[ct-dispatch]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/App/Coordinators/Suggestion/SuggestionCoordinator%2BPrediction.swift#L392-L438
[ct-typing-coordinator]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/App/Coordinators/Suggestion/SuggestionCoordinator%2BTypingPrediction.swift
[ct-typing-candidate]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Support/Suggestion/Streaming/TypingPredictionCandidate.swift
[ct-runtime-architecture]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/ARCHITECTURE.md#L245-L286
[ct-debounce]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Support/Suggestion/Request/DebouncePolicy.swift
[ct-checkpoint-design]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/ARCHITECTURE.md#L277-L286
[ct-obtain-sequence]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/Cotabby/Services/Runtime/Llama/LlamaRuntimeCore.swift#L564-L653
[ct-checkpoint-patch]: https://github.com/FuJacob/cotabby/blob/8cdbea2d2619b0f89a73d46eb0bb856504d07343/patches/cotabbyinference-upstream-pending.patch#L180-L290
