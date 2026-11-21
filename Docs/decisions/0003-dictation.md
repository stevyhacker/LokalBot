# 0003. Dictation

- Status: Accepted
- Date: 2026-11-20

## Context

Dictation records speech while a shortcut is held or toggled, transcribes it, optionally cleans it up or composes text with Think, and inserts the result at the cursor. The Mac app implements it in `LokalBot/Dictation/`, with pasting in `LokalBot/Cotyping/CotypingInserter.swift`; the Windows and Linux app spreads it across the `lokalbot-engine`, `lokalbot-ai`, `lokalbot-platform`, `lokalbot-audio`, `lokalbot-speech` and `lokalbot-app` crates. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Cleanup and Compose

### Speech that is not a writing request goes to a cleanup-only prompt as data

Transcribe inserts the recognized speech as it is, with no model call and no context read. Compose routes the speech: a writing request ("reply to…", "draft…", "tell him … from the message above") gets the Compose prompt with the context the caller supplies; anything else is sent as JSON data under a cleanup-only system prompt that forbids answering it or carrying it out, as FluidVoice and Handy do. That kept direct sentences 16/16 against 13/16 on a set frozen before it ran, and "What is the status of the Birch invoice?" is inserted instead of answered (`Benchmarks/transcribe/Dictation/results/2026-10-08-cleanup`). Letting the Compose prompt itself decide whether speech is an instruction (`composeDecides`) answered "Can you tell me when the 9 boxes arrive?" with "I don't know…" (`Benchmarks/transcribe/Dictation/results/2026-10-08-routing-window`).

Where: `LinuxWindows/crates/lokalbot-ai/src/dictation.rs`, `LokalBot/Dictation/DictationComposition.swift` (`DictationCleanupPrompt.transcriptAsData`, `DictationCleanupPrompt.composeDecides`), `LokalBotTests/Dictation/DictationGroundingTests.swift` (`testDirectSpeechIsCleanedAsDataNotAsAnInstruction`).

### Cleaned direct speech keeps its digits, names and negation, or the transcript is inserted

The cleanup-only prompt asks the model to keep numbers, names and negation, but a 4B model doesn't always: v2's "na 3 sastanka" came back as "na tri sastanka". The cleaned text is checked against the transcript: it may not contain a digit run that wasn't spoken or lose one that was, every spoken English negation word must remain, and a capitalized word that isn't a sentence's first word must remain or be respelled to a glossary term. Negation is compared by meaning ("n't" and "cannot" count as "not"), and a sentence's opening "no" after fillers is an answer, not a negation. A self-correction ("3, no, 4", "I mean", "actually") exempts what it corrects, because cleanup is meant to drop false starts, and repeating a phrase is not a loss; an invented digit is never exempt. When a check fails, the transcript is inserted instead, as Transcribe would insert it, and the log names only the check. Writing requests are not checked, since their answer is meant to differ from the speech. On the replay sets it took cleaned direct speech from 425/435 to 430/435, every fix being v2's Serbian digit case, and changed no correct output (`Benchmarks/transcribe/Dictation/results/2026-11-21-word-lock`).

Where: `LokalBot/Dictation/DictationWordLock.swift` (`DictationWordLock`), `LokalBot/Dictation/DictationTextPreparation.swift` (`DictationTextPreparation.prepare`), `LokalBot/Dictation/DictationContextReplay.swift` (`wordLock`), `Benchmarks/transcribe/Dictation/context_replay.py` (`--word-lock`), `Benchmarks/transcribe/Dictation/results/2026-11-21-word-lock/REPORT.md`, `LokalBotTests/Dictation/DictationWordLockTests.swift`.

### A relay counts as a writing request only when it points at context

`DictationRequestRouting` decides which spoken openings count as a writing request that may use context; production uses `.production`, and the replay benchmark compares the others (`Benchmarks/transcribe/Dictation/results/2026-10-08-routing-window`). `relays` answered more requests but routed "Tell him I am running 10 minutes late" as one and copied a screen fact into it. `referencedRelays`, which needs a pointer to context, still answered new requests and never routed a self-contained relay.

Where: `LokalBot/Dictation/DictationGrounding.swift` (`DictationRequestRouting`), `LokalBotTests/Dictation/DictationGroundingTests.swift` (`testProductionRoutingRequiresAPointerForRelays`).

### Compose keeps the last 2,000 characters of the focused window's text

