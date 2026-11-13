# MiniCPM5-2B against LokalBot's local Qwen default

Tested September 10, 2026. **Keep Qwen3.5-4B as the default.** MiniCPM5-2B is faster and smaller, and its native tool calls work in the bundled runtime. Its accuracy under the current extraction settings is weaker, including ownership, timestamps, and Serbian Cyrillic. Q8 improves some answers but does not close the gap. Thinking improves factual extraction at a substantial latency cost.

This is a bounded synthetic pilot on the user's Mac, including the production Swift extraction pipeline. It is not a general model ranking or validation on the user's real meeting library.

## Setup

- Apple M4 Max, 48 GiB unified memory.
- Repository source: `5cb2d9f38acb2508c386aabb5b16c2ec05ea7d75`.
- Bundled `Vendor/llama-cpp/llama-server`, reported build `b10173-b10173`, configured for full Metal offload (`-ngl 99`), 32,768-token context, Jinja chat templates, and 2,048 MiB prompt cache.
- One model process at a time. Direct tests use one slot and `cache_prompt=false`; the existing production replay uses the runtime's four-slot default, reporting 32,768 tokens per slot.
- Both primary models use Q4_K_M. Their files were checked against published SHA-256 values. MiniCPM's official Q8_0 was also verified and tested as an extraction-only precision control.
- The compared baseline is the app's built-in local default. The saved active backend was OpenAI-compatible with `z-ai/glm-5.3-flash`; that cloud model was not part of this local comparison.
- All fixtures, mock tool results, and generated meeting files are synthetic. No model-generated command or external action was executed.

Model versions, exact checksums, and runtime settings are in [manifest.json](manifest.json) and each result directory's `runtime.json`.

## Short extraction

Twelve cases cover accepted assignments, negation, request/acceptance context, corrected decisions, missing information, Serbian Latin/Cyrillic, quoted prompt injection, timestamps, conditional commitments, speaker identity, and meeting provenance. Each case ran twice. These repeated greedy runs are not independent examples.

The primary comparison matches production extraction: temperature 0, thinking disabled, 1,024 output tokens, and constrained JSON. The thinking diagnostic uses temperature 1, top-p 0.95, a 1,024-token thinking allowance within 2,048 total output tokens, and the same questions/schema. Other sampler defaults come from the bundled runtime.

| Model and extraction mode | Factually correct cases, both repeats | Correct fields, both repeats | Exact-string cases, both repeats | Median request time |
|---|---:|---:|---:|---:|
| MiniCPM Q4, thinking off | 7/12 | 68/86 (79.1%) | 5/12 | 0.284 s |
| MiniCPM Q8, thinking off | 8/12 | 76/86 (88.4%) | 5/12 | 0.338 s |
| Qwen3.5-4B Q4, thinking off | 9/12 | 80/86 (93.0%) | 7/12 | 0.554 s |
| MiniCPM Q4, thinking on | 10/12 | 80/86 (93.0%) | 7/12 | 5.818 s |

Every direct extraction response was valid JSON and ended normally. Valid JSON did not establish factual correctness. MiniCPM's thinking mode matched Qwen's field accuracy on this set, with about 10.5 times the median request latency. This diagnostic changes both thinking and sampling and therefore does not isolate their individual effects.

Manual scoring accepts harmless variations such as `Friday`/`by Friday`, translated weekday names, and `A-104`/`Meeting A-104`. The original exact scores remain in raw results. Translated weekday names still fail the explicit request to preserve wording. [reviewed-scores.json](reviewed-scores.json) lists every adjustment; [review_scores.py](review_scores.py) applies the same allowances to all models.

Observed substantive errors include:

- MiniCPM Q4 assigned Alex's accepted checklist task to Ana and cited `03:40` instead of the acceptance at `03:20`. Q8 corrected the owner but retained the wrong timestamp.
- MiniCPM Q4 invented specific 2024 dates for Serbian relative deadlines. Q8 recovered the intended weekdays.
- Both MiniCPM precisions confused a Cyrillic deadline with a transcript timestamp and treated completed work as a new task. Thinking returned empty Cyrillic owner/deadline fields.
- Both primary models confused `this afternoon` with an unrelated certificate expiry `next month` in one case. Thinking corrected this for MiniCPM.
- Both models made errors involving duplicate display names and explicit user identity.

## Tool calls and long context

These are API-level tests with synthetic local tools, not a full Pi Agent Mode session. Tool requests enable thinking, cap total output at 2,048 tokens, and use temperature 0. The tools search/read a fixture meeting or return a mocked result; no email, shell, or file mutation occurs.

| Measurement | MiniCPM Q4 | Qwen3.5-4B Q4 |
|---|---:|---:|
| Native tool/no-tool cases correct | 5/6, twice | 6/6, twice |
| Median single-request tool-case time | 0.454 s | 1.567 s |
| Search → read newest meeting → cited answer | Pass | Pass |
| Multi-step total request time | 2.381 s | 5.989 s |
| Revised facts recovered from long archive | 6/6, twice | 6/6, twice |
| Median long-archive request time | 10.736 s | 18.036 s |
| Long-archive input tokens | 16,282 | 19,328 |
| Peak server physical footprint, full primary suite | 2.41 GiB | 4.18 GiB |
| Peak server RSS, full primary suite | 3.75 GiB | 6.55 GiB |
| Weight file size | 1.56 GB | 2.74 GB |

