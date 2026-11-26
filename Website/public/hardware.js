(() => {
  'use strict';

  const SITE = 'https://www.lokalbot.com';

  const MODELS = {
    stt: [
      {
        id: 'qwen3-asr-1.7b',
        name: 'Qwen3-ASR 1.7B (LokalBot v3)',
        format: 'GGUF Q8_0 (llama.cpp)',
        platforms: ['mac'],
        diskGb: { mac: 2.52 },
        activeGb: { mac: 3.27 },
        minRamGb: 16,
        tier: 'balanced',
        metric: '9.79% AMI ihm · 100% clean silence · 31.7x RT',
        benchHash: 'stt-lokalbot-v3',
        note: 'v0.14.0 Apache-2.0 fine-tune default on Mac (2.52 GB GGUF Q8_0 + mmproj). 0 silence hallucinations, -24.3 pp code-switch WER, 52 languages.'
      },
      {
        id: 'qwen3-asr-0.6b',
        name: 'Qwen3-ASR 0.6B (LokalBot v1)',
        format: 'GGUF Q8_0 / sherpa-onnx',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 1.02, windows: 0.88, linux: 0.88 },
        activeGb: { mac: 1.77, windows: 1.45, linux: 1.45 },
        minRamGb: 8,
        tier: 'lightweight',
        metric: '10.72% AMI ihm · -21.7 pp Slavic WER · 52.7x RT',
        benchHash: 'stt-lokalbot-v3',
        note: 'v0.14.0 Apache-2.0 compact fine-tune on 8 GB Macs (1.02 GB GGUF Q8_0) and default compact tier on Windows/Linux.'
      },
      {
        id: 'parakeet-v3',
        name: 'Parakeet TDT 0.6B v3',
        format: 'Core ML / sherpa-onnx',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.60, windows: 0.49, linux: 0.49 },
        activeGb: { mac: 0.90, windows: 0.80, linux: 0.80 },
        minRamGb: 8,
        tier: 'lightweight',
        metric: '~190x RT · 25 European langs',
        benchHash: 'stt-small-engines',
        note: 'Fastest multilingual option on Apple Neural Engine and CPU; auto language detection.'
      },
      {
        id: 'parakeet-v2',
        name: 'Parakeet TDT 0.6B v2',
        format: 'Core ML / sherpa-onnx',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.46, windows: 0.48, linux: 0.48 },
        activeGb: { mac: 0.75, windows: 0.78, linux: 0.78 },
        minRamGb: 8,
        tier: 'lightweight',
        metric: 'English-only · fast ANE',
        benchHash: 'stt-small-engines',
        note: 'Smallest English-only transcription option with strong recall and word timings.'
      },
      {
        id: 'whisper-turbo',
        name: 'Whisper large-v3 turbo',
        format: 'Core ML / sherpa-onnx',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 1.60, windows: 0.56, linux: 0.56 },
        activeGb: { mac: 2.10, windows: 1.10, linux: 1.10 },
        minRamGb: 8,
        tier: 'balanced',
        metric: '~100 languages',
        benchHash: 'stt-small-engines',
        note: 'Broadest language coverage when meetings fall outside Qwen3-ASR or Parakeet languages.'
      }
    ],
    diar: [
      {
        id: 'nemotron-3',
        name: 'Nemotron 3 Sortformer',
        format: 'Core ML (FluidAudio)',
        platforms: ['mac'],
        diskGb: { mac: 0.20 },
        activeGb: { mac: 0.67 },
        minRamGb: 8,
        tier: 'balanced',
        metric: '14.56% DER · 500x RT (M4 Max)',
        benchHash: 'diarization-ami',
        note: 'Default Mac speaker separation on AMI (0.67 GiB peak RSS); loads on demand after recording stops.'
      },
      {
        id: 'pyannote-titanet',
        name: 'pyannote 3.0 + TitaNet',
        format: 'sherpa-onnx',
        platforms: ['windows', 'linux'],
        diskGb: { windows: 0.08, linux: 0.08 },
        activeGb: { windows: 0.25, linux: 0.25 },
        minRamGb: 8,
        tier: 'balanced',
        metric: 'On-demand ONNX diarization',
        benchHash: 'diarization-ami',
        note: 'Default speaker separation on Windows and Linux (alpha).'
      }
    ],
    llm: [
      {
        id: 'qwen3.5-0.8b',
        name: 'Qwen3.5 0.8B',
        format: 'GGUF Q4_K_M',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.53, windows: 0.53, linux: 0.53 },
        activeGb: { mac: 1.80, windows: 1.80, linux: 1.80 },
        fullKvGb: 3.53,
        minRamGb: 8,
        tier: 'lightweight',
        metric: '0.53 GB weights · short meetings',
        benchHash: 'summaries-mac-extraction',
        note: 'Compact built-in fallback for 8 GB Macs and lightweight laptops.'
      },
      {
        id: 'qwen3.5-2b',
        name: 'Qwen3.5 2B',
        format: 'GGUF Q4_K_M',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 1.28, windows: 1.28, linux: 1.28 },
        activeGb: { mac: 2.80, windows: 2.80, linux: 2.80 },
        fullKvGb: 4.28,
        minRamGb: 8,
        tier: 'lightweight',
        metric: '1.28 GB weights · multilingual',
        benchHash: 'summaries-mac-extraction',
        note: 'Compact multilingual option that leaves generous headroom on 8-16 GB machines.'
      },
      {
        id: 'qwen3.5-4b',
        name: 'Qwen3.5 4B (LokalBot v4)',
        format: 'GGUF Q4_K_M (32K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 2.74, windows: 2.74, linux: 2.74 },
        activeGb: { mac: 5.74, windows: 5.74, linux: 5.74 },
        fullKvGb: 5.74,
        minRamGb: 16,
        tier: 'balanced',
        metric: '118/120 memory · 1.78x faster · 6/6 tools',
        benchHash: 'summaries-lokalbot-v4',
        note: 'v0.14.0 Apache-2.0 fine-tuned default Think model. 60.6% fewer validator rejections, 45% Blind21 decisions, 6/6 native tool calls.'
      },
      {
        id: 'lfm2.5-8b-a1b',
        name: 'LFM2.5 8B-A1B (MoE)',
        format: 'GGUF Q4_K_M (32K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 5.16, windows: 5.16, linux: 5.16 },
        activeGb: { mac: 8.16, windows: 8.16, linux: 8.16 },
        fullKvGb: 8.16,
        minRamGb: 16,
        tier: 'balanced',
        metric: '~1B active MoE · fast summaries',
        benchHash: 'summaries-mac-extraction',
        note: 'Sparse MoE option for fast long-meeting summaries on 16-24 GB machines.'
      },
      {
        id: 'gemma4-12b',
        name: 'Gemma 4 12B',
        format: 'GGUF Q4_K_M (32K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 7.12, windows: 7.12, linux: 7.12 },
        activeGb: { mac: 10.12, windows: 10.12, linux: 10.12 },
        fullKvGb: 10.12,
        minRamGb: 24,
        tier: 'quality',
        metric: '7.12 GB weights · 24 GB+ class',
        benchHash: 'summaries-mac-extraction',
        note: 'Stronger 12B dense option for 24 GB Macs and 12-16 GB VRAM GPUs.'
      },
      {
        id: 'qwen3.6-27b',
        name: 'Qwen3.6 27B',
        format: 'GGUF Q4_K_M (32K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 16.82, windows: 16.82, linux: 16.82 },
        activeGb: { mac: 19.82, windows: 19.82, linux: 19.82 },
        fullKvGb: 19.82,
        minRamGb: 48,
        tier: 'quality',
        metric: '16.82 GB dense · 32-48 GB+ Macs',
        benchHash: 'summaries-mac-extraction',
        note: 'Maximum-quality dense summaries; best on 48 GB+ Macs or 24 GB+ VRAM GPUs.'
      },
      {
        id: 'qwen3.6-35b-a3b',
        name: 'Qwen3.6 35B-A3B (MoE)',
        format: 'GGUF UD-IQ4_XS (32K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 17.73, windows: 17.73, linux: 17.73 },
        activeGb: { mac: 20.73, windows: 20.73, linux: 20.73 },
        fullKvGb: 20.73,
        minRamGb: 48,
        tier: 'quality',
        metric: '~3B active MoE · top long-meeting tier',
        benchHash: 'summaries-mac-extraction',
        note: 'Highest-quality long-meeting catalog model (~3B active params); targets 32-48 GB+ Macs.'
      }
    ],
    auto: [
      {
        id: 'lfm2.5-1.2b',
        name: 'LFM2.5 1.2B Instruct',
        format: 'GGUF Q4_K_M (4K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.73, windows: 0.73, linux: 0.73 },
        activeGb: { mac: 1.48, windows: 1.48, linux: 1.48 },
        minRamGb: 8,
        tier: 'lightweight',
        metric: '26 ms median · Lightweight preset',
        benchHash: 'autocomplete-engine',
        note: 'Ultra-fast English-first autocomplete under 1 GB. Best choice for 8 GB machines.'
      },
      {
        id: 'qwen3.5-2b-auto',
        name: 'Qwen3.5 2B',
        format: 'GGUF Q4_K_M (4K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 1.28, windows: 1.28, linux: 1.28 },
        activeGb: { mac: 2.03, windows: 2.03, linux: 2.03 },
        minRamGb: 8,
        tier: 'lightweight',
        metric: '1.28 GB weights · multilingual',
        benchHash: 'autocomplete-engine',
        note: 'Lightweight multilingual inline completion option for 8-16 GB machines.'
      },
      {
        id: 'gemma4-e2b-q6',
        name: 'Gemma 4 E2B (LokalBot v4)',
        format: 'GGUF i1-Q6_K (4K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 3.85, windows: 3.85, linux: 3.85 },
        activeGb: { mac: 4.60, windows: 4.60, linux: 4.60 },
        minRamGb: 16,
        tier: 'balanced',
        metric: '56/56 memory+visible · 52.2% prec · 20.2 ms',
        benchHash: 'autocomplete-lokalbot-v4',
        note: 'v0.14.0 Apache-2.0 fine-tuned default autocomplete on 16 GB+ machines. 100% grounding across 7 suites, 80.0% email precision, 0 unsafe.'
      },
      {
        id: 'gemma4-e4b-q5',
        name: 'Gemma 4 E4B',
        format: 'GGUF UD-Q5_K_XL (4K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 6.66, windows: 6.66, linux: 6.66 },
        activeGb: { mac: 7.41, windows: 7.41, linux: 7.41 },
        minRamGb: 24,
        tier: 'quality',
        metric: '6.66 GB · higher capacity',
        benchHash: 'autocomplete-engine',
        note: 'Higher-capacity cotyping choice for 24-48 GB+ systems.'
      }
    ],
    search: [
      {
        id: 'embeddinggemma-2',
        name: 'EmbeddingGemma 2',
        format: 'GGUF Q8_0 (2K ctx)',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.31, windows: 0.31, linux: 0.31 },
        activeGb: { mac: 0.50, windows: 0.50, linux: 0.50 },
        minRamGb: 8,
        tier: 'balanced',
        metric: '39 ms p50 · 0.280 R@1 · 496 MB server peak',
        benchHash: 'retrieval-qmsum',
        note: 'Shared SQLite FTS5 + vector search embedder powering instant search and MCP/CLI retrieval.'
      }
    ],
    files: [
      {
        id: 'embeddinggemma-2-mmproj',
        name: 'EmbeddingGemma 2 Multimodal Projector',
        format: 'GGUF Q8_0 mmproj',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.55, windows: 0.55, linux: 0.55 },
        activeGb: { mac: 0.60, windows: 0.60, linux: 0.60 },
        minRamGb: 8,
        tier: 'balanced',
        metric: 'Image & audio file search',
        benchHash: 'retrieval-embeddings',
        note: 'Optional projector loaded alongside EmbeddingGemma 2 when indexing local images and audio.'
      }
    ],
    tts: [
      {
        id: 'kokoro-82m',
        name: 'Kokoro 82M',
        format: 'Core ML / sherpa-onnx',
        platforms: ['mac', 'windows', 'linux'],
        diskGb: { mac: 0.10, windows: 0.10, linux: 0.10 },
        activeGb: { mac: 0.81, windows: 0.81, linux: 0.81 },
        minRamGb: 8,
        tier: 'balanced',
        metric: '0.333x RTF · 0.81 GiB peak RAM (M4 Max)',
        benchHash: 'tts-voice',
        note: 'Optional on-demand voice playback for daily briefs and meeting recaps.'
      }
    ]
  };

  const ROLE_META = [
    { key: 'stt', label: 'Transcription', residency: 'On demand', description: 'Loads during/after meetings, unloads idle.' },
    { key: 'diar', label: 'Speaker diarization', residency: 'On demand', description: 'Runs post-meeting to separate speakers.' },
    { key: 'llm', label: 'Summaries & memory', residency: 'Main LLM (32K)', description: 'Generates notes, actions, digests & Q&A.' },
    { key: 'search', label: 'Search & agent memory', residency: 'Warm resident', description: 'Always ready for hybrid search & MCP/CLI.' },
    { key: 'auto', label: 'Live autocomplete', residency: 'Warm resident', description: 'Inline keystroke completion across apps.' },
    { key: 'files', label: 'Multimodal file search', residency: 'On demand', description: 'Indexes local images and audio files.' },
    { key: 'tts', label: 'Spoken summaries', residency: 'On demand', description: 'Reads briefs and recaps aloud locally.' }
  ];

  const PRESETS = [
    { id: 'mac-8', label: 'MacBook Air · 8 GB', os: 'mac', chip: 'm2', ramGb: 8, vramGb: 0, profile: 'auto' },
    { id: 'mac-16', label: 'MacBook Pro · 16 GB', os: 'mac', chip: 'm3', ramGb: 16, vramGb: 0, profile: 'auto' },
    { id: 'mac-24', label: 'Mac · 24 GB', os: 'mac', chip: 'm4', ramGb: 24, vramGb: 0, profile: 'auto' },
    { id: 'mac-48', label: 'Mac Pro/Studio · 48 GB', os: 'mac', chip: 'm4-max', ramGb: 48, vramGb: 0, profile: 'quality' },
    { id: 'win-gpu', label: 'Windows · 16 GB + 8 GB GPU', os: 'windows', chip: 'x64', ramGb: 16, vramGb: 8, profile: 'auto' },
    { id: 'linux-cpu', label: 'Linux · 32 GB CPU-only', os: 'linux', chip: 'x64', ramGb: 32, vramGb: 0, profile: 'auto' }
  ];

  const CHIP_NOTES = {
    'm1': 'Apple M1 (unified memory, Core ML + Metal). Real-world speed is slower than our M4 Max benchmark runs, especially on 12B+ models; M1 speeds have not been benchmarked yet.',
    'm2': 'Apple M2 (unified memory, Core ML + Metal). Handles the default or lightweight stack smoothly; M2 speeds have not been benchmarked yet.',
    'm3': 'Apple M3 (unified memory, Core ML + Metal). Solid memory bandwidth for 16-24 GB stacks; M3 speeds have not been benchmarked yet.',
    'm4': 'Apple M4 / M4 Pro (unified memory, Core ML + Metal). High memory bandwidth for resident autocomplete + summarizer.',
    'm4-max': 'Apple M4 Max (our primary benchmark machine: 48 GB unified memory). Speed badges below match this hardware directly.',
    'm5': 'Apple M5 family (unified memory, Core ML + Metal). Expected faster than M4-class chips; community M5 benchmark runs welcome on GitHub.',
    'x64': 'x86_64 desktop/laptop (Windows 10/11 or Linux with glibc 2.39+, alpha). Bundled llama.cpp runs on Vulkan/CUDA GPU or falls back to CPU.'
  };

  function modelsForPlatform(role, os) {
    return (MODELS[role] || []).filter((m) => m.platforms.includes(os));
  }

  function findModel(role, id, os) {
    const avail = modelsForPlatform(role, os);
    return avail.find((m) => m.id === id) || avail[0] || null;
  }

  function recommendSelections(config) {
    const { os, ramGb, vramGb = 0, profile = 'auto' } = config;
    const effectiveProfile = profile === 'auto'
      ? (ramGb <= 8 ? 'lightweight' : (ramGb >= 36 && (os === 'mac' || vramGb >= 16) ? 'quality' : 'balanced'))
      : profile;

    const picks = {};

    if (os === 'mac') {
      if (effectiveProfile === 'lightweight') {
        picks.stt = 'qwen3-asr-0.6b';
      } else {
        picks.stt = 'qwen3-asr-1.7b';
      }
    } else {
      picks.stt = 'qwen3-asr-0.6b';
    }

    picks.diar = os === 'mac' ? 'nemotron-3' : 'pyannote-titanet';

    if (effectiveProfile === 'lightweight') {
      picks.llm = ramGb <= 8 ? 'qwen3.5-0.8b' : 'qwen3.5-2b';
    } else if (effectiveProfile === 'quality') {
      if (ramGb >= 48 && (os === 'mac' || vramGb >= 24)) {
        picks.llm = 'qwen3.6-35b-a3b';
      } else if (ramGb >= 24 && (os === 'mac' || vramGb >= 12)) {
        picks.llm = 'gemma4-12b';
      } else {
        picks.llm = 'qwen3.5-4b';
      }
    } else {
      picks.llm = ramGb <= 8 ? 'qwen3.5-0.8b' : 'qwen3.5-4b';
    }

    if (effectiveProfile === 'lightweight' || ramGb <= 8) {
      picks.auto = 'lfm2.5-1.2b';
    } else if (effectiveProfile === 'quality' && ramGb >= 32 && (os === 'mac' || vramGb >= 12)) {
      picks.auto = 'gemma4-e2b-q6';
    } else if (os !== 'mac' && vramGb > 0 && vramGb < 6) {
      picks.auto = 'lfm2.5-1.2b';
    } else {
      picks.auto = 'gemma4-e2b-q6';
    }

    picks.search = 'embeddinggemma-2';
    picks.files = 'embeddinggemma-2-mmproj';
    picks.tts = 'kokoro-82m';
    return { picks, effectiveProfile };
  }

  function round1(n) {
    return Math.round(n * 10) / 10;
  }

  function round2(n) {
    return Math.round(n * 100) / 100;
  }

  function evaluateStack(config) {
    const os = config.os || 'mac';
    const ramGb = Number(config.ramGb) || 16;
    const vramGb = os === 'mac' ? 0 : Math.max(0, Number(config.vramGb) || 0);
    const profile = config.profile || 'auto';
    const workloads = Object.assign(
      { stt: true, diar: true, llm: true, search: true, auto: true, files: false, tts: false },
      config.workloads || {}
    );

    const { picks: recommended, effectiveProfile } = recommendSelections({ os, ramGb, vramGb, profile });
    const overrides = config.overrides || {};

    const budgetGb = round1(ramGb / 2);
    const rows = [];
    let diskTotalGb = 0;

    let warmGb = 0;
    let captureBurstGb = 0;
    let llmBurstGb = 0;
    let optionalBurstGb = 0;
    let largestSingleGb = 0;
    let largestSingleName = '';

    for (const role of ROLE_META) {
      if (!workloads[role.key]) continue;
      const chosenId = overrides[role.key] || recommended[role.key];
      const model = findModel(role.key, chosenId, os);
      if (!model) continue;

      const disk = model.diskGb[os] ?? Object.values(model.diskGb)[0];
      const active = model.activeGb[os] ?? Object.values(model.activeGb)[0];
      diskTotalGb += disk;

      if (role.key === 'auto' || role.key === 'search') {
        warmGb += active;
      } else if (role.key === 'stt' || role.key === 'diar') {
        captureBurstGb += active;
      } else if (role.key === 'llm') {
        llmBurstGb = active;
      } else {
        optionalBurstGb = Math.max(optionalBurstGb, active);
      }

      if (active > largestSingleGb) {
        largestSingleGb = active;
        largestSingleName = model.name;
      }

      rows.push({
        roleKey: role.key,
        roleLabel: role.label,
        residency: role.residency,
        model,
        diskGb: round2(disk),
        activeGb: round2(active),
        availableModels: modelsForPlatform(role.key, os)
      });
    }

    const peakOnDemandGb = Math.max(captureBurstGb, llmBurstGb, optionalBurstGb);
    const allWarmPeakGb = round2(warmGb + peakOnDemandGb);
    const lruManagedPeakGb = round2(Math.min(allWarmPeakGb, Math.max(warmGb, peakOnDemandGb)));
    const criticalPeakGb = round2(Math.max(largestSingleGb, peakOnDemandGb));

    let status;
    let headline;
    let detail;

    if (rows.length === 0) {
      status = 'comfortable';
      headline = 'Select at least one workload to estimate memory';
      detail = 'Toggle meeting transcription, summaries, hybrid search, or autocomplete above to calculate disk and RAM requirements.';
    } else if (allWarmPeakGb <= budgetGb) {
      status = 'comfortable';
      headline = 'Fits comfortably: all selected models stay warm';
      detail = `Peak simultaneous RAM (${allWarmPeakGb.toFixed(1)} GB) stays inside LokalBot's ${budgetGb.toFixed(0)} GB residency cap (50% of your ${ramGb} GB RAM), leaving at least half of system memory free for your OS, browser, and call apps.`;
    } else if (criticalPeakGb <= budgetGb && warmGb <= budgetGb) {
      status = 'lru';
      headline = 'Fits smoothly with automatic LRU model swapping';
      detail = `Your warm models (${warmGb.toFixed(1)} GB) and largest burst (${peakOnDemandGb.toFixed(1)} GB) each fit inside the ${budgetGb.toFixed(0)} GB cap, though stacking both reaches ${allWarmPeakGb.toFixed(1)} GB. LokalBot's ModelResidency governor automatically evicts idle models while a summary runs, then reloads them on demand.`;
    } else if (criticalPeakGb <= ramGb * 0.72) {
      status = 'tight';
      headline = `Tight for ${ramGb} GB: exceeds LokalBot's ${budgetGb.toFixed(0)} GB safety cap`;
      detail = `${largestSingleName || 'Your active stack'} peaks around ${criticalPeakGb.toFixed(1)} GB, above the default 50% RAM cap (${budgetGb.toFixed(0)} GB). It may run solo with other apps closed, or switch to the Lightweight preset for smooth day-long use.`;
    } else {
      status = 'exceeds';
      headline = `Too large for ${ramGb} GB RAM: pick a smaller model`;
      detail = `${largestSingleName || 'The selected model'} needs ~${criticalPeakGb.toFixed(1)} GB active memory, which will heavily swap or fail on ${ramGb} GB RAM. Switch to a compact model or apply the recommended profile.`;
    }

    let gpuSummary = null;
    if (os !== 'mac') {
      const largestGguf = Math.max(
        ...rows.filter((r) => ['llm', 'auto', 'search'].includes(r.roleKey)).map((r) => r.activeGb),
        0
      );
      if (vramGb === 0) {
        gpuSummary = {
          mode: 'cpu',
          label: 'CPU-only llama.cpp',
          note: 'Bundled llama.cpp runs cleanly on x86_64 CPU. On an AMD Ryzen 7 9700X (8 threads), Qwen3.5 4B finished short extraction in 2.86 s and a long-meeting stress test in 120 s (6/6 tool calls); use LFM2.5 1.2B for snappier CPU autocomplete.'
        };
      } else if (largestGguf <= vramGb * 0.88) {
        gpuSummary = {
          mode: 'full-vram',
          label: `Full GPU offload (${vramGb} GB VRAM)`,
          note: `Your largest GGUF workload (~${largestGguf.toFixed(1)} GB) fits cleanly inside ${vramGb} GB VRAM via Vulkan/CUDA with headroom for display buffers.`
        };
      } else if (largestGguf <= vramGb * 1.45) {
        gpuSummary = {
          mode: 'partial-vram',
          label: `Partial GPU + RAM offload (${vramGb} GB VRAM)`,
          note: `Your largest GGUF workload (~${largestGguf.toFixed(1)} GB) exceeds ${vramGb} GB VRAM; llama.cpp splits layers across GPU and system RAM. Pick a smaller summarizer or lightweight autocomplete to stay 100% on GPU.`
        };
      } else {
        gpuSummary = {
          mode: 'spill-vram',
          label: `Mostly CPU/RAM (${vramGb} GB VRAM too small)`,
          note: `~${largestGguf.toFixed(1)} GB is much larger than ${vramGb} GB VRAM. Expect CPU-bound generation speeds unless you step down to Qwen3.5 4B or 2B.`
        };
      }
    }

    return {
      os,
      ramGb,
      vramGb,
      profile,
      effectiveProfile,
      budgetGb,
      diskTotalGb: round2(diskTotalGb),
      warmGb: round2(warmGb),
      captureBurstGb: round2(captureBurstGb),
      llmBurstGb: round2(llmBurstGb),
      peakOnDemandGb: round2(peakOnDemandGb),
      allWarmPeakGb,
      lruManagedPeakGb,
      criticalPeakGb,
      status,
      headline,
      detail,
      gpuSummary,
      rows
    };
  }

  function serializeState(state) {
    const p = new URLSearchParams();
    p.set('os', state.os);
    if (state.os === 'mac') p.set('chip', state.chip);
    p.set('ram', String(state.ramGb));
    if (state.os !== 'mac') p.set('vram', String(state.vramGb));
    if (state.profile && state.profile !== 'auto') p.set('profile', state.profile);
    const activeW = ROLE_META.map((r) => r.key).filter((k) => state.workloads[k]);
    p.set('w', activeW.join(','));
    const ov = Object.entries(state.overrides || {}).filter(([, v]) => Boolean(v));
    if (ov.length) {
      p.set('m', ov.map(([k, v]) => `${k}:${v}`).join(','));
    }
    return p.toString();
  }

  function parseState(searchStr) {
    const p = new URLSearchParams(searchStr || '');
    const os = ['mac', 'windows', 'linux'].includes(p.get('os')) ? p.get('os') : 'mac';
    const ram = Number(p.get('ram'));
    const ramGb = [8, 16, 24, 32, 36, 48, 64, 96, 128].includes(ram) ? ram : 16;
    const vram = Number(p.get('vram'));
    const vramGb = os === 'mac' ? 0 : ([0, 4, 6, 8, 12, 16, 24, 32].includes(vram) ? vram : (os === 'windows' ? 8 : 0));
    const chip = os === 'mac'
      ? (Object.prototype.hasOwnProperty.call(CHIP_NOTES, p.get('chip')) && p.get('chip') !== 'x64' ? p.get('chip') : 'm3')
      : 'x64';
    const profile = ['auto', 'lightweight', 'balanced', 'quality'].includes(p.get('profile')) ? p.get('profile') : 'auto';
    const workloads = { stt: true, diar: true, llm: true, search: true, auto: true, files: false, tts: false };
    if (p.has('w')) {
      const set = new Set((p.get('w') || '').split(',').filter(Boolean));
      for (const r of ROLE_META) workloads[r.key] = set.has(r.key);
    }
    const overrides = {};
    if (p.get('m')) {
      for (const pair of p.get('m').split(',')) {
        const [k, v] = pair.split(':');
        if (k && v && MODELS[k]) overrides[k] = v;
      }
    }
    return { os, chip, ramGb, vramGb, profile, workloads, overrides };
  }

  function formatMachineLabel(state) {
    return state.os === 'mac'
      ? `Apple Silicon Mac (${state.chip.toUpperCase()}, ${state.ramGb} GB unified memory)`
      : `${state.os === 'windows' ? 'Windows x64' : 'Linux x86_64'} (${state.ramGb} GB RAM, ${state.vramGb > 0 ? `${state.vramGb} GB VRAM` : 'CPU-only'})`;
  }

  function buildMarkdownReport(state, result) {
    const osLabel = formatMachineLabel(state);
    const lines = [
      `### LokalBot Local AI Stack Estimate: ${osLabel}`,
      '',
      `- **Verdict:** ${result.headline}`,
      `- **50% RAM residency cap:** ${result.budgetGb.toFixed(0)} GB (of ${state.ramGb} GB physical RAM)`,
      `- **Total disk download:** ${result.diskTotalGb.toFixed(1)} GB`,
      `- **Warm resident RAM:** ${result.warmGb.toFixed(1)} GB · **Peak combined:** ${result.allWarmPeakGb.toFixed(1)} GB`,
      '',
      '| Role | Model | Disk | Active RAM | Residency | Benchmark reference |',
      '| --- | --- | ---: | ---: | --- | --- |'
    ];
    for (const r of result.rows) {
      lines.push(
        `| ${r.roleLabel} | ${r.model.name} (${r.model.format}) | ${r.diskGb.toFixed(2)} GB | ${r.activeGb.toFixed(2)} GB | ${r.residency} | ${r.model.metric} |`
      );
    }
    lines.push('');
    lines.push(`Interactive link: ${SITE}/hardware?${serializeState(state)}`);
    lines.push(`Reproducible benchmarks: ${SITE}/benchmarks`);
    return lines.join('\n');
  }

  function buildStackCardSpec(state, result) {
    return {
      machine: formatMachineLabel(state),
      status: result.status,
      headline: result.headline,
      diskDisplay: `${result.diskTotalGb.toFixed(1)} GB`,
      warmDisplay: `${result.warmGb.toFixed(1)} GB`,
      peakDisplay: `${result.allWarmPeakGb.toFixed(1)} GB`,
      capDisplay: `${result.budgetGb.toFixed(0)} / ${result.ramGb} GB`,
      rows: result.rows.map((r) => ({
        role: r.roleLabel,
        model: r.model.name,
        disk: `${r.diskGb.toFixed(2)} GB`,
        active: `${r.activeGb.toFixed(2)} GB`
      })),
      footer: 'lokalbot.com/hardware',
      shareUrl: `${SITE}/hardware?${serializeState(state)}`
    };
  }

  function drawRoundedRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
  }

  function renderStackCardCanvas(state, result) {
    const spec = buildStackCardSpec(state, result);
    const width = 760;
    const rowH = 34;
    const height = 395 + Math.max(1, spec.rows.length) * rowH;
    const scale = 2;

    const canvas = document.createElement('canvas');
    canvas.width = width * scale;
    canvas.height = height * scale;
    const ctx = canvas.getContext('2d');
    ctx.scale(scale, scale);

    const grad = ctx.createLinearGradient(0, 0, width, height);
    grad.addColorStop(0, '#080d14');
    grad.addColorStop(1, '#0f1c29');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, width, height);

    drawRoundedRect(ctx, 24, 24, width - 48, height - 48, 22);
    ctx.fillStyle = 'rgba(18, 28, 40, 0.94)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(110, 242, 220, 0.28)';
    ctx.lineWidth = 1.5;
    ctx.stroke();

    ctx.fillStyle = '#6ef2dc';
    ctx.font = '700 12px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText('LOKALBOT v0.14.0 · LOCAL AI STACK CARD', 48, 60);

    ctx.fillStyle = '#ecf3f7';
    ctx.font = '700 22px -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif';
    ctx.fillText(spec.machine, 48, 92);

    const statusColors = {
      comfortable: '#23c4ae',
      lru: '#60a5fa',
      tight: '#f5a623',
      exceeds: '#ef5a5a'
    };
    ctx.fillStyle = statusColors[spec.status] || '#23c4ae';
    ctx.font = '600 14px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(spec.headline, 48, 118);

    const kpis = [
      { label: 'DISK DOWNLOAD', val: spec.diskDisplay },
      { label: 'WARM RAM', val: spec.warmDisplay },
      { label: 'COMBINED PEAK', val: spec.peakDisplay },
      { label: '50% RAM CAP', val: spec.capDisplay }
    ];
    for (let i = 0; i < kpis.length; i++) {
      const bx = 48 + i * 168;
      drawRoundedRect(ctx, bx, 138, 156, 68, 12);
      ctx.fillStyle = 'rgba(22, 33, 46, 0.88)';
      ctx.fill();
      ctx.strokeStyle = 'rgba(150, 180, 200, 0.2)';
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = '#8ba2b0';
      ctx.font = '700 10px ui-monospace, SFMono-Regular, Menlo, monospace';
      ctx.fillText(kpis[i].label, bx + 12, 160);
      ctx.fillStyle = '#ecf3f7';
      ctx.font = '700 18px ui-monospace, SFMono-Regular, Menlo, monospace';
      ctx.fillText(kpis[i].val, bx + 12, 188);
    }

    const barX = 48;
    const barY = 228;
    const barW = width - 96;
    const barH = 16;
    const scaleMax = Math.max(result.ramGb, result.allWarmPeakGb * 1.08);
    const warmW = Math.min(barW, (result.warmGb / scaleMax) * barW);
    const burstW = Math.min(barW - warmW, (result.peakOnDemandGb / scaleMax) * barW);
    const capX = barX + Math.min(barW - 2, (result.budgetGb / scaleMax) * barW);

    drawRoundedRect(ctx, barX, barY, barW, barH, 8);
    ctx.fillStyle = '#16212e';
    ctx.fill();
    if (warmW > 0) {
      drawRoundedRect(ctx, barX, barY, Math.max(8, warmW), barH, 8);
      ctx.fillStyle = '#23c4ae';
      ctx.fill();
    }
    if (burstW > 0) {
      ctx.fillStyle = '#5a9cf8';
      ctx.fillRect(barX + warmW, barY, burstW, barH);
    }
    ctx.fillStyle = '#f5a623';
    ctx.fillRect(capX, barY - 4, 2, barH + 8);

    ctx.fillStyle = '#8ba2b0';
    ctx.font = '600 11px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(`Warm ${spec.warmDisplay} · Burst ${result.peakOnDemandGb.toFixed(1)} GB · Cap ${result.budgetGb.toFixed(0)} GB`, barX, barY + 34);

    let y = 294;
    ctx.fillStyle = '#8ba2b0';
    ctx.font = '700 11px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText('ROLE', 48, y);
    ctx.fillText('MODEL', 216, y);
    ctx.fillText('DISK', 540, y);
    ctx.fillText('ACTIVE RAM', 626, y);
    y += 12;
    ctx.strokeStyle = 'rgba(150, 180, 200, 0.2)';
    ctx.beginPath();
    ctx.moveTo(48, y);
    ctx.lineTo(width - 48, y);
    ctx.stroke();

    y += 24;
    for (const row of spec.rows) {
      ctx.fillStyle = '#a2b4c2';
      ctx.font = '600 13px -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif';
      ctx.fillText(row.role, 48, y);
      ctx.fillStyle = '#ecf3f7';
      ctx.font = '600 13px -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif';
      ctx.fillText(row.model, 216, y);
      ctx.fillStyle = '#a2b4c2';
      ctx.font = '600 13px ui-monospace, SFMono-Regular, Menlo, monospace';
      ctx.fillText(row.disk, 540, y);
      ctx.fillText(row.active, 626, y);
      y += rowH;
    }

    const footY = height - 42;
    ctx.fillStyle = '#6ef2dc';
    ctx.font = '700 13px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(spec.footer, 48, footY);
    const tag = '100% On-Device · Apache-2.0 Models · GPLv3';
    ctx.fillStyle = '#8ba2b0';
    ctx.font = '500 12px ui-monospace, SFMono-Regular, Menlo, monospace';
    ctx.fillText(tag, width - 48 - ctx.measureText(tag).width, footY);

    return canvas;
  }

  const api = {
    MODELS,
    ROLE_META,
    PRESETS,
    CHIP_NOTES,
    recommendSelections,
    evaluateStack,
    serializeState,
    parseState,
    buildMarkdownReport,
    buildStackCardSpec,
    renderStackCardCanvas
  };

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = api;
  }

  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return;
  }
  window.LokalBotHardware = api;

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function init() {
    const app = document.getElementById('hw-app');
    if (!app) return;

    let state = parseState(window.location.search);

    const presetWrap = document.getElementById('hw-presets');
    const osGroup = document.getElementById('hw-os');
    const chipRow = document.getElementById('hw-chip-row');
    const chipSelect = document.getElementById('hw-chip');
    const ramGroup = document.getElementById('hw-ram');
    const vramRow = document.getElementById('hw-vram-row');
    const vramGroup = document.getElementById('hw-vram');
    const profileGroup = document.getElementById('hw-profile');
    const workloadWrap = document.getElementById('hw-workloads');

    const verdictEl = document.getElementById('hw-verdict');
    const kpiDisk = document.getElementById('hw-kpi-disk');
    const kpiWarm = document.getElementById('hw-kpi-warm');
    const kpiPeak = document.getElementById('hw-kpi-peak');
    const kpiCap = document.getElementById('hw-kpi-cap');
    const meterWrap = document.getElementById('hw-meter');
    const gpuCallout = document.getElementById('hw-gpu-callout');
    const chipNoteEl = document.getElementById('hw-chip-note');
    const tableBody = document.getElementById('hw-stack-body');
    const resetBtn = document.getElementById('hw-reset-overrides');
    const copyLinkBtn = document.getElementById('hw-copy-link');
    const copyMdBtn = document.getElementById('hw-copy-md');
    const savePngBtn = document.getElementById('hw-save-png');
    const applyLightBtn = document.getElementById('hw-apply-light');

    const MAC_RAM_OPTIONS = [8, 16, 24, 32, 36, 48, 64, 96, 128];
    const PC_RAM_OPTIONS = [8, 16, 32, 64, 128];
    const VRAM_OPTIONS = [0, 4, 6, 8, 12, 16, 24, 32];

    function syncUrl() {
      const qs = serializeState(state);
      const next = `${window.location.pathname}?${qs}${window.location.hash || ''}`;
      if (window.location.search !== `?${qs}`) {
        window.history.replaceState(null, '', next);
      }
    }

    function renderPresets() {
      presetWrap.innerHTML = PRESETS.map((pr) => {
        const active =
          state.os === pr.os &&
          state.ramGb === pr.ramGb &&
          (pr.os === 'mac' ? true : state.vramGb === pr.vramGb) &&
          Object.keys(state.overrides).length === 0;
        return `<button type="button" class="hw-preset${active ? ' is-active' : ''}" data-preset="${pr.id}">${escapeHtml(pr.label)}</button>`;
      }).join('');
    }

    function renderSelectors() {
      osGroup.querySelectorAll('[data-os]').forEach((btn) => {
        const active = btn.getAttribute('data-os') === state.os;
        btn.classList.toggle('is-active', active);
        btn.setAttribute('aria-pressed', active ? 'true' : 'false');
      });

      const isMac = state.os === 'mac';
      chipRow.hidden = !isMac;
      vramRow.hidden = isMac;
      if (isMac) {
        chipSelect.value = state.chip;
      }

      const ramChoices = isMac ? MAC_RAM_OPTIONS : PC_RAM_OPTIONS;
      if (!ramChoices.includes(state.ramGb)) {
        state.ramGb = ramChoices.reduce((best, cur) =>
          Math.abs(cur - state.ramGb) < Math.abs(best - state.ramGb) ? cur : best, ramChoices[0]
        );
      }
      ramGroup.innerHTML = ramChoices.map((gb) => {
        const active = gb === state.ramGb;
        return `<button type="button" class="hw-pill${active ? ' is-active' : ''}" data-ram="${gb}" aria-pressed="${active}">${gb} GB</button>`;
      }).join('');

      if (!isMac) {
        vramGroup.innerHTML = VRAM_OPTIONS.map((gb) => {
          const active = gb === state.vramGb;
          const label = gb === 0 ? 'CPU only' : `${gb} GB`;
          return `<button type="button" class="hw-pill${active ? ' is-active' : ''}" data-vram="${gb}" aria-pressed="${active}">${label}</button>`;
        }).join('');
      }

      profileGroup.querySelectorAll('[data-profile]').forEach((btn) => {
        const active = btn.getAttribute('data-profile') === state.profile;
        btn.classList.toggle('is-active', active);
        btn.setAttribute('aria-pressed', active ? 'true' : 'false');
      });

      workloadWrap.innerHTML = ROLE_META.map((role) => {
        const checked = Boolean(state.workloads[role.key]);
        return `
          <label class="hw-toggle${checked ? ' is-checked' : ''}">
            <input type="checkbox" data-workload="${role.key}" ${checked ? 'checked' : ''} />
            <span class="hw-toggle__body">
              <strong>${escapeHtml(role.label)}</strong>
              <span>${escapeHtml(role.description)}</span>
            </span>
          </label>`;
      }).join('');
    }

    function renderResult() {
      const res = evaluateStack(state);

      verdictEl.className = `hw-verdict hw-verdict--${res.status}`;
      const badgeLabel = {
        comfortable: 'All-warm fit',
        lru: 'Fits via LRU swapping',
        tight: 'Tight: consider Lightweight',
        exceeds: 'Exceeds system RAM'
      }[res.status];

      verdictEl.querySelector('.hw-verdict__badge').textContent = badgeLabel;
      verdictEl.querySelector('.hw-verdict__title').textContent = res.headline;
      verdictEl.querySelector('.hw-verdict__detail').textContent = res.detail;
      applyLightBtn.hidden = !(res.status === 'tight' || res.status === 'exceeds');

      kpiDisk.textContent = `${res.diskTotalGb.toFixed(1)} GB`;
      kpiWarm.textContent = `${res.warmGb.toFixed(1)} GB`;
      kpiPeak.textContent = `${res.allWarmPeakGb.toFixed(1)} GB`;
      kpiCap.textContent = `${res.budgetGb.toFixed(0)} / ${res.ramGb} GB`;

      const scaleMax = Math.max(res.ramGb, res.allWarmPeakGb * 1.08);
      const warmPct = Math.min(100, (res.warmGb / scaleMax) * 100);
      const burstPct = Math.min(100 - warmPct, (res.peakOnDemandGb / scaleMax) * 100);
      const capPct = Math.min(98, (res.budgetGb / scaleMax) * 100);
      const ramEdgePct = Math.min(100, (res.ramGb / scaleMax) * 100);

      meterWrap.innerHTML = `
        <div class="hw-meter__head">
          <span><strong>Memory map</strong> (${res.ramGb} GB physical RAM)</span>
          <span class="hw-meter__legend">
            <span class="hw-dot hw-dot--warm"></span>Warm resident (${res.warmGb.toFixed(1)} GB)
            <span class="hw-dot hw-dot--burst"></span>On-demand burst (${res.peakOnDemandGb.toFixed(1)} GB)
            <span class="hw-dot hw-dot--cap"></span>50% residency cap (${res.budgetGb.toFixed(0)} GB)
          </span>
        </div>
        <div class="hw-meter__track" role="img" aria-label="Memory bar showing ${res.warmGb.toFixed(1)} GB warm resident and ${res.peakOnDemandGb.toFixed(1)} GB on-demand burst against a ${res.budgetGb.toFixed(0)} GB residency cap out of ${res.ramGb} GB total RAM">
          <div class="hw-meter__seg hw-meter__seg--warm" style="width:${warmPct.toFixed(2)}%"></div>
          <div class="hw-meter__seg hw-meter__seg--burst" style="width:${burstPct.toFixed(2)}%"></div>
          <div class="hw-meter__marker hw-meter__marker--cap" style="left:${capPct.toFixed(2)}%" title="50% residency cap (${res.budgetGb.toFixed(0)} GB)">
            <span>${res.budgetGb.toFixed(0)} GB cap</span>
          </div>
          ${ramEdgePct < 99.5 ? `<div class="hw-meter__marker hw-meter__marker--ram" style="left:${ramEdgePct.toFixed(2)}%"><span>${res.ramGb} GB RAM</span></div>` : ''}
        </div>
        <p class="hw-meter__foot">LokalBot's <code>ModelResidency</code> governor budgets half of physical RAM for local models so the other half stays free for macOS/OS, browsers, IDEs, and video calls. Transcription and diarization run sequentially before summarization, and idle models unload automatically if needed.</p>
      `;

      chipNoteEl.textContent = CHIP_NOTES[state.os === 'mac' ? state.chip : 'x64'] || '';
      if (res.gpuSummary) {
        gpuCallout.hidden = false;
        gpuCallout.className = `hw-gpu hw-gpu--${res.gpuSummary.mode}`;
        gpuCallout.innerHTML = `<strong>${escapeHtml(res.gpuSummary.label)}:</strong> ${escapeHtml(res.gpuSummary.note)}`;
      } else {
        gpuCallout.hidden = true;
      }

      const hasOverrides = Object.keys(state.overrides).length > 0;
      resetBtn.hidden = !hasOverrides;

      if (res.rows.length === 0) {
        tableBody.innerHTML = '<tr><td colspan="5" class="hw-empty">No workloads selected. Enable at least one feature above.</td></tr>';
      } else {
        tableBody.innerHTML = res.rows.map((r) => {
          const modelCell = r.availableModels.length > 1
            ? `<select class="hw-model-select" data-role="${r.roleKey}" aria-label="${escapeHtml(r.roleLabel)} model">
                ${r.availableModels.map((m) => `<option value="${m.id}" ${m.id === r.model.id ? 'selected' : ''}>${escapeHtml(m.name)} (${escapeHtml(m.format)})</option>`).join('')}
               </select>
               <span class="hw-model-note">${escapeHtml(r.model.note)}</span>`
            : `<strong class="hw-model-static">${escapeHtml(r.model.name)}</strong> <span class="hw-model-fmt">${escapeHtml(r.model.format)}</span>
               <span class="hw-model-note">${escapeHtml(r.model.note)}</span>`;
          const benchUrl = r.model.benchHash ? `/benchmarks#${r.model.benchHash}` : '/benchmarks';
          return `
            <tr>
              <td>
                <strong>${escapeHtml(r.roleLabel)}</strong>
                <span class="hw-res-tag hw-res-tag--${r.residency === 'Warm resident' ? 'warm' : 'demand'}">${escapeHtml(r.residency)}</span>
              </td>
              <td>${modelCell}</td>
              <td class="hw-num">${r.diskGb.toFixed(2)} GB</td>
              <td class="hw-num">${r.activeGb.toFixed(2)} GB</td>
              <td><a class="hw-bench-link" href="${benchUrl}">${escapeHtml(r.model.metric)}</a></td>
            </tr>`;
        }).join('');
      }

      renderPresets();
      syncUrl();
    }

    function renderAll() {
      renderSelectors();
      renderResult();
    }

    presetWrap.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-preset]');
      if (!btn) return;
      const preset = PRESETS.find((p) => p.id === btn.getAttribute('data-preset'));
      if (!preset) return;
      state.os = preset.os;
      state.chip = preset.chip;
      state.ramGb = preset.ramGb;
      state.vramGb = preset.vramGb;
      state.profile = preset.profile;
      state.overrides = {};
      renderAll();
    });

    osGroup.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-os]');
      if (!btn) return;
      const nextOs = btn.getAttribute('data-os');
      if (nextOs === state.os) return;
      state.os = nextOs;
      state.chip = nextOs === 'mac' ? 'm3' : 'x64';
      state.vramGb = nextOs === 'mac' ? 0 : (nextOs === 'windows' ? 8 : 0);
      state.overrides = {};
      renderAll();
    });

    chipSelect.addEventListener('change', () => {
      state.chip = chipSelect.value;
      renderResult();
    });

    ramGroup.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-ram]');
      if (!btn) return;
      state.ramGb = Number(btn.getAttribute('data-ram'));
      state.overrides = {};
      renderAll();
    });

    vramGroup.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-vram]');
      if (!btn) return;
      state.vramGb = Number(btn.getAttribute('data-vram'));
      state.overrides = {};
      renderAll();
    });

    profileGroup.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-profile]');
      if (!btn) return;
      state.profile = btn.getAttribute('data-profile');
      state.overrides = {};
      renderAll();
    });

    workloadWrap.addEventListener('change', (e) => {
      const input = e.target.closest('[data-workload]');
      if (!input) return;
      state.workloads[input.getAttribute('data-workload')] = input.checked;
      renderAll();
    });

    tableBody.addEventListener('change', (e) => {
      const sel = e.target.closest('.hw-model-select');
      if (!sel) return;
      const role = sel.getAttribute('data-role');
      state.overrides[role] = sel.value;
      renderResult();
    });

    resetBtn.addEventListener('click', () => {
      state.overrides = {};
      renderAll();
    });

    applyLightBtn.addEventListener('click', () => {
      state.profile = 'lightweight';
      state.overrides = {};
      renderAll();
    });

    function flashButton(btn, msg) {
      const orig = btn.innerHTML;
      btn.textContent = msg;
      setTimeout(() => { btn.innerHTML = orig; }, 1800);
    }

    copyLinkBtn.addEventListener('click', async () => {
      const url = `${SITE}/hardware?${serializeState(state)}`;
      try {
        await navigator.clipboard.writeText(url);
        flashButton(copyLinkBtn, 'Link copied');
      } catch {
        window.prompt('Copy this configuration URL:', url);
      }
    });

    copyMdBtn.addEventListener('click', async () => {
      const res = evaluateStack(state);
      const md = buildMarkdownReport(state, res);
      try {
        await navigator.clipboard.writeText(md);
        flashButton(copyMdBtn, 'Markdown copied');
      } catch {
        window.prompt('Copy Markdown summary:', md);
      }
    });

    if (savePngBtn) {
      savePngBtn.addEventListener('click', () => {
        const res = evaluateStack(state);
        const canvas = renderStackCardCanvas(state, res);
        canvas.toBlob((blob) => {
          if (!blob) return;
          const url = URL.createObjectURL(blob);
          const a = document.createElement('a');
          a.href = url;
          a.download = `lokalbot-stack-${state.os}-${state.ramGb}gb.png`;
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          window.setTimeout(() => { URL.revokeObjectURL(url); }, 1000);
        }, 'image/png');
      });
    }

    renderAll();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