`DictationWindowTextPolicy` sets how much of the focused window's OCR text a Compose prompt keeps and from which end; production uses `.production`, and the replay benchmark varies it. Keeping the first 12,000 characters dropped the newest message of a long window, which sits at the bottom next to the input field, and Compose answered from a stale one; the last 2,000 answered every window case.

Where: `LokalBot/Dictation/DictationComposition.swift` (`DictationWindowTextPolicy`).

### Compose passes options that rule out a long thinking turn

Someone is waiting to insert the text, and without options the built-in server would allow an 8K-token thinking turn before any visible text.

Where: `LokalBot/Dictation/DictationTextPreparation.swift` (`DictationTextPreparation.prepare`).

### Context is read only for writing requests

Context is read only for writing requests. A direct sentence must not acquire claims from nearby messages, so `process` stops the context capture that began during recording.

Where: `LinuxWindows/crates/lokalbot-ai/src/dictation.rs` (`prepare_checked`), `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`process`).

### A composition is re-checked around the model call, and the transcript always survives

A composition frozen at the shortcut is re-validated around the model call: a revoked grant, changed exclusions, changed destinations or a changed source reject it (`DictationGrounding.permissionsMatch`). A rejected or failed Compose must not lose minutes of transcribed speech; the transcript is kept.

Where: `LinuxWindows/crates/lokalbot-ai/src/dictation.rs` (`permissions_match`, `prepare_checked`), `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`process`).

## Transcription

### An empty result is retried once without the vocabulary prompt

Dictation transcribes with the vocabulary prompt. The engines drop rows made only of vocabulary-hint terms, because a near-silent span decodes to the hint itself, so a dictation that genuinely was only those words ("Mila Novak, Orion Launch") ended as "No speech detected". An empty result with at least 1 s of clear speech is decoded once more without the hint, which cannot echo anything.

Where: `LokalBot/Dictation/DictationCoordinator.swift` (`DictationCoordinator.shouldRetryWithoutVocabulary`), `LinuxWindows/crates/lokalbot-speech/src/transcriber.rs` (`Transcriber.transcribe_dictation_with_prompt`).

### A local multilingual model stands in when the transcription server fails

When the transcription server cannot transcribe, a speech model already on the Mac transcribes the same audio and the HUD says why (`DictationProblemNotice`). On 2026-11-10 OpenRouter stopped accepting a saved key: every dictation recorded, got HTTP 401 and ended with a message only LokalBot's own window shows, so in any other app the shortcut seemed to do nothing. Only multilingual models, best first, may stand in; the narrow ones (SenseVoice, GigaAM, Fun-ASR-Nano, Cohere) are left out so speech in another language never becomes wrong text in someone's document.

Where: `LokalBot/Dictation/DictationTranscriptionFallback.swift` (`DictationTranscriptionFallback`, `DictationTranscriptionFallback.multilingual`).

## Context for writing requests

### Each context source has its own grant, and nothing read is saved

A Compose writing request can get the focused window, the text above the field and saved facts. Each has its own grant, and nothing read for it is saved. Saved facts need dictation's own grants; autocomplete's grants do not enable them (`DictationGrounding.memorySettings`).

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation_context.rs`, `LinuxWindows/crates/lokalbot-ai/src/dictation.rs` (`memory_policy`).

### A shortcut never triggers a permission prompt

Context capture never prompts from a global shortcut. On the Mac, the Dictation permissions UI is the explicit place to grant Screen Recording. On Windows and Linux, `capture_screen` reads the focused window's title and address always, its accessible text when it shares enough, and otherwise on-device OCR when installed; the portal can prompt, so a desktop that needs it gets metadata only.

Where: `LokalBot/Dictation/DictationComposition.swift` (`DictationScreenContextCapture.capture`), `LinuxWindows/crates/lokalbot-engine/src/dictation_context.rs` (`capture_screen`).

### Captured context is bound to the exact window

Context belongs to the exact window, not the process: switching documents in one app must invalidate the captured title and address. Capture returns nothing rather than any other window, and writes nothing to disk.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation_context.rs` (`ScreenIdentity`, `capture_screen`).

### No context is read from a secure field or a selection

Screen and nearby-text context are never read from a secure field or while text is selected.

Where: `LokalBot/Dictation/DictationModels.swift` (`DictationFocusSnapshot.blocksContextCapture`).

## Where the text goes

### The destination is the app and field focused at the shortcut press

