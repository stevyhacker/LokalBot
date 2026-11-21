"""Posts for lokalbot.com/blog: releases, benchmarks, and notes on how LokalBot is built.

Rendered by Website/generator/render_web.py into Website/public/blog.html, Website/public/blog/<slug>.html, and
the Atom feed at Website/public/blog/feed.xml. Newest first. Keep product facts aligned
with the README. A post about something published in full elsewhere summarizes
it and links to the original instead of copying it.

Bodies are served from /blog/<slug>, so every internal link and image path
must be root-relative ("/benchmarks", "/assets/blog/...").

Each post needs a share image at Website/public/assets/blog/og/<slug>.png. After adding
a post or changing its title, run `python3 Website/generator/render_social_images.py
--only <slug>` before render_web.py.
"""

BLOG_INDEX = {
    "title": "LokalBot Blog — Releases, Benchmarks, and Build Notes",
    "description": "News from the LokalBot project: releases, local model benchmarks, and notes on how the app is built. Subscribe with the Atom feed.",
    "h1": "Blog",
    "lead": "Releases, local model benchmarks, and notes on how LokalBot is built. When something is posted elsewhere first, the full version ends up here.",
}

POSTS = [
    {
        "slug": "gbrain-vs-lokalbot-memory-benchmark",
        "published": "2026-11-19",
        "title": "39 ms and 50 MB vs. 255 ms and 1 GB: Benchmarking Local Meeting Retrieval on 1,576 QMSum Questions",
        "description": "Comparing LokalBot's SQLite FTS5 + EmbeddingGemma 2 retrieval against GBrain on 232 public QMSum meetings and 1,576 questions: recall, latency, context size, memory, and where each system wins.",
        "eyebrow": "Benchmark",
        "h1": "39 ms and 50 MB vs. 255 ms and 1 GB: benchmarking local meeting retrieval on QMSum",
        "lead": "Does a heavier local memory server beat plain SQLite FTS5 plus a 310 MB embedding model? We tested LokalBot's retrieval against GBrain on 232 public meetings and 1,576 questions.",
        "read_time": "6 min read",
        "body": """
        <h2>Why we ran this</h2>
        <p>Every few weeks a new local memory layer promises better recall for coding agents and personal assistants. LokalBot's own retrieval is intentionally plain: SQLite FTS5 BM25 plus EmbeddingGemma 2 (310 MB, 768 dimensions) joined with reciprocal rank fusion. We tested whether replacing it with <a href="https://github.com/garrytan/gbrain" target="_blank" rel="noopener">GBrain</a> (v0.60.734.0 on PGLite over stdio MCP) improved meeting recall enough to justify the extra runtime.</p>

        <h2>The setup</h2>
        <p>We used the public <a href="https://github.com/Yale-LILY/QMSum" target="_blank" rel="noopener">QMSum</a> corpus (232 meetings, 129,177 turns, 2.1 million words across AMI product design, ICSI research, and parliamentary committees) and all 1,576 specific questions with human-marked answer spans. No personal data was used. Both systems ingested the exact same meetings and shared one local <code>llama-server:embeddinggemma-2</code> instance on an Apple M4 Max (48 GB). Confidence intervals come from 2,000 paired bootstrap resamples over questions.</p>

        <h2>Results</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">Retrieval comparison on 1,576 QMSum questions (Apple M4 Max)</caption>
            <thead>
              <tr><th scope="col">Metric</th><th scope="col">LokalBot keyword</th><th scope="col">GBrain keyword</th><th scope="col">LokalBot hybrid</th><th scope="col">GBrain hybrid</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">Meeting R@1</th><td>0.193</td><td><strong>0.253</strong></td><td><strong>0.280</strong></td><td>0.239</td></tr>
              <tr><th scope="row">Meeting R@4</th><td>0.335</td><td>0.412</td><td><strong>0.475</strong></td><td>0.367</td></tr>
              <tr><th scope="row">Meeting R@10</th><td>0.456</td><td>0.468</td><td><strong>0.595</strong></td><td>0.370</td></tr>
              <tr><th scope="row">MRR</th><td>0.274</td><td>0.325</td><td><strong>0.379</strong></td><td>0.295</td></tr>
              <tr><th scope="row">Gold turn in evidence</th><td>0.260</td><td><strong>0.402</strong></td><td>0.367</td><td>0.340</td></tr>
              <tr><th scope="row">Median evidence handed to LLM</th><td>718 chars</td><td>97,444 chars</td><td><strong>1,248 chars</strong></td><td>96,761 chars</td></tr>
              <tr><th scope="row">Query latency (p50 / p95)</th><td>3 / 8 ms</td><td>159 / 212 ms</td><td><strong>39 / 52 ms</strong></td><td>255 / 342 ms</td></tr>
            </tbody>
          </table>
        </div>

        <h2>What stood out</h2>
        <ul>
          <li><strong>Hybrid retrieval favored LokalBot cleanly.</strong> With the same embedder, LokalBot led GBrain by +4.1 points on R@1 (95% CI +1.9 to +6.2) and +10.9 points on R@4 (+8.2 to +13.3), at <strong>6.5× lower median latency</strong> (39 ms vs. 255 ms) and roughly <strong>50 MB vs. 1 GB</strong> resident memory (excluding the shared 0.5 GB embedding server).</li>
          <li><strong>Context budget matters on local models.</strong> GBrain's default <code>query</code> hands back a median ~97,000 characters (full transcripts) per question. LokalBot hands back 1,248 characters (top 4 meetings, up to 6 moments of 400 characters each), which fits comfortably inside a local 4B model or a coding agent's MCP tool budget.</li>
          <li><strong>GBrain's keyword-only search beat LokalBot's keyword-only search.</strong> On lexical queries alone, GBrain hit R@1 0.253 vs. 0.193 and got the gold turn into evidence on 40.2% vs. 26.0% of questions. That points directly at an improvement we can take into LokalBot's FTS5 query formulation without adopting a heavier database.</li>
          <li><strong>Restated contradictions are still unsolved in both.</strong> Explicit edits and deletions worked cleanly in both systems (40/40 and 39/40), but when a later meeting silently reversed an earlier decision, neither ranked the newer meeting above the older one reliably (7/20 in LokalBot, 8/20 in GBrain).</li>
        </ul>

        <h2>Data and reproduction</h2>
        <p>The corpus builder, harness, scorer, and full report are in <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/memory/GBrain/2026-11-17/REPORT.md" target="_blank" rel="noopener">Benchmarks/memory/GBrain/2026-11-17/REPORT.md</a>. A keyword-only repeat on a 4-core Intel Xeon produced identical accuracy numbers. See the <a href="/benchmarks">benchmarks page</a> for the rest of LokalBot's local stack.</p>
        """,
    },
    {
        "slug": "local-stt-vs-cloud-apis",
        "published": "2026-11-18",
        "title": "Local Speech-to-Text vs. Cloud APIs on Real Meetings: Qwen3-ASR 1.7B, Parakeet, Gemini, and OpenAI",
        "description": "We benchmarked LokalBot's local Qwen3-ASR 1.7B and Parakeet TDT 0.6B v3 against Gemini 3.5/3.8, GPT-4o Transcribe, GPT Transcribe, and Qwen-Audio cloud APIs on AMI meetings and two-track calls.",
        "eyebrow": "Benchmark",
        "h1": "Local speech-to-text vs. cloud APIs on real meetings",
        "lead": "No closed cloud speech-to-text API measurably beat LokalBot's local Qwen3-ASR 1.7B on real two-track meetings—and several cloud APIs failed in ways that are hard to catch in clean benchmarks.",
        "read_time": "6 min read",
        "body": """
        <h2>Why test against cloud APIs</h2>
        <p>People often assume running transcription on a laptop means trading away accuracy for privacy. We tested LokalBot's default local models—<strong>Qwen3-ASR 1.7B (8-bit)</strong> and <strong>Parakeet TDT 0.6B v3</strong> on an Apple M4 Max—head-to-head against direct API calls to OpenAI (<code>gpt-transcribe</code>, <code>gpt-4o-transcribe</code>, <code>gpt-4o-mini-transcribe</code>), Google (<code>gemini-3.5-transcribe</code>, <code>gemini-3.8-flash</code>), and Alibaba Model Studio (<code>qwen-audio-3.1-asr-flash</code>, <code>qwen3-asr-flash</code>).</p>

        <h2>Public AMI meetings (human reference)</h2>
        <p>Sixteen 90–120 second windows from four AMI Mix-Headset test meetings (27.4 minutes, 4,160 reference words), containing heavy overlapped speech on a single mixed channel:</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">AMI Mix-Headset WER comparison across cloud APIs and local models</caption>
            <thead>
              <tr><th scope="col">System</th><th scope="col">WER</th><th scope="col">95% CI</th><th scope="col">Low-overlap WER</th><th scope="col">List price / hr</th><th scope="col">Speed</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">Gemini 3.8 Flash (prompted)</th><td><strong>16.7%</strong></td><td>14.0–19.0%</td><td>6.2%</td><td>$0.21</td><td>18×</td></tr>
              <tr><th scope="row">Qwen3-ASR 1.7B (local)</th><td>17.6%</td><td>14.6–20.5%</td><td>7.1%</td><td>$0</td><td>44×</td></tr>
              <tr><th scope="row">Qwen3-ASR Flash (API)</th><td>18.1%</td><td>14.6–20.8%</td><td>6.3%</td><td>$0.13</td><td>25×</td></tr>
              <tr><th scope="row">Qwen-Audio 3.1 ASR Flash</th><td>18.5%</td><td>14.6–21.8%</td><td>5.6%</td><td>$0.02</td><td>10×</td></tr>
              <tr><th scope="row">Parakeet TDT 0.6B v3 (local)</th><td>19.2%</td><td>15.8–22.3%</td><td>8.1%</td><td>$0</td><td>129×</td></tr>
              <tr><th scope="row">GPT-4o mini Transcribe</th><td>21.8%</td><td>17.5–25.7%</td><td>7.8%</td><td>$0.18</td><td>34×</td></tr>
              <tr><th scope="row">GPT Transcribe</th><td>22.2%</td><td>17.6–27.5%</td><td>6.9%</td><td>$0.27</td><td>30×</td></tr>
              <tr><th scope="row">GPT-4o Transcribe</th><td>23.0%</td><td>18.4–27.0%</td><td>6.2%</td><td>$0.36</td><td>25×</td></tr>
            </tbody>
          </table>
        </div>

        <h2>Two-track real meetings: where cloud APIs broke</h2>
        <p>On 99 two-track chunks (69.9 minutes) from real meetings scored by cross-family ROVER consensus disagreement (measuring agreement, not human ground truth), <strong>local Qwen3-ASR 1.7B placed first at 4.2% disagreement</strong> (0.4 s median latency, 0 dropped spans), tied within confidence intervals with Gemini 3.5 Transcribe (4.5%, 6.3 s latency) and Qwen-Audio 3.1 ASR Flash (4.6%, 2.9 s latency).</p>
        <p>Two failure modes jumped out immediately:</p>
        <ul>
          <li><strong>Gemini 3.8 Flash invented speech on quiet clips.</strong> Despite leading AMI WER by 0.9 points, on real meeting chunks it hallucinated 115 words across 15 spans—including turning a 1.2-second clip that every other system heard as one word or silence into a fluent 30-word sentence.</li>
          <li><strong>GPT-4o Transcribe silently dropped microphone speech.</strong> It logged 278 dropped words in runs of four or more and 42% disagreement on one meeting's microphone track (vs. 7–14% for the other systems). Only ~20% of those dropped words appeared on the system track, ruling out echo suppression.</li>
          <li><strong>Span length matters inside our own app.</strong> The test also caught a bug in LokalBot's older production path: cutting audio at speaker turns before transcription hurt AMI WER (26.5% vs. 17.7%). Assigning speakers <em>after</em> transcribing longer spans closed that gap.</li>
        </ul>

        <h2>Data and reproduction</h2>
        <p>Full tables, ROVER methodology, and caveats are in <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md" target="_blank" rel="noopener">Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md</a> and the follow-up <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/transcribe/QwenSpanLength/results/2026-09-30/REPORT.md" target="_blank" rel="noopener">span-length report</a>. Try the same local models offline in <a href="/">LokalBot</a>.</p>
        """,
    },
    {
        "slug": "local-autocomplete-56ms-benchmark",
        "published": "2026-11-17",
        "updated": "2026-11-19",
        "title": "56 ms Local System-Wide Autocomplete: Benchmarking Gemma 4 E2B vs. LFM2.5 1.2B",
        "description": "Headless keystroke-by-keystroke engine benchmark of LokalBot's local autocomplete: 56 ms median with Gemma 4 E2B vs. 26 ms with LFM2.5 1.2B, accuracy across 788 word positions, and five flaws we fixed in our own harness.",
        "eyebrow": "Benchmark",
        "h1": "56 ms local system-wide autocomplete: Gemma 4 E2B vs. LFM2.5 1.2B",
        "lead": "System-wide inline autocomplete only feels invisible when it stays under ~100 ms per keystroke and knows when to stay silent. Here are the measured numbers behind LokalBot's Balanced and Lightweight presets.",
        "read_time": "5 min read",
        "body": """
        <h2>Measuring autocomplete without fooling ourselves</h2>
        <p>Our original 28-scenario autocomplete check had five flaws: it treated an intentional confidence-gate silence as a safety failure, accepted only one exact word tail for partial-word completions, mixed 10–40 s cold startup into steady-state latency, stole keyboard focus by launching the full app, and never measured next-word accuracy.</p>
        <p>We replaced it with a headless engine runner (<code>--cotyping-bench</code>) that exercises the exact production <code>LlamaCotypingRuntime</code> with hybrid decoding, certified prefix search, and prefix healing across 28 safety/behaviour checks (5 deterministic passes) plus 96 phrases replayed at all 788 word boundaries and 8 phrases typed one character at a time.</p>

        <h2>Gemma 4 E2B Base vs. LFM2.5 1.2B Instruct (Apple M4 Max)</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">Autocomplete engine benchmark comparing Gemma 4 E2B Base Q6_K and LFM2.5 1.2B Instruct Q4_K_M</caption>
            <thead>
              <tr><th scope="col">Metric</th><th scope="col">Gemma 4 E2B Base (Balanced)</th><th scope="col">LFM2.5 1.2B Instruct (Lightweight)</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">Unsafe results (28 checks × 5 passes)</th><td><strong>0</strong></td><td><strong>0</strong></td></tr>
              <tr><th scope="row">Word completions</th><td>12 / 13</td><td>12 / 13</td></tr>
              <tr><th scope="row">Next-word accuracy (788 positions)</th><td><strong>23.1%</strong></td><td>20.7%</td></tr>
              <tr><th scope="row">English accuracy (624 positions)</th><td>25.3%</td><td>24.2%</td></tr>
              <tr><th scope="row">Non-English accuracy (164 positions)</th><td><strong>14.6%</strong></td><td>7.3%</td></tr>
              <tr><th scope="row">Right when shown (precision)</th><td><strong>50.1%</strong></td><td>43.0%</td></tr>
              <tr><th scope="row">Per keystroke while typing (median / p95)</th><td>56 / 102 ms</td><td><strong>26 / 76 ms</strong></td></tr>
              <tr><th scope="row">Model load time</th><td>0.65 s</td><td><strong>0.16 s</strong></td></tr>
            </tbody>
          </table>
        </div>

        <h2>What the numbers actually say</h2>
        <ul>
          <li><strong>In English, the two models are effectively tied</strong> (+1.1 points, 95% bootstrap interval −1.4 to +3.5), while LFM2.5 is 2–3× faster per keystroke (26 ms median) and weighs only 0.73 GB.</li>
          <li><strong>Gemma 4 E2B earns the Balanced default on precision and non-English text.</strong> When it chooses to show a suggestion, it is right 50.1% of the time vs. 43.0% for LFM2.5, and its non-English lead (+7.3 points) comes largely from languages like Serbian where LFM2.5 stayed silent.</li>
          <li><strong>Silence is a feature.</strong> Both models withheld suggestions on the exact same 3 open-ended prompts (<code>notes-list</code>, <code>comma-clause</code>, <code>sentence-start</code>) and stayed quiet mid-word (<code>rec|eive</code>), producing zero unsafe suggestions across all 140 passes.</li>
        </ul>

        <h2>First suggestion after a pause (November 18, 2026)</h2>
        <p>Steady-state speed only tells half the story: after three minutes without a decode, llama.cpp releases Metal weight residency (180 s default keep-alive), and the GPU clocks down within seconds. On an M4 Max (Gemma 4 E2B Q6_K), warming the runtime with a single throwaway token on wake, unlock, click, or the first keystroke (then removing that token so the cached prompt stays intact) brings the first suggestion back to steady-state latency:</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">First suggestion latency after idle pauses on Apple M4 Max (Gemma 4 E2B Q6_K)</caption>
            <thead>
              <tr><th scope="col">Idle pause</th><th scope="col">Before</th><th scope="col">Warm-up at key</th><th scope="col">Warm-up just before</th><th scope="col">Warm reference</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">20 s</th><td>61 ms</td><td>51 ms</td><td><strong>47 ms</strong></td><td>46–50 ms</td></tr>
              <tr><th scope="row">60 s</th><td>59 ms</td><td><strong>48 ms</strong></td><td>50 ms</td><td>48–50 ms</td></tr>
              <tr><th scope="row">300 s (5 min)</th><td>95–130 ms</td><td>50–53 ms</td><td><strong>49 ms</strong></td><td>47–49 ms</td></tr>
            </tbody>
          </table>
        </div>
        <p>Four warm-up touches over a five-minute pause added 18 mJ of CPU energy (468 vs. 450 mJ) and never reload a model freed under memory pressure. A 30-minute pause under memory pressure—where OS file paging dominates—has not been re-measured yet. Full methodology and raw logs live in <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/autocomplete/Cotyping/results/2026-11-18-first-after-pause/REPORT.md" target="_blank" rel="noopener">Benchmarks/autocomplete/Cotyping/results/2026-11-18-first-after-pause/REPORT.md</a>.</p>

        <h2>Choosing between them in LokalBot</h2>
        <p>Both presets ship built into LokalBot: <strong>Balanced local</strong> uses Gemma 4 E2B Base, and <strong>Lightweight local</strong> switches to LFM2.5 1.2B Instruct for faster typing and a smaller disk footprint. For a feature-by-feature comparison with Cotypist and Cotabby, see <a href="/blog/autocomplete-that-knows-your-meetings">Autocomplete that knows your meetings</a>. Full category breakdowns and commands to rerun the engine harness are in <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/REPORT.md" target="_blank" rel="noopener">Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/REPORT.md</a>.</p>
        """,
    },
    {
        "slug": "recall-vs-restraint-memory-benchmark",
        "published": "2026-10-23",
        "updated": "2026-11-02",
        "title": "Recall vs. Restraint: Testing Which Local Models Know When Not to Save a Memory",
        "description": "A 120-case benchmark of local models writing personal memories, scored on what they save and on what they correctly leave out: Qwen3.5 4B and 9B, Hy-Memory 30B-A3B, LFM2.5 24B-A2B, and MemT-1.0-Nano.",
        "eyebrow": "Benchmark",
        "h1": "Recall vs. restraint: which local models know when not to save a memory",
        "lead": "A memory writer has two jobs: save what is useful, and leave out everything else. Most memory benchmarks only measure the first. This one measures both.",
        "read_time": "6 min read",
        "body": """
        <h2>Why restraint matters</h2>
        <p>LokalBot's Personal Context learns facts, preferences, goals, and principles from what you type and say, so that agents you allow can tailor their work to you. A missed memory costs little: the next conversation usually brings it up again. A wrong one is worse. It quietly ends up in the context every agent reads, and nobody notices until an answer is off.</p>
        <p>So the test asks for both recall and restraint. Three kinds of cases make the difference visible:</p>
        <ul>
          <li><strong>Who said it.</strong> “I live in Valencia” should be saved. “My colleague said, ‘I live in Valencia’” should not.</li>
          <li><strong>Already known.</strong> A new preference should be saved. One already in the known-memories list should be skipped.</li>
          <li><strong>Policy.</strong> A job title mentioned alongside a salary should be kept, and the salary left out.</li>
        </ul>

        <h2>The test</h2>
        <p>The benchmark has 120 synthetic cases arranged as 60 contrast pairs. The main comparison uses the 96 English cases: 52 contain one useful memory to extract, and in 44 the correct output is an empty list. A separate 24-case Serbian slice is reported on its own.</p>
        <p>Every model received the same application prompt with its native chat template, an enforced JSON schema, temperature 0, seed 0, thinking disabled, and a single pass, with no model-specific prompt tuning. The GGUF models ran one after another through llama.cpp on the same Ryzen 7 9700X server. This measures accuracy, not speed. A recalled memory only counts when it also cites the right source line.</p>

        <h2>Results</h2>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">Results on the 96 English cases</caption>
            <thead>
              <tr><th scope="col">Model</th><th scope="col">Useful memories recalled</th><th scope="col">Unwanted proposals</th><th scope="col">Empty cases correct</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">Qwen3.5 4B, Q4_K_M</th><td>30/52 (57.7%)</td><td>3</td><td>42/44 (95.5%)</td></tr>
              <tr><th scope="row">Qwen3.5 9B, Q4_K_M</th><td>37/52 (71.2%)</td><td>5</td><td>40/44 (90.9%)</td></tr>
              <tr><th scope="row">Hy-Memory 30B-A3B, official Q4_K_M</th><td>52/52 (100%)</td><td>76</td><td>0/44 (0%)</td></tr>
              <tr><th scope="row">LFM2.5 24B-A2B, QAD Q4_0</th><td>40/52 (76.9%)</td><td>53</td><td>10/44 (22.7%)</td></tr>
              <tr><th scope="row">MemT-1.0-Nano, NF4 experts / BF16 dense</th><td>51/52 (98.1%)</td><td>6</td><td>39/44 (88.6%)</td></tr>
            </tbody>
          </table>
        </div>
        <figure class="blog-figure">
          <img src="/assets/blog/memory-retention-recall-vs-restraint.webp" width="1600" height="864" alt="Bar charts comparing five models on useful memories recalled, empty cases handled correctly, and unwanted memory proposals, with the numbers from the table above." loading="lazy" decoding="async" />
          <figcaption>The 96 English cases. Higher is better in the first two columns, lower in the third.</figcaption>
        </figure>

        <h2>What stood out</h2>
        <ul>
          <li><strong>Perfect recall can hide the real problem.</strong> Hy-Memory captured every eligible memory and failed all 44 cases where the right answer was nothing, with 76 unwanted proposals. Scored on recall alone, it would look like the best model here.</li>
          <li><strong>The Qwen models held back.</strong> Both missed more valid memories, but they handled over 90% of the empty cases and made only three and five unwanted proposals.</li>
          <li><strong>LFM2.5 copied from the instructions.</strong> In several cases it proposed “I live in Belgrade”, an example from the prompt with no support in the conversation. It also often returned the source sentence instead of the required source-line ID. Accepting exact quotations recovered 9 of its 18 invalid English citations, raising exact source selection from 51 to 56 of 96 cases, but that only repairs formatting. The table keeps the strict scoring.</li>
          <li><strong>MemT-1.0-Nano was the best balance.</strong> A reader on <a href="https://www.reddit.com/r/LocalLLaMA/comments/1xd95n0/recall_vs_restraint_testing_which_local_llms_know/" target="_blank" rel="noopener">r/LocalLLaMA</a> suggested it, and it was added on October 25: 51 of 52 useful memories, 6 unwanted proposals, and 39 of 44 empty cases. On the Serbian slice it recalled 13 of 13, made 3 unwanted proposals, and passed 8 of 11 empty cases, but three of its outputs switched language or script.</li>
        </ul>

        <h2>Caveats</h2>
        <ul>
          <li>MemT-1.0-Nano ran with experimental NF4 expert offload through Transformers on a Radeon RX 6600 XT; the other models ran as GGUF files in llama.cpp on a CPU. There is no matched run of its Qwen3.6-35B-A3B backbone, so the comparison isn't controlled for hardware or precision.</li>
          <li>Each case starts from a fresh state, so MemT's persistent memory feature isn't exercised.</li>
          <li>An AI assistant wrote the cases and graded the semantic decisions with the model names visible. There is no independent human validation and no claim of statistical significance.</li>
        </ul>

        <h2>What it means for LokalBot</h2>
        <p>These results don't change LokalBot's defaults. What they confirm is that a memory writer has to be judged on what it leaves out as much as on what it finds. The suggestions Personal Context learns appear under <strong>To review</strong> in Settings → Personal Context, where you keep or dismiss them.</p>

        <h2>Data</h2>
        <p>Everything needed to check or rerun the comparison is in the repository: the <a href="https://github.com/stevyhacker/lokalbot/tree/master/Benchmarks/think/MemoryRetention/2026-10-23" target="_blank" rel="noopener">benchmark folder</a> with the cases, prompts, and scorer, the <a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/think/MemoryRetention/2026-10-23/memt-nano/REPORT.md" target="_blank" rel="noopener">MemT report</a> with every failed case, and the raw responses. Other model results are on the <a href="/benchmarks">benchmarks page</a>.</p>
        """,
    },
    {
        "slug": "windows-and-linux-alpha",
        "published": "2026-10-20",
        "updated": "2026-11-11",
        "title": "LokalBot for Windows and Linux Is in Alpha",
        "description": "LokalBot 0.11 adds a native Windows and Linux app written in Rust with GPUI: meeting notes, transcription, dictation, autocomplete, and search on your own computer, reading the same library as the Mac app.",
        "eyebrow": "Release",
        "h1": "LokalBot is on Windows and Linux, in alpha",
        "lead": "Until version 0.11, LokalBot only ran on Apple Silicon Macs. Now there is a native app for Windows and Linux with the same pages and the same library format, so a library recorded on one computer opens on the others.",
        "read_time": "5 min read",
        "body": """
        <h2>What works</h2>
        <p>Updated November 3, 2026: most features that were Mac only when this post came out have since been ported, so these lists describe the app as it is now.</p>
        <p>The Windows and Linux app is written in Rust with <a href="https://www.gpui.rs" target="_blank" rel="noopener">GPUI</a>, the UI framework behind the Zed editor. Meetings, transcription, Ask, search, day memory, screen context, dictation, autocomplete, selection actions, spoken summaries, Files, overnight review, Personal Context, meeting note and daily exports, calendar, Agent Mode, and the CLI and MCP server for coding agents all work. Like the Mac app, it runs its models on your computer by default, and it has no account and no telemetry.</p>
        <figure class="blog-figure">
          <img src="/assets/blog/linux-meetings.webp" width="1600" height="1000" alt="LokalBot on Linux showing a meeting's recap, action items with timestamps, and decisions, next to a list of recent meetings." loading="lazy" decoding="async" />
          <figcaption>A meeting's recap and action items on Linux, with fictional demo data.</figcaption>
        </figure>

        <h2>What's still missing</h2>
        <ul>
          <li><strong>The Windows build isn't code-signed yet.</strong> SmartScreen asks before the first launch: choose <strong>More info → Run anyway</strong>.</li>
          <li><strong>Wayland support is partial.</strong> Autocomplete in other apps works as an input method on Sway, Hyprland, GNOME, where you also add LokalBot as an input source, and, since 0.12.3, KDE Plasma, where you choose it under Virtual Keyboard. It has only been tried on headless Sway, GNOME, and KWin with stand-in suggestions, and Hyprland itself hasn't been run (<a href="/explainers/wayland-autocomplete.pdf">how it works</a>). On other compositors it works in the practice editor in Settings. For dictation and selection actions on Wayland, bind <code>lokalbot dictate</code> and <code>lokalbot selection-actions</code> to shortcuts in your desktop's settings.</li>
          <li><strong>Meeting audio isn't always one app's.</strong> On Windows and Linux LokalBot records the meeting app alone where it can be separated, and otherwise everything the computer plays.</li>
          <li><strong>Remembered speakers only suggest.</strong> Later meetings offer a remembered name for you to apply, rather than naming the speaker automatically as on Mac.</li>
          <li><strong>No iPhone or iPad app yet.</strong> Android phones and tablets pair with Windows and Linux as they do with a Mac, through the <a href="https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion" target="_blank" rel="noopener">app on Google Play</a>, but the iPhone and iPad app isn't in the App Store yet.</li>
          <li><strong>A few features are Mac-only for now:</strong> Gmail in meeting briefs, Apple Intelligence, Granite Speech transcription, and Nemotron speaker separation.</li>
        </ul>
        <p>The full list is in <a href="https://github.com/stevyhacker/lokalbot/blob/master/LinuxWindows/README.md#what-works-where" target="_blank" rel="noopener">what works where</a>, and the <a href="/explainers/windows-linux-app.pdf">two-page overview</a> shows what changed.</p>
        <figure class="blog-figure">
          <img src="/assets/blog/windows-today.webp" width="1600" height="900" alt="LokalBot on Windows showing Today, with open actions and the day digest." loading="lazy" decoding="async" />
          <figcaption>Today on Windows, with fictional demo data.</figcaption>
        </figure>

        <h2>The models</h2>
        <ul>
          <li><strong>Transcription:</strong> Qwen3-ASR 0.6B through sherpa-onnx, with Parakeet v3 and v2, SenseVoice, GigaAM for Russian, and Whisper turbo as options.</li>
          <li><strong>Speaker separation:</strong> pyannote segmentation and TitaNet.</li>
          <li><strong>Notes and Ask:</strong> Qwen3.5 4B, the same as on Mac.</li>
          <li><strong>Search:</strong> EmbeddingGemma 2, the same as on Mac.</li>
          <li><strong>Autocomplete:</strong> LFM2.5 1.2B.</li>
        </ul>
        <p>The default download is about 4 GB. llama.cpp runs on a Vulkan GPU or the CPU, and since 0.11.3 you can choose <strong>CUDA (experimental)</strong> in Settings → Models → llama.cpp on a supported NVIDIA GPU. You can swap any model in Settings.</p>

        <h2>Install</h2>
        <ul>
          <li><strong>Windows 10 or 11, x64:</strong> run <code>LokalBot-&lt;version&gt;-windows-x86_64-setup.exe</code> from the <a href="https://github.com/stevyhacker/lokalbot/releases/latest" target="_blank" rel="noopener">latest release</a>. It installs for your user, without administrator rights. A portable zip is in the same release.</li>
          <li><strong>Linux x86_64:</strong> install the <code>.deb</code> (Debian, Ubuntu), the <code>.rpm</code> (Fedora, openSUSE), or the Arch package, or extract the <code>.tar.gz</code> and run <code>./install.sh</code>. Since 0.11.2 the <code>.deb</code>, and the <code>.rpm</code> on Fedora, add the LokalBot repository, so <code>sudo apt upgrade</code> or <code>sudo dnf upgrade</code> brings later versions.</li>
        </ul>
        <p>Linux needs glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40, or newer), PulseAudio or PipeWire, and a Vulkan or OpenGL driver. See the <a href="/system-requirements">system requirements</a>.</p>

        <h2>On Omarchy and other Hyprland desktops</h2>
        <p><a href="https://omarchy.org" target="_blank" rel="noopener">Omarchy</a> already has everything LokalBot uses on Wayland: <code>grim</code> for screen context, <code>wtype</code> and <code>wl-clipboard</code> for dictation, PipeWire for meeting audio, and the Hyprland desktop portal. Install the Arch package with <code>sudo pacman -U</code>, then bind LokalBot's commands in <code>~/.config/hypr/bindings.lua</code>. These keys are free in Omarchy's defaults:</p>
        <pre class="code" aria-label="Hyprland key bindings for LokalBot on Omarchy">o.bind(<span class="c-str">"SUPER + ALT + D"</span>, <span class="c-str">"LokalBot dictation"</span>, <span class="c-str">"lokalbot dictate"</span>)
o.bind(<span class="c-str">"SUPER + ALT + A"</span>, <span class="c-str">"Ask LokalBot"</span>, <span class="c-str">"lokalbot quick-recall"</span>)</pre>
        <p>The tray icon appears in Omarchy's bar, and the dictation pill and Quick Recall float instead of tiling.</p>
        <p>Omarchy runs Fcitx 5 for typing other languages, and a desktop runs one input method at a time, so autocomplete in other apps stays out of its way and Settings says so. If you don't use Fcitx 5, <code>systemctl --user disable --now omarchy-fcitx5.service</code> lets autocomplete start. This comes from reading Omarchy's repository; it hasn't been tried on Omarchy.</p>

        <h2>Tell us what breaks</h2>
        <p>Most testing so far has been on a handful of personal and rented machines, so reports from real hardware help the most. <a href="https://github.com/stevyhacker/lokalbot/issues/new/choose" target="_blank" rel="noopener">Open an issue</a> with your distribution, desktop, X11 or Wayland, CPU and GPU, and what you tried.</p>
        """,
    },
    {
        "slug": "porting-to-windows-and-linux-with-agents",
        "published": "2026-10-20",
        "title": "How the Windows and Linux Port Was Built with Coding Agents",
        "description": "The Windows and Linux app was ported from 150,000 lines of Swift to Rust in three days by coding agents. What made it work, how the result was checked, and a link to the full write-up.",
        "eyebrow": "Build notes",
        "h1": "How the Windows and Linux port was built",
        "lead": "The port began with one message sent from a phone on a Sunday morning and shipped as LokalBot 0.11.0 two days later. Here is the short version, with a link to the full write-up.",
        "read_time": "3 min read",
        "body": """
        <h2>A first attempt that only looked right</h2>
        <p>On October 2 a coding agent built a working Windows and Linux app with a native interface and CI on both platforms in one morning. It had its own data model and its own library on disk, so it couldn't open anything recorded on a Mac, and nothing would show when it drifted from how the Mac app behaves. That pull request was closed.</p>

        <h2>Specs before code</h2>
        <p>The second attempt spent its first hour on specs. Four agents read the Mac app's 150,000 lines of Swift without changing anything and wrote down the library format, the processing pipeline with every model prompt, every screen with its exact text, and the command-line tools and privacy rules. The core data types were written to match the Mac app's files, and every agent tested against a real library recorded by the Mac app. Six implementation agents then each took one part of the code.</p>

        <h2>How the work was checked</h2>
        <p>The port landed as one large pull request, so the checks mattered more than reading every line of the diff:</p>
        <ul>
          <li>CI runs the app on a virtual display on Linux and on Windows and takes a screenshot of every page.</li>
          <li>The live transcript is tested by playing a scripted conversation into virtual audio devices. That caught two bugs the unit tests had missed.</li>
          <li>Autocomplete is tested by typing into Notepad and checking that the suggestion appears after the cursor.</li>
          <li>End-to-end runs use the real models from an empty library: they download the models, process a short meeting, and ask a question about it.</li>
          <li>Meetings recorded on a Mac are played on Linux, with their timestamps required to line up exactly.</li>
          <li>Afterwards, the Mac and Windows/Linux apps were compared feature by feature, and the gaps were closed in five separate pull requests.</li>
        </ul>

        <h2>Read the full write-up</h2>
        <p>The full story, including the build machines, the rules for agents working side by side, and the decisions that were left to a person, is on Field Notes: <a href="https://bogosavljevic.me/blog/posts/porting-lokalbot-to-linux-and-windows/" target="_blank" rel="noopener">Porting LokalBot to Linux and Windows with agents</a>. The result is described in <a href="/blog/windows-and-linux-alpha">LokalBot is on Windows and Linux, in alpha</a>.</p>
        """,
    },
    {
        "slug": "autocomplete-that-knows-your-meetings",
        "published": "2026-10-13",
        "updated": "2026-11-19",
        "title": "Autocomplete That Knows Your Meetings, on Gemma 4 E2B",
        "description": "LokalBot's autocomplete runs Gemma 4 E2B base at about 50 ms a suggestion on an M4 Max and can bring in facts from your own meeting notes. How it compares with Cotypist and Cotabby.",
        "eyebrow": "Autocomplete",
        "h1": "Autocomplete that knows your meetings",
        "lead": "LokalBot suggests the rest of what you are typing in almost any Mac app, with a small model running on your Mac. When your draft names something from a recent meeting, it can bring in what was said there.",
        "read_time": "4 min read",
        "body": """
        <figure class="blog-figure">
          <img src="/assets/blog/autocomplete-memory.gif" width="1650" height="258" alt="Typing an update in TextEdit after a call with John: after “the Harbor beta ships”, autocomplete suggests “Thursday morning, after the accessibility review.” and Tab accepts it word by word." loading="lazy" decoding="async" />
          <figcaption>A suggestion that comes from a meeting earlier that day. Tab accepts it word by word.</figcaption>
        </figure>

        <h2>Fast enough to stay out of the way</h2>
        <p>Getting autocomplete to be useful without being intrusive or laggy took a lot of experiments with different models and quantizations. The best balance of suggestion quality and latency on a regular MacBook turned out to be the Gemma 4 E2B base model at 6-bit (Q6_K), running in-process through llama.cpp. On an M4 Max a suggestion takes a median of 56 ms while typing (see the <a href="/blog/local-autocomplete-56ms-benchmark">full engine benchmark</a>).</p>
        <p><strong>Update, November 19, 2026 — first suggestion after a pause:</strong> Cotypist highlights staying fast when you resume typing after a break. Previously, once llama.cpp's 180-second Metal residency keep-alive lapsed, LokalBot's first suggestion after a 5-minute pause took 95–130 ms. LokalBot now warms the loaded runtime with a single throwaway token on screen wake, unlock, click, or the first keystroke—removing that token afterward so the cached prompt stays intact—cutting a 5-minute pause down to <strong>49–53 ms</strong> against a <strong>47–49 ms</strong> warm reference (<a href="https://github.com/stevyhacker/lokalbot/blob/master/Benchmarks/autocomplete/Cotyping/results/2026-11-18-first-after-pause/REPORT.md" target="_blank" rel="noopener">benchmark report</a>; 30-minute pauses under heavy memory pressure remain unmeasured).</p>

        <h2>Context from your own work</h2>
        <ul>
          <li><strong>The text above the field.</strong> On by default, read through macOS accessibility. Private browser windows are never read.</li>
          <li><strong>Your meetings, if you opt in.</strong> When your draft names something distinctive, LokalBot can add up to two facts from your own meeting notes to the model's context.</li>
        </ul>
        <p>Autocomplete lives in the same app as meetings, dictation, and screen recall, which share one memory budget for their models.</p>

        <h2>How it compares</h2>
        <p>Cotypist and Cotabby are the closest local-first alternatives. As described on their sites (checked October 13, 2026; LokalBot column updated November 19, 2026):</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">Cotypist, Cotabby, and LokalBot autocomplete compared</caption>
            <thead>
              <tr><th scope="col">Feature</th><th scope="col">Cotypist</th><th scope="col">Cotabby</th><th scope="col">LokalBot</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">License and price</th><td>Proprietary; free for 100 words a day, paid for unlimited</td><td>AGPL-3.0, free (beta)</td><td>GPLv3, free, no limits</td></tr>
              <tr><th scope="row">Platforms</th><td>macOS</td><td>macOS</td><td>macOS (Swift), Windows &amp; Linux (Rust + GPUI)</td></tr>
              <tr><th scope="row">Model</th><td>Local (Gemma 4 E4B recommended)</td><td>Local GGUF through llama.cpp, or Apple Intelligence</td><td>Gemma 4 E2B base Q6_K (Balanced) or LFM2.5 1.2B (Lightweight), in-process llama.cpp</td></tr>
              <tr><th scope="row">First suggestion after a 5-min pause</th><td>Advertised fast resume</td><td>Not published</td><td>49–53 ms on M4 Max (warm-up on wake, click, or key)</td></tr>
              <tr><th scope="row">Knows what was said in your meetings</th><td>No</td><td>No</td><td>Yes, opt-in</td></tr>
              <tr><th scope="row">Text above the field</th><td>Not documented on its site</td><td>OCR of the window</td><td>Accessibility text, never from private windows</td></tr>
              <tr><th scope="row">Also in the app</th><td>Autocomplete only</td><td>Emoji, macros, autocorrect</td><td>Meetings, dictation, screen recall, read-only MCP</td></tr>
            </tbody>
          </table>
        </div>
        <p>A head-to-head with Cotabby used identical inputs and the same Gemma 4 E2B weights over 782 next-word checkpoints. LokalBot predicted the exact next word 32.7% of the time (256 of 782) and Cotabby 30.7% (240 of 782), a difference of 2.0 points with a 95% interval of 0.0 to 4.0. In other words, the two are comparable on accuracy; the work now is on the experience around the suggestions.</p>

        <h2>Try it</h2>
        <p>Turn on Autocomplete in <strong>Settings → Writing</strong>. It needs the Accessibility and Input Monitoring permissions and a one-time model download. Tab accepts a word. Password fields and apps you exclude are never read.</p>
        """,
    },
    {
        "slug": "raycast-extension",
        "published": "2026-10-02",
        "title": "Search Your Meetings from Raycast",
        "description": "The LokalBot Raycast extension finds every meeting where a word came up, in titles, summaries, or transcripts, without opening the app. It only reads your local library.",
        "eyebrow": "Integration",
        "h1": "Search your meetings from Raycast",
        "lead": "Finding out what was said in a meeting shouldn't mean opening another app. The LokalBot extension, now in the Raycast Store, searches your meetings from Raycast.",
        "read_time": "2 min read",
        "body": """
        <figure class="blog-figure">
          <img src="/assets/blog/raycast-quick-recall.webp" width="1600" height="1000" alt="Raycast's Quick Recall command listing meetings that mention onboarding, each match labeled title, summary, or transcript." loading="lazy" decoding="async" />
          <figcaption>Quick Recall in Raycast, with fictional demo data.</figcaption>
        </figure>

        <h2>Two commands</h2>
        <ul>
          <li><strong>Quick Recall.</strong> Type a word and see every meeting where it came up, from titles, summaries, or the transcript itself. Enter reveals the meeting's files in Finder and ⌘Enter copies the matching snippet.</li>
          <li><strong>Recent Meetings.</strong> Lists your last 20 meetings.</li>
        </ul>

        <h2>Local, like the app</h2>
        <p>The extension makes no network requests. It reads your local LokalBot library, and only after you allow external agents to read your meeting library in LokalBot's privacy settings.</p>
        <p>It needs the LokalBot app installed, which on Mac means Apple Silicon and macOS 15 or later.</p>

        <h2>Install</h2>
        <p>Get <a href="https://www.raycast.com/stevan_bogosavljevic/lokalbot" target="_blank" rel="noopener">LokalBot in the Raycast Store</a>. It's the first LokalBot extension for Raycast, so <a href="https://github.com/stevyhacker/lokalbot/issues/new/choose" target="_blank" rel="noopener">tell us</a> what's missing or annoying.</p>
        """,
    },
    {
        "slug": "five-local-models-6-8-gb",
        "published": "2026-09-30",
        "updated": "2026-10-26",
        "title": "Five Local Models, 6.8 GB of Weights: LokalBot 0.9.2's Model Stack",
        "description": "Since July every model in LokalBot was benchmarked and most defaults swapped for smaller ones. In 0.9.2 the whole stack is 6.8 GB, with faster notes, better speaker labels, and quicker autocomplete.",
        "eyebrow": "Models",
        "h1": "Five local models, 6.8 GB of weights",
        "lead": "Since LokalBot launched in July, every model in it has been benchmarked, and most defaults were swapped for smaller ones. In 0.9.2 the whole stack is 6.8 GB.",
        "read_time": "3 min read",
        "body": """
        <p class="blog-note"><strong>Update, October 2026:</strong> two defaults have changed since this post. Search now uses EmbeddingGemma 2, and autocomplete uses Gemma 4 E2B; see <a href="/blog/autocomplete-that-knows-your-meetings">Autocomplete that knows your meetings</a>. Current numbers are on the <a href="/benchmarks">benchmarks page</a>.</p>

        <h2>The stack in 0.9.2</h2>
        <ul>
          <li><strong>Transcription:</strong> Qwen3-ASR 1.7B, MLX 8-bit.</li>
          <li><strong>Who spoke when:</strong> Nemotron 3, Core ML.</li>
          <li><strong>Notes and action items:</strong> Qwen3.5 4B, Q4_K_M in llama.cpp.</li>
          <li><strong>Search embeddings:</strong> Harrier 0.6B, Q8_0.</li>
          <li><strong>Autocomplete in any app:</strong> LFM2.5 1.2B, Q4_K_M.</li>
          <li><strong>Screen text:</strong> Apple Vision OCR, opt-in.</li>
        </ul>

        <h2>What changed, in numbers</h2>
        <p>Measured on an M4 Max with 48 GB of memory:</p>
        <ul>
          <li>A 26-minute meeting goes to finished notes in 33 seconds with the model already loaded, decoding at about 85 tokens a second.</li>
          <li>Speaker error dropped from 43.4% to 14.6% diarization error rate on the AMI corpus. That's against the previous pyannote setup, so it says more about that configuration than about pyannote.</li>
          <li>Autocomplete latency at the 95th percentile fell from 1.83 s with Gemma 4 E4B to 0.49 s.</li>
        </ul>

        <h2>A model that didn't make it</h2>
        <p>MiniCPM5 2B was tested for notes. It was smaller and faster, but it got stuck repeating itself on one summary and assigned action items to the wrong person. Qwen3.5 4B stayed the default: saving a few seconds isn't worth getting wrong who agreed to do what.</p>

        <h2>Also in the app</h2>
        <p>A read-only MCP server and CLI, off by default, let Claude Code or any other MCP client pull context from your meetings.</p>
        <p>There are no numbers yet from 16 GB Macs or other M-series chips. If you run LokalBot on one, especially an M5 or M6, <a href="https://github.com/stevyhacker/lokalbot/issues/new/choose" target="_blank" rel="noopener">share what you get</a>. The <a href="https://github.com/stevyhacker/lokalbot/releases/tag/v0.9.2" target="_blank" rel="noopener">0.9.2 release notes</a> have the rest.</p>
        """,
    },
    {
        "slug": "a-workday-on-local-models",
        "published": "2026-07-21",
        "updated": "2026-10-26",
        "title": "A Whole Workday on Local Models: LokalBot 0.5",
        "description": "LokalBot 0.5 adds Dreaming, which turns a finished day into a morning brief, plus faster autocomplete and answers right in Quick Recall. What the app does, and the models behind it.",
        "eyebrow": "Release",
        "h1": "A whole workday on local models",
        "lead": "LokalBot now does the job of three or four subscription apps (a meeting notetaker, dictation, autocomplete, and a memory of your day) on your own hardware, with no subscription and no API keys.",
        "read_time": "3 min read",
        "body": """
        <p class="blog-note"><strong>Update, October 2026:</strong> several default models have changed since this post; the current ones are on the <a href="/benchmarks">benchmarks page</a>.</p>

        <h2>What it does</h2>
        <ul>
          <li><strong>Meetings.</strong> Detects Zoom, Teams, Meet, and other calls and records you and the other side on two synchronized tracks, with no bot joining the call. Transcription and the summary run on your Mac as soon as the meeting ends.</li>
          <li><strong>Dictation.</strong> Hold ⌥ Space, talk, and release. It's transcribed locally and pasted at the cursor, and the audio is deleted afterwards.</li>
          <li><strong>Autocomplete.</strong> Ghost-text suggestions in almost any Mac text field; Tab accepts. Opt-in.</li>
          <li><strong>Recall.</strong> Ask “what did we decide about this?” and get the answer from your own library, with the source meeting cited and the exact moment ready to replay. Full-text and semantic search cover everything.</li>
          <li><strong>Day timeline.</strong> An optional private timeline of where your time went, with a daily digest.</li>
        </ul>

        <h2>New in 0.5</h2>
        <ul>
          <li><strong>Dreaming.</strong> LokalBot can compile a finished day overnight into a morning brief and structured work memory.</li>
          <li><strong>Faster autocomplete.</strong> New installs get the 0.73 GB LFM2.5 1.2B model, and accepting suggestions is more reliable across native apps, Chromium, and input methods.</li>
          <li><strong>Answers in Quick Recall.</strong> Quick Recall can answer right in its compact window instead of always opening the full Ask view.</li>
          <li><strong>Scheduled day digests</strong>, with a prompt you can customize.</li>
        </ul>

        <h2>The models in daily use</h2>
        <p>One setup, on a 48 GB M4 Max, all through the bundled llama.cpp with full Metal offload:</p>
        <div class="guide-table-wrap">
          <table class="guide-table">
            <caption class="visually-hidden">Models in daily use</caption>
            <thead>
              <tr><th scope="col">Job</th><th scope="col">Model</th><th scope="col">Quantization</th><th scope="col">Size</th><th scope="col">Speed</th></tr>
            </thead>
            <tbody>
              <tr><th scope="row">Transcription</th><td>Granite Speech 4.1 2B</td><td>Q4_K_M + F16 projector</td><td>2.3 GB</td><td>Faster than real time</td></tr>
              <tr><th scope="row">Summaries and chat</th><td>Qwen3.5 4B</td><td>Q4_K_M</td><td>2.7 GB</td><td>About 100 tokens/s</td></tr>
              <tr><th scope="row">Autocomplete</th><td>Gemma 4 E4B</td><td>UD-Q5_K_XL</td><td>6.7 GB</td><td>About 78 tokens/s</td></tr>
              <tr><th scope="row">Embeddings</th><td>Qwen3-Embedding 0.6B</td><td>Q8_0</td><td>0.6 GB</td><td>—</td></tr>
              <tr><th scope="row">Diarization</th><td>pyannote community-1</td><td>Core ML</td><td>0.1 GB</td><td>—</td></tr>
            </tbody>
          </table>
        </div>
        <p>The full list of changes is in the <a href="https://github.com/stevyhacker/lokalbot/releases/tag/v0.5.0" target="_blank" rel="noopener">0.5.0 release notes</a>.</p>
        """,
    },
    {
        "slug": "introducing-lokalbot",
        "published": "2026-07-01",
        "updated": "2026-10-26",
        "title": "Introducing LokalBot: Meetings, Autocomplete, and Day Tracking on Your Mac",
        "description": "LokalBot is a free, open-source Mac app that records and summarizes meetings, autocompletes your typing in any app, and tracks where your day went, with every model running on your Mac.",
        "eyebrow": "Launch",
        "h1": "Introducing LokalBot",
        "lead": "LokalBot records and summarizes your meetings, autocompletes your typing in any app, and keeps track of where your day went. Every model runs on your Mac: no cloud, no account, and no API keys.",
        "read_time": "3 min read",
        "body": """
        <p class="blog-note"><strong>Update, October 2026:</strong> this is the original announcement. The default models have changed since (see <a href="/blog/five-local-models-6-8-gb">Five local models, 6.8 GB of weights</a>), the app now checks for updates (see the <a href="/privacy">privacy policy</a> for every network use), and LokalBot also runs on <a href="/blog/windows-and-linux-alpha">Windows and Linux</a>.</p>

        <h2>One app instead of several</h2>
        <p>Recording meetings, autocompleting text, and keeping track of the day usually means several separate apps, each with its own subscription and its own cloud. LokalBot does all of it in one Mac app, with no third-party inference cost. It's free and open source under the GPLv3.</p>

        <h2>The model stack</h2>
        <ul>
          <li><strong>Summaries, chat, and autocomplete</strong> run on a bundled llama.cpp: in-process for autocomplete's low latency, llama-server otherwise. Any of them can point at your own GGUF file, Ollama, an OpenAI-compatible endpoint, or Apple Intelligence.</li>
          <li><strong>Transcription</strong> uses Granite Speech 4.1, Parakeet, Whisper, or Qwen3-ASR through Core ML and MLX on Apple Silicon. Parakeet runs at about 190 times real time.</li>
          <li><strong>Semantic search</strong> uses Qwen3-Embedding 0.6B on a second llama-server, with vectors in SQLite and brute-force cosine similarity. At personal scale, brute force is instant, and it adds no dependencies.</li>
          <li><strong>Speaker separation</strong> is optional: pyannote, through FluidAudio, splits the other side of a call into individual speakers.</li>
          <li><strong>An in-app Hugging Face browser</strong> searches and downloads GGUF models, with a note on whether each one fits your Mac.</li>
        </ul>

        <h2>Launch defaults</h2>
        <ul>
          <li><strong>Transcription:</strong> IBM Granite Speech 4.1 2B, Q4.</li>
          <li><strong>Summaries:</strong> Qwen 3.6 35B-A3B, Q4_K_M.</li>
          <li><strong>Autocomplete:</strong> Gemma 4 E4B, Q5 XL.</li>
        </ul>
        <p>These run well on an M4 Max with 48 GB of memory. With 16 to 24 GB, choose one of the lighter alternatives in the app's model settings.</p>

        <h2>Private by design</h2>
        <p>After the one-time model download, LokalBot works offline. Optional screenshots are sealed with AES-GCM and deleted automatically. LokalBot needs an Apple Silicon Mac with macOS 15 or later.</p>
        <p>Get it from <a href="https://github.com/stevyhacker/lokalbot" target="_blank" rel="noopener">GitHub</a>, and join the <a href="https://www.reddit.com/r/LocalLLaMA/comments/1ukhpnl/lokalbot_fully_local_macos_app_meetings/" target="_blank" rel="noopener">launch discussion on r/LocalLLaMA</a>, especially if you have better local speech or small, fast autocomplete models to suggest.</p>
        """,
    },
]
