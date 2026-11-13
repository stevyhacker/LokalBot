# On-disk layout

Part of the [development guide](../../DEVELOPMENT.md).

```
~/Library/Application Support/me.dotenv.LokalBot/
├── meetings/YYYY/MM/dd-slug/   # mic.m4a, system.m4a, meta.json, transcript.{json,md}, summary.md
├── journal/YYYY-MM-DD.md       # day digests
├── chats/<uuid>.json.enc       # saved Ask conversations (AES-GCM, chat-key)
├── dreams/ · memory/           # overnight reviews and Dream work memory (memory.json)
├── memory/personal-model.json.enc  # Personal Context claims (AES-GCM, chat-key)
├── email/                      # connected mail: accounts.json.enc, <account-id>/threads/*.json.enc (AES-GCM, email-key)
├── activity/YYYY-MM-DD/shots/  # <epoch>.heic.enc  (AES-GCM sealed)
├── companion/companion.sqlite  # records shared with paired phones and tablets, their public keys (only while sharing is on)
├── models/                     # downloaded GGUFs
├── qwen3-asr-models/           # downloaded Qwen3-ASR MLX weights
└── lokalbotv3.sqlite           # FTS5 (docs) + embeddings + activity_blocks + ocr_fts + screenshots + coding_agent_bursts
```

Rooted at the bundle id (not "LokalBot") so it never collides with another app's `Application Support/LokalBot` on the default case-insensitive filesystem.

Legacy migration never replaces an existing current database, including an empty one. A missing database is imported through a WAL-aware SQLite snapshot and atomic no-replace installation; concurrent creation wins safely. Conflicting legacy data and recovery snapshots remain available for explicit reconciliation. Dev, UI-test, and fixture launches skip legacy migration.
