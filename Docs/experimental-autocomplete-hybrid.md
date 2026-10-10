# Experimental hybrid autocomplete trial

This is an opt-in experiment, not a recommendation to change the default decoder.

In **Settings → Writing → Autocomplete**, turn on **Experimental hybrid suggestions**. Turn it off to restore the current decoder immediately; no restart or model download is needed. The setting is saved across launches and defaults to off, including upgrades. Autocomplete itself must be enabled and the fast in-process runtime must be on. Model-server fallback continues using its existing decoder.

The hybrid preserves passing current suggestions. When the current confidence gate would stay silent, a second gate can offer a single word. It uses the same model, prompt, sampler and decode budget. It normalizes the complete generation before applying the one-word cap; stopping the decode early can miss a later reason to suppress the suggestion. Hybrid mode publishes the final normalized result instead of intermediate text.

Switching modes cancels pending autocomplete work, hides the current suggestion, clears suggestion remainders, and rebuilds the local engine for the selected mode. Cache and model-check identities include the experiment flag. Capture, memory, and network permissions are unchanged.

## Evidence and limitations

The [frozen prototype report](../Benchmarks/Cotyping/results/2026-10-10-native-hybrid/REPORT.md) contains the raw observations, source snapshot, hashes, blinded Claude ratings and protocol. Its validation counts and binary hashes describe that prototype, not this integration build.

With Gemma 4 E2B Q6_K fixed, 738 fresh synthetic checkpoints produced 306 current suggestions and 383 hybrid suggestions. All 306 current suggestions were preserved. Claude Opus rated the 77 additions as 71 helpful and 6 neutral; 68 additions were at most three characters. Warm headless mean latency increased from 36.6 to 40.2 ms. Dynamic latency was inconclusive. This is a modest coverage gain, not a demonstrated speed improvement or a human acceptance study.

The older regression corpus retained two bad added suggestions: a redundant Serbian clitic and a Latin-script word after a Cyrillic prefix. Existing bad suggestions remain. Real typing, acceptance, and first-visible end-to-end latency still need user evaluation.

## Reproduce a comparison

Use the normal `--cotyping-replay <input.json> --model-path <model.gguf>` headless entry point. Run the same input twice, changing only the optional top-level `selectiveOneWordHybrid` field from `false` to `true`. Keep the confidence gate on. Replay output records the flag and per-request latency. Remote replay rejects the hybrid flag rather than silently testing another decoder.

The non-UI `CotypingFirstWordConfidenceTests` include actual-model composition and streaming checks when `TEST_RUNNER_LOKALBOT_CANDIDATE_TEST_MODEL` points to the fixed GGUF during `xcodebuild test`. Settings, route switching, cancellation, cache invalidation and rollback have focused regression coverage. Run the settings UI test on a hosted runner with `Scripts/ui-tests.sh --remote CotypingSettingsUITests`; never run it on the developer's Mac.
