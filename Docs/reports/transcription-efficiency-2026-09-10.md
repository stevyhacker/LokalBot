# Transcription runtime and cloud notes fixes — 10 September 2026

The production audit found repeated Granite process starts, cloud notes that exhausted their allowance before covering the transcript, and long ASR filler loops that survived cleanup. The changes address those causes without changing the selected speech or notes model.

## Changes

- **Reuse the loaded speech model.** The bundled llama.cpp build returns a full model path in `/v1/models`; the old check compared it only with a filename. Health checks now accept the exact path or a reported filename. A different absolute path with the same basename fails. PID ownership, executable path, model path, context size and runtime arguments still have to match.
- **Keep confirmed silence out of ASR.** A successful empty VAD result remains empty. Unavailable VAD still permits whole-track transcription. The common span loop avoids audio decoding and inference for an empty span list, including the Cohere path.
- **Remove the observed filler loops.** Cleanup now catches fast, overwhelmingly repetitive bursts below the old 80-word/12-words-per-second gate. It retains meaningful edges, two repetitions, timestamps and speaker attribution. Short acceptances, ordinary emphasis, slower repetitions and non-repeating counting remain intact.
- **Send supported GLM reasoning settings immediately.** GLM-5.3 requests use effort-based reasoning from the first call; bounded notes use `low`. Higher explicit budgets retain `high`. Strict JSON schema and the configured data policy survive compatibility handling. A schema-only routing failure is surfaced instead of silently dropping the schema. Known pre-generation parameter rejections refund their output reservation while still counting as physical requests; unknown usage remains reserved.
- **Separate chunk planning from the safety allowance.** Native tokenization remains authoritative. For providers without a tokenizer, an approximate token count chooses useful part sizes while UTF-8 bytes still bound prompt input with the existing output/envelope headroom. Verified OpenRouter GLM endpoints get a modest 32K allowance; unknown external servers retain 16K. Output allocation considers how many parts can fit within the remaining request budget, including possible repairs. Long meetings retain resumable progress rather than dividing output across unreachable work.
- **Improve overview selection and diagnostics.** The deterministic overview prioritizes validated user-action evidence and decisions across the meeting, then samples the remaining facts across the full transcript. Every notes attempt gets its own metrics file with an attempt ID, start time, model, transcript revision and planned part count. `notes-generation-metrics.json` remains the latest snapshot; `notes-generation-runs/` preserves earlier attempts.

GLM-5.3-Flash documents explicit `low`, `high` and `max` reasoning levels, with unsupported values falling back to `max`. [Z.ai model card](https://huggingface.co/zai-org/GLM-5.3-Flash). The inspected OpenRouter model endpoint metadata reports a minimum context of 262,144 tokens for both configured GLM variants; 19 of the 26 Flash endpoints advertise structured-output support. Runtime compatibility still depends on the routed provider and account policy. [Flash provider metadata](https://openrouter.ai/api/v1/models/z-ai/glm-5.3-flash/endpoints), [GLM-5.3 provider metadata](https://openrouter.ai/api/v1/models/z-ai/glm-5.3/endpoints), [structured-output requirements](https://openrouter.ai/docs/guides/features/structured-outputs).

## Local validation

An opt-in native XCTest replay used the installed Granite Speech 4.1 2B Q8 model on a separate loopback port. It decoded 12 copied audio windows totaling 67.83 seconds from the recent 26-minute meeting. The source meeting was not edited.

| Measurement | Result |
| --- | ---: |
| Initial runtime/model startup | 4.172 s |
| Model processes across 12 repeated preparation calls | 1 |
| Combined reuse checks | 13.80 ms |
| Median reuse check | 1.19 ms |
| ASR span decoding, excluding VAD and startup | 2.001 s |
| Empty VAD windows that skipped inference | 2 |
| Changed context size replaced the process | Passed |

Both replay tests passed. This verifies process reuse and configuration invalidation on real audio; it is not a full-meeting elapsed-time measurement. The audited production run had spent approximately 11m10s outside ASR profiling across 562 region calls, largely in repeated startup. A precise full-job speedup has not been measured.

Planning and cleanup were also replayed locally against private copies of the two latest transcripts, without calling a cloud service:

| Transcript | Original words | Repetitive words removed | Changed segments | Planned GLM parts after cleanup |
| --- | ---: | ---: | ---: | ---: |
| Recent 26-minute meeting | 4,254 | 0 | 0 | 3 |
| Recent 38-minute meeting | 10,710 | 4,655 | 35 | 3 |

The 38-minute meeting previously planned 38 parts and verified none in its latest cloud attempt. With the new planner it needs five parts before cleanup and three after cleanup. Every retained evidence source, including the transcript tail, remains in the plan. This is a planning result, not a completed GLM summary or a measured cloud latency improvement.

All focused regressions passed. The full native suite recorded **2,003 passed, 19 failed and seven skipped**. The 19 failures are the existing speaker evidence storage/identity/lifecycle tests: protected `.sealed` fixtures could not be reopened while the Mac was locked. The locked state was verified during this run. The skipped tests include opt-in inference replays; the two replays above subsequently ran and passed separately. Strict SwiftLint and `git diff --check` pass. No UI tests ran locally.

A small synthetic GLM request was prepared, but reading the configured Keychain credential timed out; no request was sent. The provider request shape is covered by unit tests and current primary documentation. Authenticated end-to-end GLM generation remains unverified.

## Reproduction and limits

`LlamaServerTests/testLocalGraniteRegionReplayKeepsOneProcess` accepts `LOKALBOT_GRANITE_REPLAY_MANIFEST`, with local model/projector/audio paths, an unused ephemeral port, an output folder, and start/end windows. It exercises production request construction and VAD/span decoding, checks one PID across calls, then verifies restart on a context change.

`MeetingNotesReplayTests/testLocalCloudPlanningAndTranscriptCleanup` accepts `LOKALBOT_NOTES_PLAN_MANIFEST`, containing transcript paths and a private output folder. It checks complete source coverage and context bounds, and writes cleanup/part counts plus sanitized copies. Both tests skip during ordinary CI. Set the variables in the native test target's `EnvironmentVariables` in an `.xctestrun` file and run `xcodebuild test-without-building`; exclude `LokalBotUITests`.

All audio, source transcripts, model responses, authenticated request material and generated meeting documents remain outside the repository. The source meetings, model selections and running installed application were not changed by validation. Short fragments can still produce incorrect text; the sample still returned several short filler phrases. Recognition recall, word error rate, language accuracy and live cloud completion need separate measurements. These changes preserve speaker boundaries; they do not add neighboring speakers' audio as context to short turns.
