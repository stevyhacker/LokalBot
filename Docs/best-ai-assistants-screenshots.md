# Screenshots for the AI assistants comparison

The page at <https://www.lokalbot.com/best-open-source-ai-assistants> shows one screenshot per app, all taken by us. The content and facts live in `Scripts/assistant_roundup.py`; this file is how to retake the screenshots when an app's main window changes. Retaking is not part of every monthly re-check.

Rules:

- Use each app's latest release, its default settings, and the model it suggests on first run. Note any change from the defaults in "How we tested" on the page.
- Fictional prompts and documents only, and a different everyday topic for each app.
- Decline analytics prompts. Accepting an app's terms of use needs the maintainer's OK each time.
- Captures are 1440×900 at 2× and published as 1600×1000 WebP (`cwebp -q 84`) in `web/assets/compare/ai-assistants/`.

## Where they were taken

On 2026-11-09, on a Linux x86_64 machine with no GPU (8-core Ryzen 7 9700X, 64 GB), in a scratch folder with a throwaway `HOME` for each desktop app, and everything bound to `127.0.0.1`. Delete the folder, containers, volumes, and images afterwards.

### Ollama, Open WebUI, AnythingLLM (Docker)

```bash
docker network create shots
docker run -d --name shots-ollama --network shots -p 127.0.0.1:11535:11434 -v shots-ollama:/root/.ollama ollama/ollama
docker exec shots-ollama ollama pull qwen3.5:4b
docker run -d --name shots-openwebui --network shots -p 127.0.0.1:18080:8080 -e WEBUI_AUTH=False \
  -e OLLAMA_BASE_URL=http://shots-ollama:11434 -v shots-openwebui:/app/backend/data ghcr.io/open-webui/open-webui:main
docker run -d --name shots-anythingllm --network shots -p 127.0.0.1:13001:3001 --cap-add SYS_ADMIN \
  -e STORAGE_DIR=/app/server/storage -e DISABLE_TELEMETRY=true -e LLM_PROVIDER=ollama \
  -e OLLAMA_BASE_PATH=http://shots-ollama:11434 -e OLLAMA_MODEL_PREF=qwen3.5:4b -e OLLAMA_MODEL_TOKEN_LIMIT=8192 \
  -e EMBEDDING_ENGINE=native -e VECTOR_DB=lancedb -v shots-anythingllm:/app/server/storage mintplexlabs/anythingllm
```

- Drive the two web apps with Playwright (`viewport 1440×900`, `deviceScaleFactor: 2`, light scheme).
- Run one app's chat at a time. Both share one CPU-bound Ollama, and Open WebUI's background title and follow-up requests make Ollama reload the model, which cancels AnythingLLM's request.
- Keep the browser open until the reply finishes; closing the page cancels the stream in both apps.
- Open WebUI: `WEBUI_AUTH=False` avoids creating an account. In 0.13.3 a 4B model kept calling the built-in automation tools, and with thinking on it once thought for four minutes and answered nothing, so the chat's Controls → Advanced Params set Function Calling to Legacy and think (Ollama) to Off. Each control is a button with the id in its label's `for` attribute; clicking cycles the values. The two memories were added with `POST /api/v1/memories/add`, which is what Settings → Personalization → Memory → Add Memory calls.
- AnythingLLM: create a workspace, upload the PDF in the document manager, Move to Workspace, Save and Embed, then ask in a new thread.
- Ollama: on Linux it is a command-line tool, so the shot is a rendering of a real terminal session (`ollama list`, then `ollama run … --hidethinking`), captured with `script` and drawn in a terminal-style HTML page.

### LM Studio and Jan (desktop apps under Xvfb)

```bash
Xvfb :173 -screen 0 2880x1800x24 -nolisten tcp &
./LM-Studio-*.AppImage --appimage-extract
HOME=$PWD/home-lms DISPLAY=:173 squashfs-root/lm-studio --no-sandbox --force-device-scale-factor=2 --remote-debugging-port=9333 &
```

- LM Studio is Electron, so Playwright's `connectOverCDP("http://127.0.0.1:9333")` drives and screenshots it. Its in-app model download crawled from this machine, so the suggested model's two files were fetched with `curl` into `~/.lmstudio/models/lmstudio-community/gemma-4-E4B-it-GGUF/`.
- Jan is Tauri (WebKitGTK) and needs `GDK_SCALE=2 WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 LIBGL_ALWAYS_SOFTWARE=1` to draw under Xvfb. Size its window with `xdotool windowsize <id> 2880 1800`, click with `xdotool`, and capture with `ffmpeg -f x11grab -video_size 2880x1800 -i :174 -frames:v 1 out.png`.

### LokalBot

The LokalBot shot is Quick Recall from `Assets/readme/search-light.png` and `search-dark.png`, made with the README capture kit (`Docs/screenshot-kit.md`).
