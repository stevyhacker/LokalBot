# Simplified Chinese README screenshots

These two frames illustrate Mandarin support in [README.zh-CN.md](../../../README.zh-CN.md).
They were captured on **October 17, 2026** in light appearance.

| File | Surface |
| --- | --- |
| [meetings-summary.png](meetings-summary.png) | "Harbor 2.0 发布评审" with its Mandarin recap and action items, beside two other Mandarin meetings |
| [meetings-transcript.png](meetings-transcript.png) | The same meeting's transcript, with timestamps and speaker labels |

Unlike the [English set](../README.md), these frames show real model output. The
meetings are fictional, but their transcripts, recaps, and action items were
produced by LokalBot's own pipeline on this Mac and were not edited.

## How they were made

1. **Script and voices.** Three short Mandarin meetings were written for this
   capture and voiced with ElevenLabs `eleven_v4` using library voices (Yating
   Lin, Arthur, Linda, and Willow). Each line was placed on a microphone track
   ("You") or a system-audio track (the other participants), 0.9 s after the
   previous line, the way `say_track` in `Scripts/seed_demo_library.py` builds
   its tracks.
2. **Processing.** Each meeting folder (`mic.m4a`, `system.m4a`, `meta.json`)
   was processed with `--process <meeting-folder>` in a temporary library
   (`LOKALBOT_STORAGE_ROOT`) with a fresh UserDefaults suite, so every setting
   was a fresh-install default: Qwen3-ASR 1.7B (MLX 8-bit) with automatic
   language detection, Nemotron 3 speaker separation, and Qwen3.5 4B for notes.
   The model files were APFS clones of already-downloaded models. Nothing was
   sent off the Mac except the voice synthesis requests.
3. **Rendering.** The LokalBot UI Test Host rendered each frame in-process with
   the per-frame settings from `Scripts/capture-screenshots.sh`
   (`LOKALBOT_INITIAL_SECTION=meetings`, `LOKALBOT_SELECT_INDEX=0`,
   `LOKALBOT_DETAIL_TAB=summary` or `transcript`), against the processed
   library instead of a seeded one. Windows were 1400 × 880 points at 2×
   (2800 × 1760 PNG), with the `en_US` locale: the interface is English until
   the Simplified Chinese translation ships.

The host was a Debug build of 0.10.9 (build 53) made on October 17, 2026. Its
transcription, notes, and meeting views match the 0.10.10 release. The build
carried three filming hooks that activate only when `LOKALBOT_RECORD_DIRECTORY`
or `LOKALBOT_GEMMA_FILMING` is set; neither was set. No production app, user
library, or UI test was involved.

## What the frames show as-is

- Speakers are unnamed ("Speaker 1", "Speaker 2"), as in any recording before
  its voices are named. The "3 speakers need names" banner is the app's own
  prompt; speaker separation found one more voice than the meeting had.
- At 00:00:35 in the transcript, the first character of a turn ("回" from
  "回归测试") is attributed to "Other speaker". In auto-detect mode,
  `TranscriptLanguageVote` counts whitespace-separated words, so Chinese
  segments cast no vote, no language is detected, and word-level speaker
  attribution falls back to speaker regions.
- Spoken version numbers come out as words ("二点零", "二点零一点一"); the notes
  normalize them ("2.0.1").

## Featured meeting script

What was said in "Harbor 2.0 发布评审", for comparison with the transcript.
"Me" is the microphone track; 老陈 and 王静 are on the system track.

| Speaker | Line |
| --- | --- |
| Me | 好，人齐了，我们开始吧。今天主要过一下 Harbor 2.0 的发布：崩溃修复、App Store 审核、发布时间，还有 beta 用户的反馈。老陈，你先说说崩溃的情况？ |
| 老陈 | 好。上周那个导入照片时闪退的问题已经修好了，是 iOS 26 上相册权限回调的问题。修复已经合进主分支了，在 TestFlight 的 214 版本里。 |
| 老陈 | 从这两天的数据看，崩溃率从百分之一点二降到了零点一左右。 |
| Me | 太好了。王静，测试这边呢？ |
| 王静 | 回归测试我们在三台设备上都跑完了，主要流程都没问题。还剩一个小 bug：深色模式下，设置页面有几行字对比度太低，看不太清。 |
| 王静 | 我觉得这个不影响发布，可以放到 2.0.1 再修。 |
| Me | 同意，深色模式的问题放到 2.0.1。老陈，审核什么时候能提交？ |
| 老陈 | 下周一上午就可以提交。按最近的经验，审核一般一到两天。 |
| Me | 那我们把发布日期定在下周四，十月二十三号。如果审核卡住了，就顺延到再下周一。大家觉得可以吗？ |
| 王静 | 可以。 |
| 老陈 | 没问题。 |
| Me | 好。王静，beta 用户那边有什么反馈？ |
| 王静 | 这一轮一共三十七个测试用户。呼声最高的是导出成 Markdown，好几个人说想把笔记放进 Obsidian。另外也有人觉得同步有点慢。 |
| Me | Markdown 导出挺重要的，但这次来不及了，放到 2.1。老陈，你下周三之前评估一下工作量，好吗？ |
| 老陈 | 行，我周三前给你一个估算。同步慢的问题，我也顺便看一下日志。 |
| Me | 好。发布说明要中英文两个版本，王静你来写初稿？ |
| 王静 | 没问题，我周二之前发到群里。 |
| Me | 那我负责 App Store 的截图，还有公众号和小红书的发布文案，周三之前准备好。 |
| 王静 | 对了，订阅价格要不要调？之前说年费从六十八涨到九十八。 |
| Me | 这个先不定，下周拿到 beta 的留存数据以后再讨论。 |
| Me | 好，我总结一下：下周一提交审核，下周四发布；深色模式的 bug 放到 2.0.1；Markdown 导出放到 2.1。谢谢大家。 |

| File | Dimensions | SHA-256 |
| --- | --- | --- |
| meetings-summary.png | 2800 × 1760 | `d1bccdca2acea42ed7044e6c3a96308a15ec2f994f757797964978a231b1745f` |
| meetings-transcript.png | 2800 × 1760 | `6a37f4987c6e9b2ad3aac4451be3b2f2414fc8f2a0bb1635b0223e6f22bf235d` |