The focus read starts at the shortcut, alongside the microphone; a read during recording would bind whichever app had focus by then. A retry once took a fresh focus read during recording, so switching apps right after the shortcut made the second app the paste destination; a late answer must come from the shortcut's own read. The microphone does not wait for that read: waiting delayed every start by up to its deadline, and words spoken meanwhile were lost.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`Dictation.start`), `LokalBot/Dictation/DictationCoordinator.swift` (`DictationCoordinator.start`), `LokalBotTests/Dictation/DictationReliabilityTests.swift` (`testSlowFocusReadStillBindsTheFieldFocusedAtTheShortcut`).

### Insert only while that app and field still have focus; otherwise copy

Insertion is allowed only while the app and field that had focus at the press still do; otherwise the text is copied. On a desktop that reports nothing about focus (`Binding::Unknown`), dictation pastes as asked, since refusing would make it copy-only on that whole desktop.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`Binding::Unknown`).

### A password field is never a destination, and its text is never kept

A captured target is `None` for a secure field, and a blocked focus snapshot always wins over the app-only paste fallback, so a target captured before AX exposed a field never becomes permission to paste into a same-app password field later. Reading back what was inserted requires the bound field and never inspects a secure one: an app-only target (no field identity) once let the read-back inspect whatever field had focus, including a secure one (review finding on 719b3dc). Text meant for a password field is never kept.

Where: `LinuxWindows/crates/lokalbot-platform/src/focus.rs` (`DeliveryTarget::captured`), `LokalBot/Dictation/DictationModels.swift` (`DictationDeliveryTarget.check`), `LokalBotTests/Dictation/DictationFeedbackTests.swift` (`testReadBackRequiresTheBoundFieldAndNeverASecureOne`), `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`process`).

## Pasting

### Paste through the clipboard and restore it once the app has read the text

On the Mac, text is inserted by putting it on the pasteboard and sending Paste, then restoring the user's clipboard once the focused app has read it. The text is provided lazily so LokalBot learns when the read happens; a fixed delay used to restore the old clipboard before a busy app read it, and that app pasted the previous clipboard instead. It is a trimmed port of Cotabby's `insertViaPaste`, used by dictation commits.

Where: `LokalBot/Cotyping/CotypingInserter.swift` (`CotypingInserter.insertViaPaste`).

### Pastes run one at a time, and a waiting paste re-checks its destination

A second paste waits for the first; otherwise it would snapshot the first one's dictated text as the user's clipboard. A paste that had to wait runs `revalidateAfterWaiting`, since focus may have moved, and cancelling the caller cancels a paste that has not started: a queued paste once ran after its dictation was cancelled, into whatever app had focus by then (review finding on b323141).

Where: `LokalBot/Cotyping/CotypingInserter.swift` (`CotypingInserter.pasteQueue`, `CotypingInserter.insertViaPaste`), `LokalBotTests/Dictation/DictationReliabilityTests.swift` (`testQueuedPasteIsDroppedWhenItsCallerIsCancelled`).

### Clipboard contents are marked as generated, and concealed items are not restored

The dictated text only passes through the clipboard, so both apps mark it as generated and clipboard history and cloud sync skip it. The restored clipboard is marked the same way so clipboard managers do not record a second copy. A concealed item (a password manager's copy) is not put back: its owner clears it on a timer only while the pasteboard is unchanged, so a restored copy would linger.

Where: `LinuxWindows/crates/lokalbot-platform/src/insert.rs` (`paste`), `LokalBot/Cotyping/CotypingInserter.swift` (`CotypingInserter.restorePasteboard`).

### The Paste menu item is pressed off the main thread

The menu item is found on the main actor but pressed on a background queue: the app answers the press by reading the pasteboard, and that read is served from LokalBot's main thread.

Where: `LokalBot/Cotyping/CotypingInserter.swift` (`CotypingInserter.pressPasteMenuItem`).

### Typing falls back to short chunks

When paste cannot be set up, dictation types the text in short Unicode keystrokes. Many apps take only the first 20 UTF-16 units of a single synthetic key event, so the whole string in one event could silently lose the rest.

Where: `LokalBot/Cotyping/CotypingInserter.swift` (`CotypingInserter.typeInChunks`).

### A paste fits its spacing and first capital to the text before the caret

Back-to-back dictations ran together ("right now.Next") and a dictation that finished a typed sentence kept the transcriber's capital ("we should Probably wait"). A space goes in front after a word, but not after whitespace, a new line or an opening character, before punctuation the dictation starts with, or next to a script written without spaces (Chinese, Japanese, Thai, Lao, Khmer, Myanmar, full-width forms; Korean keeps its spaces). In the middle of a sentence a capitalized everyday first word is lowered; a sentence end (`.!?…:`, `。！？`, also behind a closing quote or bracket), a new line or a list marker (`-`, `*`, `1.`, `a)`) keeps the capital, and "I", acronyms and mixed-case words are never lowered.

Where: `LokalBot/Dictation/DictationPasteSeam.swift` (`DictationPasteSeam.fit`, `DictationPasteSeam.needsSpace`, `DictationPasteSeam.continuesSentence`, `DictationPasteSeam.loweringFirstWord`), `LokalBotTests/Dictation/DictationPasteSeamTests.swift`.

### The capital rule is English only and keeps words the dictionary capitalizes

Other languages capitalize differently (German nouns), so only English dictations are lowered: the transcription language is English, or Automatic and `NLLanguageRecognizer` reads the field's last 200 characters plus the dictation as English at 0.8 or more. A word counts as everyday when macOS's English dictionary knows it in lower case and does not offer it capitalized as its top guess, which keeps Monday, English and Google. A name that is also an everyday word ("Mark", "Will") cannot be told apart and is lowered.

Where: `LokalBot/Dictation/DictationPasteSeam.swift` (`DictationPasteSeam.lowersSentenceCapital`, `DictationPasteSeam.isEverydayEnglishWord`), `LokalBot/Dictation/DictationCoordinator.swift` (`DictationCoordinator.fittedToField`).

### The fit reads the field when the paste's turn comes, under the read-back's rules, and changes only what is pasted

`fitToField` runs inside the paste queue, just before the text goes on the pasteboard, so the second of two quick dictations sees the first in the field. It reads the bounded text before the caret under the read-back's rules: only the field bound at the shortcut, never a secure field or an app on the exclusion list, nothing kept; an unreadable field, a selection or a timeout pastes the text unchanged. Only the paste and the typed fallback get the fitted text; history, clipboard copies (including a paste no app reads) and the delivery notice keep the dictation as transcribed.

Where: `LokalBot/Cotyping/CotypingInserter.swift` (`CotypingInserter.insertViaPaste`, `CotypingInserter.pasteAndConfirm`), `LokalBot/Dictation/DictationCoordinator.swift` (`DictationCoordinator.deliver`, `DictationCoordinator.fittedToField`), `LokalBotTests/Dictation/DictationPasteSeamTests.swift`.

## Shortcut and keys

### The shortcut never cancels finished speech

In Toggle mode a second press while the text was being prepared (to start the next dictation, or because the HUD looked slow) used to delete the recording and the transcript; push-to-talk already ignored it. The shortcut now never cancels finished speech, and while the speech model needs attention it retries instead. The menu and other on-screen controls keep their explicit Cancel.

Where: `LokalBot/Dictation/DictationCoordinator.swift` (`DictationCoordinator.toggleAction`), `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`toggle_action`).