MiniCPM returned executable OpenAI-format `tool_calls` directly from stock b10173. The diagnostic XML adapter was never needed. Its one tool-case error requested ten meetings when the user asked for three. Both models selected the newest meeting and returned the correct launch date, checklist owner, meeting ID, and timestamps in the multi-step case.

The long archive is the same 450-record text for both models; token counts differ by tokenizer. It tests revisions and provenance at several positions within the app's context limit, not the advertised 128K maximum. Memory is sampled server-process RSS/physical footprint through macOS `proc_pid_rusage` every 200 ms. It excludes the rest of the application and is not total machine memory use. MiniCPM Q4's measured process footprint was 42.3% lower.

## Production extraction replay

The existing [SummaryEfficiency replay](../../SummaryEfficiency/README.md) ran current `MeetingNotesGenerator` and its actual validation/repair/rendering path. The native test target was built first with `Scripts/test/unit-tests.sh MeetingNotesReplayTests`; UI tests were excluded. The replay fixture contains seven accepted commitments, including three user commitments, and one unassigned request. Completed work and speculative ideas are distractors.

| Model / run | Pipeline result | User commitments retained with correct owner and citation | All accepted commitments retained correctly | Extraction wall time |
|---|---|---:|---:|---:|
| MiniCPM Q4, cold | Incomplete | 1/3 | 2/7 | 3.012 s |
| MiniCPM Q4, warm | Incomplete | 2/3 | 3/7 | 2.680 s |
| Qwen Q4, cold | Incomplete | 2/3 | 5/7 | 10.229 s |
| Qwen Q4, warm | Complete | 3/3 | 3/7 | 10.375 s |

MiniCPM's cold run lost the onboarding commitment, rejected a release-note action with distant context, and left Iva's explicit commitment without an owner. Its warm run also missed the release-note commitment. The app correctly retained these as incomplete notes.

Qwen also showed reliability limits: its cold repair missed a user commitment, and its complete warm result retained all three user commitments but omitted four other accepted commitments. Pipeline completion therefore does not certify comprehensive task coverage. Some action links in the cold Qwen summary point to earlier contextual timestamps even though the underlying citation list also contains the actual commitment.

Because retained work and completion differ, production timings are descriptive rather than equivalent-work speed comparisons. "Cold" includes a fresh runtime process, without flushing the macOS filesystem cache; the table above excludes startup. Startup-inclusive figures and raw accepted/rejected records are in [replay-scores.json](replay-scores.json) and [results](results/). Each run used a fresh output directory, so saved extraction checkpoints could not bypass inference. The native replay's request model label is hardcoded to Qwen, but its isolated server loads the specified weight file; the server model path and metadata confirm the actual tested model.

## Recommendation and limits

Keep Qwen3.5-4B as the local default. MiniCPM is a credible candidate for an experimental smaller agent model: its API tool integration works and this pilot shows useful latency/memory savings. Default adoption needs stronger ownership, timestamp, Cyrillic, and complete-task coverage. Q8 improves accuracy at 2.68 GB, close to Qwen's weight size, without surpassing Qwen on the short extraction set. Thinking improves accuracy while erasing the short-task latency advantage.

The results also identify follow-up work for the existing Qwen extraction pipeline. No production source, catalog default, installed app, or saved settings were changed. Benchmark scripts and synthetic artifacts are the only new repository files.

This pilot uses 12 short cases, six tool cases, one long archive, one multi-step workflow, and one synthetic production meeting. It does not establish performance on real long meetings, broader languages, battery use, concurrent app workloads, unconstrained reasoning, or a full Agent Mode session. Q8 and the thinking diagnostic covered short extraction only. Benchmark servers were stopped after each run.

## Reproduce

From the repository root, with the verified model files in `/private/tmp/lokalbot-minicpm5-20260910/models`:

```sh
uv run --no-project Benchmarks/think/MiniCPM5/2026-09-10/make_cases.py

uv run --no-project Benchmarks/think/MiniCPM5/2026-09-10/run.py \
  --model /private/tmp/lokalbot-minicpm5-20260910/models/MiniCPM5-2B-Q4_K_M.gguf \
  --output /private/tmp/minicpm-new-run --tool-thinking

uv run --no-project Benchmarks/think/MiniCPM5/2026-09-10/run.py \
  --model "$HOME/Library/Application Support/me.dotenv.LokalBot/models/Qwen3.5-4B-Q4_K_M.gguf" \
  --output /private/tmp/qwen-new-run --tool-thinking

# Precision control: use Q8 with --group extraction.
# Thinking diagnostic: use Q4 with --group extraction --extraction-thinking --temperature 1.

Scripts/test/unit-tests.sh MeetingNotesReplayTests
uv run --no-project Benchmarks/think/SummaryEfficiency/run.py \
  --transcript "$PWD/Benchmarks/think/MiniCPM5/2026-09-10/fixtures/transcript.json" \
  --model /private/tmp/lokalbot-minicpm5-20260910/models/MiniCPM5-2B-Q4_K_M.gguf \
  --output /private/tmp/minicpm-production-new-run --skip-build
```

Use fresh output directories. Model source: [official GGUF release at the pinned revision](https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/tree/d00c954e5f9a0f2605468f24703ffa7e5cb0c492). The original claim was in [the linked X post](https://x.com/trikcode/status/2097715781983232382).
