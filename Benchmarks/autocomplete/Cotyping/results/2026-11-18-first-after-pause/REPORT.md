# First suggestion after a pause, 2026-11-18

Cotypist advertises being faster when you start typing after a break. On
2026-10-06 LokalBot's first suggestion after a 30-minute pause took 1,907 ms of
model time against 62 ms while typing. These runs measure the same thing on the
current runtime, before and after the warm-up in this change.

## Setup

- Gemma 4 E2B i1 Q6_K, as an APFS clone that the installed app does not map.
- `LlamaCotypingRuntime.forAutocomplete()` (2 threads), bundled llama.cpp
  v1.0.0 (b12359), Release build with testability.
- MacBook Pro M4 Max, 48 GB, macOS 27.2.1.
- `CotypingTypingLatencyBenchmarkTests/testFirstSuggestionAfterIdle`. After a
  short typing burst and the pause, it times one keystroke, "…design team has
  time", which suggests " to review the numbers.". Then it times the same
  request again as the warm reference. Times are model time, from asking for
  the suggestion to having it.
- Each run waited for a quiet Mac first: 1-minute load under 6 and no other
  process above 60% CPU, twice 30 s apart. Load was logged every 10 s during
  the run, and no run below went over 8.6.
- One sample per cell, two at 300 s. Differences under about 10 ms are noise.

## Results

First suggestion after the pause, in ms. The warm reference is the same
request repeated at once.

| Pause | Before | After, warm-up at the key | After, warm-up just before | Warm reference |
| --- | ---: | ---: | ---: | ---: |
| 0 s | 47 | – | – | 47 |
| 20 s | 61 | 51 | 47 | 46–50 |
| 60 s | 59 | 48 | 50 | 48–50 |
| 300 s | 130, 95 | 50, 53 | 49 | 47–49 |
| 1800 s | unmeasured (1,907 on 2026-10-06, older llama.cpp) | unmeasured | unmeasured | 62 on 2026-10-06 |

In the app, whichever comes first warms the model: a click, a key in any app,
the screen waking or an unlock shortly before typing ("just before"), or the
first key itself ("at the key"). For "at the key", the touch starts when the key
lands and the suggestion is asked for 45 ms later. That is about the app's wait
for the field to update plus its 20 ms debounce, so the touch fits inside a wait
that already exists.

The touch took 21 ms after a 20 s pause, 19 ms after 60 s and 46 ms after
300 s. Without the warm-up, the first suggestion paid that time itself.

Other ways to keep the model warm, at 300 s:

| Variant | First | Warm reference |
| --- | ---: | ---: |
| A touch every 60 s during the pause, as while the person uses other apps | 59 | 47 |
| llama.cpp keep-alive raised to 3600 s, no touch | 62 | 48 |

Both hold the weights resident (wired memory stayed 2–3 GB higher than without
them). Both still leave the GPU clocked down, which costs 10–15 ms, like a 20 s
or 60 s pause. In the app, the key adds its own touch in that case. Raising
the keep-alive would also keep the weights wired while the person is away, so
it was not chosen. A first keep-alive run was disturbed: the warm reference
also took 132 ms. It is kept as `keepalive3600-disturbed.txt`.

## What makes a pause slow

- **Under three minutes:** the GPU clocks down within seconds. This costs
  10–15 ms on the first suggestion.
- **After three minutes:** llama.cpp's residency keep-alive lapses (180 s after
  the last decode, `GGML_METAL_RESIDENCY_KEEP_ALIVE_S`). The system's wired
  memory then fell by about 3.4 GB (13.3 → 9.9 GB, 12.8 → 9.3 GB), and the next
  decode has to wire the weights again. This costs 50–80 ms on the first
  suggestion.
- **Longer pauses on a busy Mac:** the model file's pages are paged or
  compressed. On a quiet Mac the file stayed 99–100% in memory after 300 s. In
  a discarded run, other work used about 28 GB of compressed memory, and half
  the file was out of memory after 60 s. This is the likely cost of the 1.9 s
  measured after 30 minutes.

## Not measured

- **The 30-minute pause.** It was not run, because the run heats the laptop.
  The fix has not been shown to remove the 1.9 s measured on 2026-10-06. A touch
  that starts at the first key only has the app's wait before the suggestion,
  about 45 ms. If paging makes the touch itself take most of the 1.9 s, only a
  click, a wake or an unlock some time before typing would hide it. Measuring
  it needs a Mac other than this laptop.
- **Removing the touch's token, undone.** No real-model run checked that the
  new position assertion in `testTouchKeepsTheCachedPromptAndTheSuggestion`
  fails without the `seq_rm`.

`llama_decode` only queues the GPU work. A first version of the touch did not
wait for it, so it returned in 2 ms, and the first suggestion waited for the
touch's GPU work instead of finding it done: 98 ms after 300 s against 130 ms
without it. The touch now calls `llama_synchronize`. Those runs were discarded,
as were runs during another session's model server at 500% CPU.

## Cost

- **Memory:** while the person keeps typing or clicking anywhere, touches renew
  the keep-alive, so the model's roughly 3.4 GB stays wired. Before, it stayed
  wired only for three minutes after the last suggestion. It is released three
  minutes after the person stops using the Mac. The memory-pressure policy is
  unchanged: a warning frees the model after a minute without a suggestion
  (touches do not count), critical pressure frees it at once, and a touch never
  loads a model again.
- **Energy:** at most one touch every 30 s, only while the person uses the Mac
  without typing. There are none while typing, because the suggestions keep the
  model warm, and none while the person is away. Over a 300 s pause, four
  touches added 18 mJ of CPU energy to the process (468 against 450 mJ). The
  process's GPU energy is not reported on this Mac (`task_gpu_utilisation` reads
  0). One warm token is about 6.5 ms of GPU time (2026-10-04), so a touch every
  30 s keeps the GPU busy well under 0.1% of the time. The process's CPU use
  during an untouched pause, about 1.5 mW, was already there. llama.cpp's
  residency thread wakes every 5 ms for as long as the Metal device exists
  (`ggml-metal-device.m`), which is the likely source. It was not measured on
  its own.

## Files

- `before-none.txt`, `before-none-300s-second.txt`: no warm-up.
- `after-ahead.txt`: touch finished just before the key.
- `after-key.txt`, `after-key-300s-second.txt`: touch started at the key.
- `after-every60.txt`: a touch every 60 s during the pause.
- `keepalive3600.txt`, `keepalive3600-disturbed.txt`: keep-alive raised, no
  touch.