### A disabled event tap counts as a key release

A disabled event tap can swallow the physical key-up, so the disable notification is treated as a fail-safe release before the tap is re-enabled; otherwise push-to-talk may record indefinitely.

Where: `LokalBot/Dictation/DictationInputMonitor.swift` (`DictationInputMonitor.handle`).

### Modifier-only chords are watched by reading key state, never taken

Shortcuts made only of modifier keys, like Ctrl+Alt, are watched by reading the keyboard's state, which consumes nothing, so other shortcuts that start with the same modifiers keep working. X11 and Windows can report that state; a Wayland desktop tells an app about keys only through a shortcut with a real key, so chords aren't offered there. AltGr reports as Left Ctrl + Right Alt on many layouts, and pressing it alone must not read as Ctrl+Alt.

Where: `LinuxWindows/crates/lokalbot-platform/src/chord.rs` (`WinKeys::read`).

### Esc is taken only while dictating

Esc is taken only while dictation is starting or recording, and given back at once. Wayland lets no app take a key, so there the overlay's X cancels.

Where: `LinuxWindows/crates/lokalbot-app/src/desktop.rs` (`sync_dictation_cancel_keys`).

### The Wayland pill is a layer surface

On Wayland the dictation pill is a layer surface on the bottom edge: a tiling compositor would otherwise tile it and give it the keyboard, and the dictated text would land in the pill.

Where: `LinuxWindows/crates/lokalbot-app/src/hud.rs` (`hud::open`).

## Microphone and media

### The Mac microphone is an AVCaptureSession, not AVAudioEngine

