# LokalBot

LokalBot is a local-first work-memory app for macOS, with a Windows and Linux
app in alpha. It captures conversations,
turns them into useful memory, and helps people retrieve or act on that memory
without making remote data sharing the default.

## Language

**Work Memory**

The durable, searchable record LokalBot builds from meetings, transcripts,
notes, outcomes, and related context.

_Avoid_: knowledge base, second brain

**Day Digest**

An evidence-backed daily journal assembled from a person's Work Memory. It
should reflect what happened that day rather than inventing a generic recap.

_Avoid_: daily summary, daily recap

**Model Role**

A distinct responsibility in LokalBot's on-device intelligence stack. A role
has one selected engine and one understandable lifecycle, even when several
features use it.

_Avoid_: model slot, model tier

**Transcribe**

The Model Role that turns recorded speech into timestamped text and speaker
evidence.

_Avoid_: speech model, STT slot

**Think**

The Model Role that turns Work Memory into summaries, answers, outcomes,
briefs, drafts, and agent responses. It stays on-device by default; using a
remote engine requires explicit approval.

_Avoid_: summarizer, main LLM slot

**Autocomplete**

The Model Role that offers short, immediate continuations while a person is
writing. It is optimized for responsiveness rather than deeper synthesis.

_Avoid_: small LLM, fast model slot
