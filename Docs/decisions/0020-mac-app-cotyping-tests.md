# 0020. Mac app: Cotyping tests

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBotTests/Cotyping/`.

## Decisions

### `LokalBotTests/Cotyping/CotypingAcceptanceChunkerTests.swift`

#### Default matches Cotypist: punctuation after a word takes its own press
`CotypingWordAcceptanceTests.testDefaults`: Cotypist's default: punctuation after a word takes its own press.

### `LokalBotTests/Cotyping/CotypingAutocorrectTests.swift`

#### Flagged but completable mid-word fragment runs LLM continuation, not autocorrect
`CotypingAutocorrectTests.testTypoGateProceedsForCompletableMidWordFragment`: "follo" is flagged by the spell checker but is a live prefix of
"follow": it is an unfinished word, so the LLM continuation must run
(Cotypist's core mid-word behavior) instead of an autocorrect offer.

#### Fragment no dictionary word starts with is a real typo and gets a correction
`CotypingAutocorrectTests.testTypoGateStillCorrectsUncompletableMidWordFragment`: No dictionary word starts with "recieve" — mid-word or not, this is a
real typo and the correction must be offered.

#### Trailing space means word is done; correct it without consulting completability
`CotypingAutocorrectTests.testTypoGateIgnoresCompletabilityOnceWordIsFinished`: A trailing space means the word is done: even a fragment that would
be completable mid-word ("follo" → follow) must be corrected, and the
completability check must not even be consulted.

### `LokalBotTests/Cotyping/CotypingAvailabilityTests.swift`

#### Code fields named only by placeholder or label once got suggestions
`CotypingCodeFieldDetectorTests.testCodeFieldNamesAreRecognized`: A verification code field named only by its placeholder or `<label>`
got suggestions.

### `LokalBotTests/Cotyping/CotypingBenchmarkCriteriaTests.swift`

#### Whitespace-leading completion after a fragment (follo up) is the bug class guarded
`CotypingBenchmarkCriteriaTests.testWhitespaceLeadingTextFailsWordCompletion`: " up" after "follo" would insert "follo up" — the exact bug class the
criterion exists to catch.

#### Confidence gate staying quiet is a missed suggestion, not harm
`CotypingBenchmarkCriteriaTests.testSilenceIsSafeButOnlyAllowedSilenceIsNotWithheld`: The confidence gate staying quiet is a missed suggestion, not harm.

#### A wrong word tail corrupts the word when letters follow the caret
`CotypingBenchmarkCriteriaTests.testExpectedCompletionPrefixesConstrainTheTail`: ...but corrupts the word when letters follow the caret.

#### side_by_side.py parses these JSON report keys; renaming breaks A/B evaluation
`CotypingBenchmarkCriteriaTests.testJSONReportCarriesWordCompletionCounters`: side_by_side.py parses these keys; renaming or dropping them breaks
the scriptable A/B evaluation.

#### External tooling filters scenario ids; keep wc-follow and mid-word scenarios
`CotypingBenchmarkCriteriaTests.testDefaultScenariosKeepCotypistParityIds`: External tooling filters on these ids; the parity suite must retain a
word-completion scenario and the mid-word safety scenario.

### `LokalBotTests/Cotyping/CotypingBenchmarkTests.swift`

#### Mid-word is a word-completion scenario; allowed suppression passes safety but is no hit
`CotypingBenchmarkTests.testEvaluatorAllowsExpectedSuppressionForSafetyScenario`: Mid-word is a word-completion scenario since the Cotypist-parity
work: an allowed suppression still passes safety, but does not
count as a completion hit.

### `LokalBotTests/Cotyping/CotypingChatReplySpacingTests.swift`

#### Chat models omit the space before a new word; replies from OpenRouter 2026-10-15
`CotypingChatReplySpacingTests`: Chat models often leave out the space before a new word. The replies here
are what OpenRouter returned on 2026-10-15 for the rehearsal text.

### `LokalBotTests/Cotyping/CotypingContextReportTests.swift`

#### Screen memory switch looked active but did nothing while Overnight review was off
`CotypingContextReportTests.testScreenMemoryIsAvailableWhileOvernightReviewIsOff`: The switch used to look active while Overnight review, turned off,
silently kept it from doing anything.

### `LokalBotTests/Cotyping/CotypingContinuationAcceptanceTests.swift`

#### One accept keypress is planned once for both live tap and Settings rehearsal
`CotypingContinuationAcceptanceTests`: One accept keypress, planned once for both the live accept tap and the
Settings rehearsal.

#### One word per accept once inserted the whole suggestion on first Tab
`CotypingRehearsalTests.testOneWordPerAcceptKeepsTheRestOfTheSuggestion`: "One word" used to insert the whole suggestion on the first Tab.

#### Editor reporting accepted text back is not a stale edit
`CotypingRehearsalTests.testOneWordPerAcceptKeepsTheRestOfTheSuggestion`: The editor reports the accepted text back; that is not a stale edit.

#### Piece-by-piece accept must reproduce suggestion for accents, emoji, punctuation, unspaced scripts
`CotypingRehearsalTests.testAcceptingPieceByPieceReproducesTheSuggestion`: Accepting piece by piece must reproduce the suggestion exactly, for
accents, emoji, punctuation runs and scripts written without spaces.

### `LokalBotTests/Cotyping/CotypingCoordinatorTests.swift`

#### Coordinator needs live AX and taps; tests pin permission-free paths only
`CotypingCoordinatorTests`: Most of the coordinator needs live AX + event taps, so these tests pin the
paths that run before any permission check: the settings gate in
`applySettings()` (which must bail out without touching AX) and the
permission-free `previewSuggestion` pipeline the in-app playground uses.

#### Test counters must never be the installed app's saved ones
`CotypingCoordinatorTests.stats`: Counters for this test only: never the installed app's saved ones.

#### Visible context is on for new installs; test starts without the grant
`CotypingCoordinatorTests.testRehearsalOffersTheSampleConversationOnlyWithTheVisibleTextGrant`: On for new installs; this test starts without the grant.

#### Setup sample stays free of every optional context source
`CotypingCoordinatorTests.testRehearsalOffersTheSampleConversationOnlyWithTheVisibleTextGrant`: The setup sample stays free of every optional source.

#### Rehearsal keys also reach the live pipeline, whose generation moves during a server reply
`CotypingCoordinatorTests.testKeysTypedIntoTheRehearsalDoNotDropItsSuggestion`: A key typed into the rehearsal also reaches the live pipeline, whose
generation moves while a server is still answering.

#### Insertion check used to stay open, keeping compared text in memory
`CotypingCoordinatorTests.testAnInsertionCheckExpiresWithoutAnotherEvent`: With no further key or focus change the check used to stay open, and
the text it compares stayed in memory.

#### Typing on keeps the check open since inserted text is still readable
`CotypingCoordinatorTests.testAKeyThatChangesTheTextBeforeTheCaretClosesAnOpenCheck`: Typing on leaves the check open: the inserted text is still there to read.

#### Undo, backspace or caret move means insertion can no longer be read back
`CotypingCoordinatorTests.testAKeyThatChangesTheTextBeforeTheCaretClosesAnOpenCheck`: Taking the text back, or moving the caret, means it can no longer be read back.

#### Accept without recorded suggestion counts words but not as used, capping share at 100%
`CotypingCoordinatorTests.testAnAcceptWithoutAShownSuggestionIsNotCountedAsUsed`: An accept with no suggestion on record still counts its words, but
never as a used suggestion, so the share used cannot pass 100%.

#### Deletions, other keys and pauses break the run; not typing speed
`CotypingCoordinatorTests.testTypingIsCountedOnlyWhereAutocompleteCouldSuggest`: Deletions, other keys and pauses break the run; they are not typing speed.

#### Typo-fix suggestions are instant and excluded from suggestion latency
`CotypingCoordinatorTests.testKeystrokeToVisibleIsMeasuredOncePerKeystroke`: A typo fix is instant and says nothing about suggestion latency.

#### No ghost on screen in unit tests, so nothing may be appended
`CotypingCoordinatorTests.testATopUpIsOnlyAppliedToTheSuggestionOnScreen`: No ghost is on screen in a unit test, so nothing may be appended.

#### 2026-10-09: Chrome ghost stayed over typed letters until browser published them
`CotypingCoordinatorTests.testAKeyThatLeavesTheSuggestionTakesItDownAtOnce`: The 2026-10-09 report: in Chrome the ghost stayed on screen over the
letters just typed until the browser published them, which takes a
while there. A key that leaves the suggestion takes it down at once.

#### Suggestion with no place to go is dropped, not drawn elsewhere
`CotypingCoordinatorTests.testASuggestionWithNowhereToBeShownIsDropped`: A suggestion with nowhere on screen to go that covers no text is
dropped, not drawn somewhere else: here a guessed caret in a field
that reports no frame, so a popup has no outside to go to.

#### Idle suggestion must go down so Tab reaches the app (Cotypist 2026.5 fix)
`CotypingCoordinatorTests.testASuggestionLeftAloneIsTakenDownSoTabReachesTheApp`: Cotypist 2026.5 fixed a suggestion staying up after a minute without
typing and taking the Tab meant for the app.

#### Checks sit 800 ms from the deciding moment so slow runners cannot flip them
`CotypingCoordinatorTests.testASuggestionLeftAloneIsTakenDownSoTabReachesTheApp`: Each check sits 800 ms from the moment that would change its answer,
so a slow runner cannot decide it.

#### Typing through a suggestion counts as activity and restarts its lifetime clock
`CotypingCoordinatorTests.testASuggestionLeftAloneIsTakenDownSoTabReachesTheApp`: Typing through the suggestion is activity, so the clock starts again.

#### Clicking into another field left state ready, blocking read-ahead of new field
`CotypingCoordinatorTests.testFocusLeavingAShownSuggestionGoesIdleAndPrewarmsTheNewField`: Clicking into another field took the suggestion down but left the
state at "ready", which kept the new field from being read ahead.

#### Focus change used to replace the meeting-recording pause label with idle
`CotypingCoordinatorTests.testTheMeetingPauseLabelSurvivesAFocusChange`: Moving between fields during a recording replaced "Paused while a
meeting is recording." with the idle state.

#### Only one pending caret re-read, none once its suggestion is gone
`CotypingCoordinatorTests.testOnlyTheLatestCaretRereadRuns`: One pending re-read of the caret at a time, and none once the
suggestion it was for is gone.

#### First suggestion after 30 min took 1.9 s vs 62 ms; any key readies the model
`CotypingCoordinatorTests.testAKeyAfterAPauseReadiesTheModel`: The first suggestion after half an hour without typing took 1.9 s
against 62 ms (2026-10-06): the model had gone cold. Any key readies
it, as clicks and unlocking do, before the suggestion is asked for.

#### Typing asks to ready the model once per interval; engine skips recently run model
`CotypingCoordinatorTests.testActivityAsksToReadyTheModelAtMostOncePerInterval`: Typing asks at most once per interval; the engine itself skips a
model that ran recently.

#### Model is left alone while autocomplete is stopped or a meeting records
`CotypingCoordinatorTests.testTheModelIsLeftAloneWhileStoppedOrRecording`: Autocomplete is paused during a meeting recording and while stopped,
so the model is left alone then.

### `LokalBotTests/Cotyping/CotypingFieldStyleTests.swift`

#### Host foreground flattened to background must not paint invisible ghost text
`CotypingFieldStyleTests.testResolvedGhostColorOverridesForegroundIndistinguishableFromBackground`: A host fg flattened to the background color (wrong-appearance capture)
must not paint invisible text — synthesize a legible hint instead.

#### Measured-dark background flips ghost to a light hint (the reported bug)
`CotypingFieldStyleTests.testMeasuredLuminanceDrivesGhostContrast`: Measured-dark background → flip to a light hint (the reported bug).

#### Retina strip: far end counts as much as the caret end
`CotypingFieldStyleTests.testAverageLuminanceCoversTheWholeStrip`: A Retina strip's worth of pixels: the far end counts as much as the caret's.

#### 32 px wide output letterboxed strips in black; use the strip's own pixel size
`CotypingFieldStyleTests.testTheBackgroundCaptureIsTheWholeStripAtItsOwnPixelSize`: A 32-pixel-wide output letterboxed some strips in black (2–4 columns,
measured), darkening the background; the strip's own pixel size never does.

#### Off-display pixels come back black, so capture stops at the display edge
`CotypingFieldStyleTests.testTheBackgroundCaptureStopsAtTheDisplayEdge`: Off-display pixels come back black, so the strip stops at the edge.

#### Luminance readings are per field, not per app (dark Reddit box got black ghosts)
`CotypingBackgroundSamplerTests.testReadingFromOneFieldIsNotReusedInAnotherFieldOfTheSameApp`: 2026-10-21: a reading from a light page in Chrome drew black ghosts in
a dark Reddit comment box, because readings were kept per app.

#### Chrome hands out new elements per read; field reading must outlive that
`CotypingBackgroundSamplerTests.testReadingIsReusedWhileTypingInTheSameField`: Chrome hands out a new element on every read; the field's reading
must outlive that, or every suggestion would sample and recolor.

### `LokalBotTests/Cotyping/CotypingInserterTests.swift`

#### Inserter posts real CGEvents; only non-posting guards unit tested, rest in UI test
`CotypingInserterTests`: The inserter posts real CGEvents into whatever has focus, so only its
non-posting surface is testable: the synthetic-event marker and the
scrub-then-bail guards that must reject no-op inserts before any event
exists. Everything past those guards types into the frontmost app and is
covered by the Cotyping UI test instead.

### `LokalBotTests/Cotyping/CotypingMacroTests.swift`

#### Fixed clock 2026-06-23 14:30 UTC Tuesday, en_US, injected RNG and UUID
`CotypingMacroTests.fixedEngine`: Deterministic engine: fixed clock (2026-06-23 14:30 UTC, a Tuesday), UTC
calendar, en_US locale, and an injected RNG/UUID.

#### Bundled offline currency rates in tests: USD=1.0, EUR=0.92
`CotypingMacroTests.testCurrencyConversion`: Currency (bundled offline rates: USD=1.0, EUR=0.92)

### `LokalBotTests/Cotyping/CotypingMarkerSelectionTests.swift`

#### Chromium value has paragraph line breaks; selection and AXStringForRange omit them
`CotypingParagraphBreakAlignmentTests`: Chromium's value has a line break between paragraphs; its selection
and `AXStringForRange` count the text without it.

#### 2026-10-21 Reddit in Chrome: caret split one character early
`CotypingParagraphBreakAlignmentTests.testTheCaretLandsAfterTheLastTypedCharacter`: 2026-10-21, Reddit in Chrome: split at the reported offset, the caret
came out one character early, so the suggestion after "elabor" began
"rate" and showed in a popup over the text.

#### A br counts in both offsets; adjacent paragraph break is only in value
`CotypingParagraphBreakAlignmentTests.testALineBreakNextToAParagraphBreakIsMatchedOnce`: A `<br>` is a line break in both counts; a paragraph break next to it
is only in the value.

#### Accept must read the field like the snapshot; AXStringForRange windows lack paragraph breaks
`CotypingParagraphBreakAlignmentTests.testAnAcceptReadLikeTheSnapshotMatchesIt`: Tab is checked against a second read of the field. Read the way the
suggestion's snapshot was, it matches; the `AXStringForRange` windows
the accept used to read have no paragraph breaks and never match when
paragraphs surround the caret, so Tab was refused there.

#### Chromium marker attributed string has AXFont with only size, color as CGColor
`CotypingWebFieldStyleTests.testChromiumFontSizeAndColorAreRead`: Chromium's marker-based attributed string has an `AXFont` with only a
size, and the text color as a `CGColor`.

#### Without extended accessibility Chromium sends an empty font
`CotypingWebFieldStyleTests.testAnEmptyChromiumFontIsNoStyle`: Without extended accessibility Chromium sends an empty font.

### `LokalBotTests/Cotyping/CotypingMemoryContextTests.swift`

#### Reading saved memory needs only writing switches; Overnight review only schedules
`CotypingMemoryContextTests.testSavedWorkMemoryIsReadUnderTheWritingGrantsAlone`: Reading what is already saved is granted by the writing switches alone.
The Overnight review switch only schedules new reviews.

#### Escaped retrieval: everyday words pulled an unrelated meeting's date
`CotypingMemoryContextProviderTests.testEverydayWordingDoesNotBorrowAnUnrelatedMeetingsDate`: Reproduces the escaped retrieval: a generic sentence picked up
"you on Friday" from a meeting it had nothing to do with, because the
two shared a pair of everyday words.

### `LokalBotTests/Cotyping/CotypingMemoryLookupTests.swift`

#### Mid-word typing needs no lookup; finished nameable word does; keep newest only
`CotypingMemoryLookupTests.testOnlyTheNewestLookupForTheFieldIsKept`: Typing inside a word asks for nothing new; a finished word that could
name something does, and only the newest lookup is kept.

### `LokalBotTests/Cotyping/CotypingMemoryRelevanceTests.swift`

#### Model-free evaluation: relevant drafts find their fact, distractors find nothing
`CotypingMemoryRelevanceTests`: The rules that decide whether a saved fact may reach a completion prompt,
and a model-free evaluation over the benchmark fixtures: every relevant
draft must find its fact, and every distractor must find nothing.

#### Work-memory goal is its own title; a statement, not a heading
`CotypingMemoryRelevanceTests.testALineThatOnlyRestatesItsTitleIsLeftOut`: A work-memory goal is its own title; it is a statement, not a heading.

#### Judging adds-nothing against the draft dropped the current fact; older one won
`CotypingMemoryRelevanceTests.testAnAnswerAlreadyInTheDraftDoesNotLetAnOlderFactWin`: A draft that already mentions the answer must still get the current
fact. Judging "adds nothing" against the draft dropped it, and the
older version of the same topic then won.

#### Test fixtures are copies of Benchmarks/autocomplete/Cotyping; see project.yml
`CotypingMemoryRelevanceTests.fixture`: Copies of Benchmarks/autocomplete/Cotyping fixtures; see project.yml.

#### Visible-context fixtures were frozen before rules changed; selections must hold
`CotypingMemoryRelevanceTests.testVisibleContextFixturesKeepTheirFrozenSelections`: The visible-context fixtures were frozen before these rules changed.
Their expected selections must hold with and without nearby text.

### `LokalBotTests/Cotyping/CotypingOverlayGeometryTests.swift`

#### 2026-10-09: small-drift hold left the ghost overlapping typed letters in Chrome and Viber
`CotypingOverlayGeometryTests.testAGhostThatCoversTypedTextAlwaysMoves`: The 2026-10-09 report: in Chrome and Viber the ghost kept overlapping
the letters just typed. A caret read a few points past the ghost's
start was held as "small drift", so the ghost stayed on those letters.

#### Ghost slightly ahead of caret is held only while app may still move caret after accept
`CotypingOverlayGeometryTests.testAGhostThatCoversTypedTextAlwaysMoves`: A ghost a few points ahead of the caret is held only while the app
may still be moving its caret after an accept.

#### 2026-10-05: GitHub review box in Chrome gave no exact caret; popup covered first line
`CotypingOverlayGeometryTests.testAnEstimatedCaretsPopupNeverCoversTheField`: The 2026-10-05 report: a GitHub review box in Chrome gave no exact
caret, and the popup was drawn under a guess at the field's top-left
corner, across the first line of text. Cocoa coordinates; the guess is
the resolver's fallback, 4 pt in and 22 pt tall at the field's top.

#### AppKit caret is one default line tall; ghost sits on that baseline, not center
`CotypingOverlayGeometryTests.testAnAppKitCaretPutsTheGhostOnTheFieldBaseline`: AppKit text reports a caret one default line tall; the ghost sits on
that line's baseline, not on its center.

#### Web engines report about the glyph box; its center is the line center
`CotypingOverlayGeometryTests.testAWebCaretCentersTheGlyphBox`: Web engines report about the glyph box; its center is the line's center.

#### A top-up appends words; words already on screen keep their places
`CotypingOverlayGeometryTests.testAppendingWordsNeverMovesWordsAlreadyShown`: A top-up appends words; words already on screen keep their places.

#### Field geometry: 8 pt inset, lines x 48-232, baselines 502 and 488
`CotypingOverlayGeometryTests.roomyField`: A field tall enough for several lines, its text inset 8 pt: lines
run from x 48 to 232. A 12 pt Helvetica caret at y 499 puts the
baseline at 502 and the next line's at 488.

#### One-line chat box as in Viber or LinkedIn message box before it grows
`CotypingOverlayGeometryTests.oneLineField`: A chat box one line tall, as in Viber or a LinkedIn message box
before it grows.

#### 2026-10-09: typed space moved ghost by nothing; lone space measured as no text
`CotypingOverlayGeometryTests.testTypingASpaceMovesTheGhostByASpace`: The 2026-10-09 report: typing through a suggestion left the ghost
overlapping the letters typed. A typed space moved it by nothing,
because the ghost draws runs of spaces as one and measured a lone
space as no text at all, so every later letter landed on the ghost.

#### Accepted word that does not fit is wrapped by the app; caret goes to next line
`CotypingOverlayGeometryTests.testAWordThatWrapsWhenAcceptedTakesTheCaretToTheNextLine`: An accepted word that does not fit after the caret is wrapped by the
app, so the caret goes to the start of the next line, after the word.

#### A word whose start still fits stays on the line
`CotypingOverlayGeometryTests.testAWordThatWrapsWhenAcceptedTakesTheCaretToTheNextLine`: The start of that word still fits, so the app keeps it on the line.

#### Rest of a word moves with its start, so no caret derivation
`CotypingOverlayGeometryTests.testAWordThatWrapsWhenAcceptedTakesTheCaretToTheNextLine`: The rest of a word the app is about to move along with its start.

#### Rest of word that does not fit is not drawn; app moves whole word down
`CotypingOverlayGeometryTests.testTheRestOfAWordThatDoesNotFitIsNotDrawn`: The rest of the word at the caret, if it does not fit after it, has
no place on screen: the app will move the whole word down. It used to
be drawn at the start of the next line, right where that word lands
as soon as the next letter is typed.

#### One-line chat box: wrapped lines would draw over its toolbar; show only fitting words
`CotypingOverlayGeometryTests.testWrappedLinesStayInsideTheField`: A one-line chat box: wrapped lines would be drawn under it, over its
toolbar. Only the words that fit after the caret are shown.

#### Chromium returned the whole field as caret for a one-character message
`CotypingOverlayGeometryTests.testALineBoxIsNotTakenForTheCaret`: Chromium answered the caret query with the whole field for a
one-character message, and the ghost went to the line below.

#### Bitmap rows count down from top; view points count up
`CotypingGhostTextViewTests.inkRows`: Bitmap rows count down from the top; view points count up.

#### HELLO has no descenders so ink starts on baseline and rises to cap height
`CotypingGhostTextViewTests.testTheGhostIsDrawnOnTheRequestedBaseline`: "HELLO" has no descenders, so its ink starts on the baseline and rises
to about the cap height, beginning at the line's origin.

### `LokalBotTests/Cotyping/CotypingRenderModeTests.swift`

#### 2026-10-09: suggestion jumped between popup and line until caret found; now waits
`CotypingRenderModeTests.testAnEstimatedCaretThatWillBeFoundOnScreenIsWaitedFor`: The 2026-10-09 report: in Viber, which reports no caret at all, and
in Chrome text areas, the suggestion appeared above or below the field
until the caret was found on screen, then on the line, and back again.
Where the caret will be found, the suggestion waits for it.

### `LokalBotTests/Cotyping/CotypingRequestBuilderTests.swift`

#### SMS code typed in an unlabeled field got suggestions
`CotypingPrefixWindowTests.testNumbersWithoutLettersGetNoSuggestion`: An SMS code typed into an unlabeled field got suggestions.

#### Stable window start avoids re-reading whole window per keystroke
`CotypingPrefixWindowTests.testALongDraftsWindowStartStaysPutWhileTyping`: Typing on at the end of a long draft keeps the window's start in
place, so the model does not read the whole window again per keystroke.

#### Caret fragment plus spell verdict arm the normalizer's word-completion mismatch guard
`CotypingRequestBuilderTests.testCapturesWordPrefixAtCaretWithSpellVerdict`: The fragment at the caret plus the injected spell-checker verdict are
what arm the normalizer's word-completion mismatch guard downstream.

### `LokalBotTests/Cotyping/CotypingServerRouteTests.swift`

#### Choosing a server is consent; context toggles apply as set
`CotypingServerRouteTests.testAChosenServerGetsTheContextTheUserTurnedOn`: Choosing a server is the user's consent: the context toggles apply as
set, the same as on this Mac.

### `LokalBotTests/Cotyping/CotypingSessionReconcilerTests.swift`

#### Typing suggested words and accepting them are equivalent for top-up
`CotypingSessionReconcilerTests.testTypingThroughKeepsTheTopUpThatAcceptingKeeps`: Typing the suggested words and accepting them are the same to the
top-up: both keep the suggestion open, so the ghost stays ahead.

### `LokalBotTests/Cotyping/CotypingSettingsTests.swift`

#### Settings saved before the option load with it on, like a fresh install
`CotypingSettingsTests.testChromiumEnhancedAccessibilityIsOnByDefault`: Settings saved before the option existed load with it on, like a
fresh install: Chrome-based browsers get enhanced accessibility.

#### Chrome switches modes despite error; only timeout is re-asked to keep request count low
`CotypingSettingsTests.testOnlyATimeoutLeavesEnhancedAccessibilityUnasked`: Chrome switched modes even though the request reported an error, so
only a timeout leaves a browser to be asked again; asking again would
raise Chrome's request count past what one release takes back.

#### Version 4 moved two defaults to Cotypist's; user-chosen values are kept
`CotypingSettingsTests.testEarlierDefaultsMoveToTheCotypistOnesOnce`: Version 4 moved two defaults to what Cotypist does. Settings saved by
an earlier build follow; a value chosen since then is kept.

#### Max response tokens floor is 5
`CotypingSettingsTests.testMaxResponseTokensMirrorCotypistBudget`: floor

#### Max response tokens is ceil(words * 1.3)
`CotypingSettingsTests.testMaxResponseTokensMirrorCotypistBudget`: ceil(8 * 1.3)

#### Max response tokens is ceil(words * 1.3)
`CotypingSettingsTests.testMaxResponseTokensMirrorCotypistBudget`: ceil(20 * 1.3)

#### Multiline doubles the max response tokens
`CotypingSettingsTests.testMaxResponseTokensMirrorCotypistBudget`: doubled for multiline

#### Max response tokens is capped at 120
`CotypingSettingsTests.testMaxResponseTokensMirrorCotypistBudget`: cap

### `LokalBotTests/Cotyping/CotypingSpellLanguageGateTests.swift`

#### Stock macOS dictionaries lack sr/hr/bs; no spell-check for Serbian, Croatian, Bosnian, Montenegrin
`stockLanguages`: The stock macOS dictionary set (abridged): notably no sr/hr/bs — Serbian,
Croatian, Bosnian, and Montenegrin have no spell-check support at all.

#### Recognizer confidence on one-word fragments varies; gate needs multi-word evidence
`CotypingSpellLanguageGateTests.testAmbiguousShortContextKeepsVerdicts`: Recognizer confidence for one-word fragments varies by macOS model;
the gate must not stand down without multi-word language evidence.

#### Language identification uses text at the caret, not an earlier preamble
`CotypingSpellLanguageGateTests.testIdentificationWindowsToCaretContext`: An English preamble must not keep the gate armed once the text at
the caret is a full window of Serbian.

### `LokalBotTests/Cotyping/CotypingStatsTests.swift`

#### p95 index is round((n-1)*0.95)
`CotypingStatsTests.testDerivedLatencyStats`: idx = round(4*0.95) = 4

#### Counters saved before measurements existed must keep their values
`CotypingLiveMeasureTests.testOlderSavedCountersDecodeWithoutResetting`: Counters saved before the measurements existed must keep their values.

#### Continued typing or browser non-breaking space still counts as the same insertion
`CotypingLiveMeasureTests.testInsertionIsConfirmedWhenTheFieldShowsIt`: Typing that continued, or a browser's non-breaking space, is still the same insertion.

#### An empty field has no preceding text to anchor on
`CotypingLiveMeasureTests.testInsertionIsConfirmedWhenTheFieldShowsIt`: An empty field has no text before the caret to anchor on.

#### Half of a 16-character insertion once counted as confirmed
`CotypingLiveMeasureTests.testATruncatedInsertionIsNotConfirmed`: Half of a 16-character insertion used to count as confirmed.

### `LokalBotTests/Cotyping/CotypingSuggestionExtensionTests.swift`

#### Top-up keeps ghost two to five words ahead like Cotypist, replacing three-word reappearing
`CotypingSuggestionExtensionTests`: Topping up a suggestion while it is accepted. Cotypist keeps its ghost two
to five words ahead until the sentence ends; a suggestion that ran out
every three words and reappeared a moment later is what these rules replace.

#### One word short of limit counts as open-ended; token budget can end mid-word
`CotypingSuggestionExtensionTests.testOnlyOutputCutByTheLengthLimitIsContinued`: One word short still counts: the token budget can end before the last word is whole.

#### Typing part of next word does not change words left
`CotypingSuggestionExtensionTests.testATopUpStartsOnceTwoWordsAreLeft`: Typing part of the next word does not change how many words are left.

#### Additions must never alter words already on screen (number to numbers)
`CotypingSuggestionExtensionTests.testAnAdditionNeverChangesWordsAlreadyOnScreen`: "number" must not turn into "numbers" under the reader's eyes.

### `LokalBotTests/Cotyping/CotypingSurfaceContextTests.swift`

#### Chat composer is reused across conversations; window title must follow, reads share a capture
`CotypingSurfaceContextTests.testAComposerReusedAcrossConversationsReadsTheNewTitle`: Chat apps keep one composer across conversations. The window title the
prompt and the saved-fact lookup use must follow the conversation, not
stay as long as the field keeps focus; one suggestion's reads still
share a capture.

### `LokalBotTests/Cotyping/CotypingSurfaceGuardTests.swift`

#### Open and save dialogs stay quiet since a file name is not prose
`CotypingFileDialogDetectorTests`: Open and save dialogs stay quiet: a file name is not prose.

#### Go to Folder sheet has unnamed window on the panel
`CotypingFileDialogDetectorTests.testOpenAndSavePanelsAreRecognizedByTheirWindow`: Go to Folder: a sheet whose own window has no name, on the panel.

#### AppKit names panels save-panel and open-panel, read in-process without a window
`CotypingFileDialogDetectorTests.testAppKitStillNamesItsPanelsThisWay`: AppKit's own name for the panels, read in-process with no window shown.

#### macOS inline predictions compete with autocomplete at the caret
`CotypingSystemInlinePredictionsTests`: macOS's own inline predictions compete with autocomplete at the caret.

#### Leftover keyboard hooks from apps slow every keystroke
`EventTapAuditTests`: Keyboard hooks left behind by an app slow every keystroke on the Mac.

### `LokalBotTests/Cotyping/CotypingTextLeafCaretTests.swift`

#### Leaf-derived caret fallback for Chromium/Electron; numbers measured on Discord composer
`CotypingTextLeafCaretTests`: The leaf-derived caret fallback for Chromium/Electron editables. The main
scenario's numbers are real: measured via an AX probe against Discord's
message composer (Slate contenteditable) with the draft "test this u".

#### Draft/Slate keep trailing newline in value while caret stays at visible end
`CotypingTextLeafCaretTests.testTrailingNewlineFromContenteditableIsTolerated`: Draft/Slate keep a trailing "\n" in the reported value while the
caret index stays at the visible end of the text.

#### After Return the last run's edge is the line above, not the caret
`CotypingTextLeafCaretTests.testACaretOnANewLineAfterTheTextRefuses`: Return in a textarea starts a new line; the last run's edge is the end
of the line above, not the caret.

#### A run can omit a trailing typed space; caret is one space past the run
`CotypingTextLeafCaretTests.testASpaceTheRunLeavesOutMovesTheCaretOneSpace`: A run can stop before a space typed at the end of the text. The caret
is then one space past the run, so the suggestion does not touch the
last word.

#### Web editors keep a typed trailing space as a no-break space
`CotypingTextLeafCaretTests.testASpaceInsideTheRunIsNotCountedAgain`: Web editors keep a typed trailing space as a no-break space.

#### Wrapped text node reports one box; caret derivation refuses it
`CotypingTextLeafCaretTests.testARunThatWrapsOntoASecondLineRefuses`: A text node that wraps reports one box around all its lines. Its
trailing edge is the end of the widest line, and a caret that tall puts
the suggestion across both lines.

#### Trailing emoji or mention uncovered by runs would misplace ghost, so refuse
`CotypingTextLeafCaretTests.testFieldTextNotEndingWithLastRunRefuses`: A trailing emoji/mention the runs don't cover would put the caret
past the last text run — refuse rather than misplace the ghost.

#### TextEdit and Telegram report empty range a line high; Chrome gives no size
`CotypingCaretGeometryTests`: TextEdit and Telegram report the empty range at the caret one line above
where it is drawn, and Chrome reports it with no size; the character before
the caret is reported where it is.

#### AX coordinates are top-left origin; empty range sits a line high
`CotypingCaretGeometryTests.testTheCaretIsTheTrailingEdgeOfTheCharacterBeforeIt`: AX coordinates, top-left origin: the empty range sits a line high.

#### GitHub review box in Chrome: zero-size empty range once left only a corner guess
`CotypingCaretGeometryTests.testWithAZeroSizeEmptyRangeTheCharacterBeforeTheCaretPlacesIt`: A GitHub review box in Chrome: the empty range comes back with no size,
which used to leave only a guess at the field's top-left corner.

#### Without an empty range, a character is trusted only inside its field
`CotypingCaretGeometryTests.testWithoutAnEmptyRangeACharacterOutsideTheFieldIsRefused`: Without an empty range to agree with, a character is only trusted
inside its own field.

#### Field frame costs Accessibility calls; skip when empty range vouches for character
`CotypingCaretGeometryTests.testTheFieldFrameIsReadOnlyWithoutAnEmptyRange`: The field's frame costs Accessibility calls; it is not read when the
empty range already vouches for the character.

### `LokalBotTests/Cotyping/CotypingTextNormalizerTests.swift`

#### Completion on new line after Hi team, once lost its separating space
`CotypingTextNormalizerTests.testACompletionThatBeganOnANewLineKeepsOneSeparatingSpace`: "Hi team," followed by a completion the model put on a new line used
to come out as "Hi team,I'm working".

#### Space-leading completion after an invalid fragment would insert broken text
`CotypingTextNormalizerTests.testSuppressesWhitespaceLeadingCompletionAfterInvalidFragment`: "follo" is not a standalone word; " up on that" would insert
"follo up on that" — broken text the guard must reject.

#### A complete word fragment may be treated as finished with a new word
`CotypingTextNormalizerTests.testValidWordFragmentMayBeFollowedBySpace`: "the" is a complete word in its own right — the model may legitimately
treat it as finished and continue with a new word.

#### Inside a word the force path already strips space; new guard must stay out
`CotypingTextNormalizerTests.testForceWordContinuationPathUnchangedByWordPrefixFields`: Strictly inside a word the force path already strips the leading
space and validates the tail; the new guard must stay out of its way.

### `LokalBotTests/Cotyping/CotypingTypingLatencyBenchmarkTests.swift`

#### Opt-in keystroke replay benchmark of latency and re-decoded prompt tokens; env var invocation
`CotypingTypingLatencyBenchmarkTests`: Opt-in: replays typing one keystroke at a time through the in-process model
and reports how long each suggestion takes and how many prompt tokens had to
be decoded again. Skipped unless a model is named:

TEST_RUNNER_LOKALBOT_COTYPING_LATENCY_MODEL=/path/to/model.gguf \
xcodebuild test-without-building ... \
-only-testing:LokalBotTests/CotypingTypingLatencyBenchmarkTests

#### Idle-gap benchmark: env vars, warm-up modes, 45 ms key delay, use unmapped GGUF copy
`CotypingTypingLatencyBenchmarkTests.testFirstSuggestionAfterIdle`: Opt-in: how long the first suggestion takes after the person stops
typing for a while, against a keystroke while typing. For each pause in
`LOKALBOT_COTYPING_IDLE_GAPS` (seconds, e.g. `0,60,300,1800`) it types a
short burst, waits, times the next keystroke, then the same request
again as the warm reference. The run takes as long as the pauses add
up to, per warm-up mode.

`LOKALBOT_COTYPING_IDLE_WARMUP` lists warm-up modes (default `none`):
- `none`: nothing runs between the burst and the key.
- `key`: `touch` starts when the key lands and the suggestion is asked
  for 45 ms later, about the app's wait for the field to update plus its
  debounce. Timed from the request, like the others.
- `ahead`: `touch` finishes before the key, as it would from a focus
  change or unlock a moment earlier. Its own time is reported apart.
- `every<N>`: `touch` every N seconds during the pause, e.g. `every120`.

Use a copy of the GGUF (`cp -c`) that the installed app does not map:
the page cache is per file, and the app's own typing would keep it warm.
`LOKALBOT_COTYPING_IDLE_OUT` appends the report to a file.

#### Every pause ends on the same keystroke so modes compare; IDLE_KEY moves it
`CotypingTypingLatencyBenchmarkTests.testFirstSuggestionAfterIdle`: Every pause ends on the same keystroke ("…design team has time",
suggesting " to review the numbers."), so the work after it is the
same in every mode and pause, and the same request right after it is
the warm reference. `LOKALBOT_COTYPING_IDLE_KEY` moves it.

#### Key mode times from the request; the 45 ms wait is spent either way
`CotypingTypingLatencyBenchmarkTests.testFirstSuggestionAfterIdle`: Timed from the request, as in the other modes: the 45 ms
before it are spent waiting either way.

#### Fresh read-only mapping shares cached pages; mincore reads without faulting in
`CotypingTypingLatencyBenchmarkTests.residentFraction`: Share of the file's pages in memory now. A fresh read-only mapping
shares the file's cached pages and `mincore` reads them without
faulting any in.

### `LokalBotTests/Cotyping/CotypingUsageHistoryTests.swift`

#### Pauses longer than a second are not typing speed
`CotypingUsageHistoryTests.testTimeSavedUsesYourTypingSpeedOnceMeasured`: Pauses longer than a second are not typing speed.

### `LokalBotTests/Cotyping/CotypingVisibleContextTests.swift`

#### Field text read once, refreshed in background; keystrokes get previous read
`CotypingVisibleContextTests.testAStaleFieldContextIsServedWhileItRefreshesInTheBackground`: The text above a field is read once per field and then refreshed in
the background: a keystroke gets the previous read instead of waiting.

#### Empty field has no font yet; failed read must not be remembered
`CotypingVisibleContextTests.testAFontThatCouldNotBeReadIsNotRemembered`: An empty field has no font to read yet; the first typed character's
font must be read then, not hidden behind a remembered failure.

#### Nearby text can name a saved source but never counts as the user's own wording
`CotypingVisibleContextTests.testVisibleGenericVocabularyCannotRetrieveAnotherProjectsMemory`: The visible conversation names Willow. Its incidental words ("export",
"format") must not admit Mistral: nearby text can name a saved source
but never counts as the user's own wording.

#### Visible text is on for new installs only; older settings missing key mean off
`CotypingVisibleContextTests.testVisibleTextIsOnForNewInstallsOnly`: On for new installs only: settings saved by an earlier version keep
what they had, and a missing key there means off.

#### PRIVACY.md promises nearby text never comes from a private window
`CotypingVisibleContextTests.testPrivateWindowsAreNeverRead`: PRIVACY.md promises nearby text never comes from a private window.

### `LokalBotTests/Cotyping/CotypingVisualCaretInkTests.swift`

#### A caret right after a letter is the same ink run as the letter
`CotypingVisualCaretInkTests.testACaretTouchingTheLastLetterIsToldFromIt`: A caret right after the letter is the same run of ink as the letter.

### `LokalBotTests/Cotyping/CotypingVisualCaretTests.swift`

#### Visual caret is found from on-screen text; global Cocoa coordinates, y up
`CotypingVisualCaretTests`: The caret found from a field's text on screen, for Chrome text areas that
report no caret position. Global Cocoa coordinates (y up).

#### Fixture models a GitHub comment box: 797x103, 14 pt text inset 13 pt
`CotypingVisualCaretTests.field`: A GitHub comment box: 797×103 with 14 pt text inset 13 pt.

#### Recognized line spans first letter's ink start to last letter's ink end
`CotypingVisualCaretTests.line`: A line as recognition reports it: from where the ink of its first
letter starts to where the ink of its last one ends, for text drawn
from `origin`.

#### Caret sits where the last letter's advance ends, not its ink
`CotypingVisualCaretTests.end(of:)`: Where the caret is after `text` drawn from `origin`: where its last
letter's advance ends.

#### Use advance not ink end; ink end put ghost 0.6-0.8 pt over letter
`testTheCaretFollowsTheLastLettersAdvanceNotItsInk`: Recognition ends a line where its last letter's ink ends; the caret is
that letter's side bearing further on. Taking the ink's end put the
ghost 0.6–0.8 pt over the last letter (measured 2026-10-09).

#### Viber caret read as bar is the caret; do not add the space again
`testTheAppsCaretReadAsABarIsTheCaret`: Viber's caret is a bar that recognition reads as "|" (2026-10-09). The
caret is where that bar is drawn, already past the space typed before
it; adding the space again put the ghost a space too far right.

#### A word really ending in l is text, not a caret bar
`testTheAppsCaretReadAsABarIsTheCaret`: A word that really ends in "l" is text, not a caret.

#### Line break, far jump or other text means look for the caret again
`testTypingMovesTheCaretAlongItsLineUntilTheLineEnds`: A line break, a long way from where the caret was found, or other
text: look again.

#### Capture may lag typing or miss a full stop; caret must follow typed text
`testACaptureThatLacksTheLastLettersStillPutsTheCaretAfterThem`: A capture can be a frame behind the typing, and recognition can miss
a final full stop. Taking the end of what was recognized for the
caret put the ghost over the last letters typed.

#### Viber report: line missing short last word put ghost over it
`testALineWithoutItsLastWordPutsTheCaretAfterThatWord`: The 2026-10-09 report from Viber: after "Ima i dalje preklapanja te"
the ghost "lefonskih brojeva, ali" began a letter or two early, over
"te". Recognition had returned the line without its short last word,
which still matched well enough, and the caret was put at the end of
what was recognized.

#### When recognition splits a row, the longer piece sizes the font
`testALineWithoutItsLastWordPutsTheCaretAfterThatWord`: Recognition split the row in two: the longer piece sizes the font.

#### Unseen words that would pass the line end belong to the next line
`testALineWithoutItsLastWordPutsTheCaretAfterThatWord`: Unseen words that would pass the end of the line went to the next one.

#### Size font from typed text; misread text gave 12.8 pt instead of 13.5 pt
`testTheFontIsSizedFromTheTypedTextNotTheMisreadOne`: Measured in Viber on 2026-10-09: at LokalBot's 2× capture, recognition
read "bolje ali i dalje nije" as "bolJe all I dalJe nlJe". Sizing the
font from that text made it 12.8 pt instead of 13.5 pt, so every
letter typed afterwards put the ghost a little further behind the
caret; after "uvS" it began over the "S".

#### Fast recognition often drops accents, as on Serbian text
`testAccentsDoNotStopAMatch`: Fast recognition often drops accents, as on Serbian text.

#### Right text edge is estimated; word near it may already be wrapped; spaces never wrap
`testLettersTypedNearTheLineEndAreFoundAgain`: The field's right text edge is only estimated, so a word typed close
to it may already be on the next line. Following the caret along the
line put the ghost on the line above, and its wrapped words on the
word just typed. Spaces never wrap.

#### Deleting into a wrapped line's first word can let it fit above again
`testDeletingIntoTheFirstWordOfAWrappedLineIsFoundAgain`: Deleting back into the first word of a wrapped line can let that
word fit on the line above again.

#### Fields with an on-screen caret wait for it unless finds keep failing
`testAFieldWhoseCaretIsFoundOnScreenIsKnown`: A field whose caret is found on screen waits for it instead of a
popup outside the field, unless finds there keep failing.

#### Overlay rect puts ghost baseline on the found line however overlay reads it
`testTheGhostIsDrawnOnTheBaselineFound`: The rect handed to the overlay puts the ghost's baseline on the line
found, whichever way the overlay reads it.

#### With a site excluded, a page must be known to be another site
`testCaptureFollowsTheScreenCaptureExclusions`: With a site excluded, a page must be known to be another site.

#### Chrome returns a new element per read; reuse the found caret
`testTheCaretFoundIsReusedWhenChromeHandsOutANewElement`: Chrome hands out a new element for the same field on every read; the
caret found for it still applies, so it is not looked for again.

#### Fast recognition at 1x cannot read c-caron, z-caron, dj; capitals misread (2026-11-02)
`testLettersRecognitionCannotReadDoNotStopAMatch`: Measured at 1x on 2026-11-02: fast recognition cannot read "č", "ž" or
"đ". Capitals with them came back as other characters, so a short
Serbian message never matched and the suggestion went to a popup.

#### Run-together words must not count lost spaces; gave 21 pt for 13.5 pt text
`testWordsRunTogetherStillMatchAndMeasureTheWholeLine`: Recognition ran these words together. Counting the spaces it lost took
the line for the end of a longer paragraph, and sized the font from
part of the text: 21 pt for 13.5 pt text.

#### Line missing its first letters must not fit all typed text to it
`testALineMissingItsFirstLettersStillMeasuresTheFont`: "Šta ćeš da radiš večeras" came back as "a ces da radis veceras". All
of the typed text was then fitted to a line without its first letters.

#### Too-short lines are not measured past start; would give implausibly small font
`testALineMissingItsFirstLettersStillMeasuresTheFont`: Too short to measure past its start: fitting all of the typed text
to it would be far smaller than text in a field.

#### Measure short lines whole; partial alignment gave 18 pt
`testAShortLineThatReadsTwoLettersAsOneIsMeasuredWhole`: Fitting all of "Čekam" to what is read as "&kam" is right: "&" stands
for two letters. Measuring only the letters that line up gave 18 pt.

#### Other scripts are not excused; matching on length alone would pass any line
`testOtherScriptsAreNotMatchedOnLengthAlone`: Other scripts are not excused: any line of the right length would pass.

#### One font size per field; it varied find to find and caret moves by it
`testAFontMeasuredFromAWholeLineOutlastsFindsThatCouldNot`: One size for one field. It changed from find to find with how much of
the line recognition could read, and the caret moves by it.

#### After a sent message, use the field's known first-line start
`testANewMessageStartsWhereTheFieldsFirstLineStarts`: The next message after one was sent: no text to follow on from, and
too few letters to find, yet the field's first line is known.

#### Fields of another size may hold another font; do not reuse first-line start
`testANewMessageStartsWhereTheFieldsFirstLineStarts`: Nor in a field of another size, which may hold another font.

#### Non-Retina capture scaled to 3x; 2x made Viber 'je' read as 'Je'
`testTheCaptureIsScaledUpOnANonRetinaDisplay`: On a non-Retina display the capture is scaled up to three times its
point size, not left at its own pixels in a corner of a larger image;
at two times recognition misread Viber's "je" as "Je" throughout.
A field too big for that is captured at two times.

#### Recognition mixes Latin letters into Cyrillic words since it lacks Serbian's
`testACyrillicLineMatchesHoweverItsLettersWereRead`: Recognition mixes Latin letters into a word, as it does not know Serbian's.

#### Never take any Cyrillic line for the typed text; caret was 24 pt off
`testACyrillicLineWithOtherTextDoesNotMatch`: Other text of about the same length is not the typed text. Taking any
Cyrillic line for it put the caret up to 24 pt off.

#### A lost letter made an earlier word end match better; caret 13 pt off
`testALetterLostFromAMeasuredLineDoesNotMoveTheCaretOn`: With one letter lost, the typed text looked a closer match ending a word
earlier, so that word was added after the line's real end: 13 pt off.

#### Last word lost in reading but present in ink is not added again
`testAWordLostInReadingIsNotAddedAfterTheInk`: Recognition lost the last word, and the ink past what it read holds it:
that word is on screen, so the caret does not move by it again.

#### Capture may predate the last key; stale caret lagged a letter for four keys
`testAMeasuredCaretInAFrameFromBeforeTheLastKeyMovesOn`: The capture can be from before the last key, with the caret drawn where
it was. Stale by a letter the caret was a letter behind, for four keys.

#### Latin keeps its matching: a line a letter short is a missed last word
`testAFastRecognitionLineKeepsItsOwnMatching`: Latin keeps the matching it had: a line read a letter short still counts
as a line whose last word was missed.

#### Render Cyrillic at display pixels then scale; drawing at 3x hid the Serbian bug
`testRecognitionFindsTheCaretInRenderedCyrillic`: Runs the real recognizer on Cyrillic drawn at a display's own pixels and
scaled up as the capture does: drawing directly at 3x hid the Serbian bug.
With fast recognition, none of these has a line to match.

#### Suggestion waits at most its budget for the caret; slow find keeps running
`testTheWaitForASlowFindEndsAtItsDeadline`: A finished suggestion waits at most its budget for the caret, then is
shown beside the field. The slow find is left running for next time.

### `LokalBotTests/Cotyping/CotypingWindowTextTests.swift`

#### Stacked windows of one app can only be told apart by title
`testCaptureReadsOnlyTheFocusedWindow`: Two windows of the same app over each other: only the title can tell.

#### Reread reuses lines if window unchanged outside the field; caret blink ignored
`testFingerprintIgnoresTheFieldButNotTheRestOfTheWindow`: A reread reuses the last lines when the window image is unchanged
outside the field: the caret blinking in the field does not count, a
changed word elsewhere or a moved window or field does.

#### Test images are 2 pixels per point, rects from top left
`testFingerprintIgnoresTheFieldButNotTheRestOfTheWindow`: 2 pixels per point; rectangles in pixels from the image's top left.

#### A recognition started before text was forgotten cannot store its result
`testReusedLinesAreForgottenWithTheTextInUse`: A recognition that started before the text was forgotten cannot store.

#### A timestamp or typing indicator is too little to reread everything
`testRereadingKeepsThePromptUnlessNewTextAppears`: A timestamp or typing indicator is too little to read everything again.

#### Chat text stayed in memory after clicking another app without typing
`testFocusInAnotherAppOrFieldForgetsTheTextWithoutARead`: Reading a chat window and then clicking into another app without
typing never asked for a new read, so the chat's text stayed in memory.

#### A reply box that grows and moves down while typing is the same field
`testFocusInAnotherAppOrFieldForgetsTheTextWithoutARead`: The reply box grows and moves down as you type: still the same field.

#### New window text waits for a typing pause; rereads cost 268 ms vs 41 ms
`testNewTextWaitsForAPauseInTyping`: 2026-10-16: rereads added new text every few seconds while typing, and
each one made the next keystroke read the whole prompt again (268 ms
instead of 41). New text now waits for a pause in typing.

#### Test sleep never ends on its own; the test steps the clock
`testNewTextWaitsForAPauseInTyping`: The wait never ends on its own here; the test steps the clock.

#### Window text is on for everyone, including settings saved before the switch
`testWindowTextIsOnForEveryoneUnlessTurnedOff`: On for everyone, including settings saved before the switch existed.

#### Words from screen may be suggested; only the label is leak scaffolding
`testPromptStartsWithTheWholeWindowAndKeepsEveryOtherLine`: Words from the screen are fair to suggest; the label is scaffolding.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
