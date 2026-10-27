---
name: Bug report
about: Report a reproducible LokalBot bug
title: "[Bug] "
labels: bug
assignees: ""
---

## Category

Check all that apply:

- [ ] Recording / Audio capture (mic or system audio not captured, wrong source)
- [ ] Transcription (missing, garbled, or wrong-language text)
- [ ] Summaries / Ask / LLM (bad or empty output, model or server errors)
- [ ] Day memory / Screen context
- [ ] Dictation / Autocomplete
- [ ] Permissions (macOS permissions, or Linux desktop support)
- [ ] Install / Updates
- [ ] Performance / Crash (slow processing, hang, or crash)

## Summary

Describe the bug in one or two sentences.

## Environment

- LokalBot version:
- Platform: macOS / Windows (alpha) / Linux (alpha)
- OS version (on Linux: distribution, desktop, and X11 or Wayland):
- Mac model, or PC CPU and GPU:
- RAM:
- Installed with: DMG / Homebrew / Windows zip / Linux archive and install.sh / built from source
- Audio source: microphone / system audio / both
- Transcription model:
- Think (summaries) model: built-in / Ollama / OpenAI-compatible server / ChatGPT or Claude plan / Apple Intelligence
- macOS only, permissions granted: Microphone / Screen Recording / Accessibility

## Steps to reproduce

1.
2.
3.

## Expected behavior

Describe what you expected LokalBot to do.

## Actual behavior

Describe what happened instead.

## Notes

Add screenshots or relevant lines from LokalBot's log here if useful, without
meeting content, API keys, or other private material. On a Mac the log is
`~/Library/Application Support/me.dotenv.LokalBot/debug.log`; on Windows and
Linux it's in the library's `logs` folder (Settings → Advanced → Logs).