Dictation's microphone is an `AVCaptureSession` on the default input device. `AVAudioEngine` stops itself whenever the I/O hardware format changes, and a Bluetooth headset changes format as soon as its microphone opens (AirPods switch from music to headset mode); rebuilding the engine a second later had already released the microphone, so the headset fell back to music mode, the cycle repeated, dictation recorded fragments and the microphone indicator flickered. A capture session keeps the device open across those changes and converts every buffer to one fixed client format. Starting and stopping run on a private serial queue, because opening a Bluetooth microphone can take a second and the main thread also services the shortcut's keyboard event tap.

Where: `LokalBot/Services/Audio/CaptureSessionMicrophoneInput.swift` (`CaptureSessionMicrophoneInput`).

### A successful recorder rebuild does not reset the flap budget

In the AirPods loop every rebuild succeeded, reset the retry budget, and the device dropped again, so dictation recorded fragments forever and never told anyone. The recorder degrades when the input keeps dropping, even after successful recoveries.

Where: `LokalBotTests/Dictation/DictationReliabilityTests.swift` (`testRecorderDegradesWhenTheInputKeepsDroppingAfterSuccessfulRecoveries`).

### A mic thread stuck in the audio system is never joined

When starting times out, the thread is still inside the audio system; joining it would wait for the call the timeout gave up on, so it is left to end by itself once it sees the stop.

Where: `LinuxWindows/crates/lokalbot-audio/src/mic_capture.rs` (`MicCapture::start`).

### Dictation does not start during a meeting recording

The two share a microphone, and the meeting recording wins.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`dictation_does_not_start_during_a_meeting_recording`).

### Media pausing skips calls, conference pages and live streams

Calls and conference pages are never paused, whatever the desktop reports about them (`pauseHTMLMediaJavaScript` on the Mac). Browsers publish one player per page, and a page with no known length is a live stream or a call, which pausing would lose. Windows media sessions don't say which page a browser's session is for or whether it has an end.

Where: `LinuxWindows/crates/lokalbot-platform/src/media.rs` (`CONFERENCE_HOSTS`, `BROWSER_PLAYERS`, the SMTC read).

### Resume only what dictation paused, tracked even when the pause script times out

Dictation resumes what it paused, unless the person changed it since. A browser script that runs out of time may already have paused some tabs: with sixty tabs open it paused the video in tab 3 and was stopped at its time limit before it could report, nothing was recorded, and the video stayed paused after the dictation. What to resume is therefore kept by the pause token even when the script did not report; resuming by the token is safe when nothing carries it.

Where: `LinuxWindows/crates/lokalbot-platform/src/media.rs` (`resume`), `LokalBot/Services/Audio/MediaPlaybackController.swift` (`MediaPlaybackController.pausedTarget`), `LokalBotTests/Services/Audio/MediaPlaybackPauseTests.swift` (`MediaPlaybackController.pausedTarget`).

### A new dictation waits for an earlier cancel's resume

An earlier cancel may still be restoring the players it paused; dictation waits for it, or its late resume could interrupt this capture. Then it pauses what is playing now and gives the sound a moment to stop.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`Dictation.start`).

## History, learning and background work

### Every exit path clears the flag that holds digests and reviews

Day digests and overnight reviews wait while dictation's flag is set, so every way out clears it, including a cancel or a failed load before the text.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`Runner.run`).

### Recent dictations are sealed on disk only when the credential store can keep their key

The latest results are kept so one left on the clipboard can be copied again (`DictationHistory`). They live in memory and are sealed in the library whenever the credential store can keep their key; without one they last until quit.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`Recent`).

### Learning keeps dictated words only if they pass the nearby-text exclusions

Learn from my dictation (`keepForLearning`) reads the pasted-into window's title and page address once and keeps the spoken words only if they pass the same exclusions as nearby text. Anything unreadable keeps nothing.

Where: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs` (`keep_for_learning`).

## Consequences

- Speech that is not a writing request stays data for a cleanup-only prompt; a change to routing, the cleanup prompt or the window-text policy needs a rerun of the replay benchmarks in `Benchmarks/transcribe/Dictation/results/`, and every path that rejects or fails a composition must still keep the transcript.
- The destination is bound at the shortcut press and checked again before each paste; a secure field blocks paste, read-back, context and keeping the text, and no fallback may weaken that.
- Dictation borrows the person's microphone, clipboard, keys and media players: a global shortcut never prompts or takes keys it does not need, and dictation puts back only what it changed.
