#!/usr/bin/env python3
"""Short native load/decode check using the repository's synthetic speech only.

Run with uv run --no-project python Benchmarks/GraniteSpeech5/native-smoke.py
  --models /absolute/temporary/model-directory --output /absolute/result.json
This does not launch the app, read its library, or install models into its cache.
"""

import argparse
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    model = args.models / "granite-speech-5.0-2b-Q8_0.gguf"
    projector = args.models / "mmproj-model-f16.gguf"
    audio = root / "LokalBot/Resources/ModelChecks/speech.wav"
    runtime = root / "Vendor/llama-cpp/llama-server"
    pins = {
        model: "4972786fa455b71ee1f020e8ae1b147ca6cd2b1e5b0818048011d7f1da242790",
        projector: "c0d108e1a3cf345b22c411245fc2762319f1c6b6e56bb15bdffe748c9342ca7d",
    }
    for path, expected in pins.items():
        with path.open("rb") as handle:
            actual = hashlib.file_digest(handle, "sha256").hexdigest()
        if actual != expected:
            raise RuntimeError(f"Artifact hash mismatch: {path.name}")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    token = uuid.uuid4().hex
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = f"http://127.0.0.1:{port}"
    command = [
        str(runtime), "-m", str(model), "--mmproj", str(projector),
        "--host", "127.0.0.1", "--port", str(port), "-c", "4096",
        "-ngl", "99", "--jinja", "--no-webui", "--api-key", token,
        "--parallel", "1", "--cache-ram", "256", "--threads", "4",
    ]
    log_path = args.output.with_suffix(".server.log")
    started = time.monotonic()
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Native server exited {process.returncode}; see {log_path}")
                try:
                    request = urllib.request.Request(base + "/health", headers={"Authorization": "Bearer " + token})
                    with opener.open(request, timeout=2) as response:
                        if response.status == 200:
                            break
                except (OSError, urllib.error.URLError):
                    time.sleep(0.25)
            else:
                raise TimeoutError("Native model did not become ready within 120 seconds")
            preparation = time.monotonic() - started
            results = []
            for vocabulary in [None, "LokalBot, release schedule"]:
                boundary = "granite5-smoke-" + uuid.uuid4().hex
                prompt = "transcribe the speech with proper punctuation and capitalization."
                if vocabulary:
                    prompt += " Keywords: " + vocabulary
                fields = {"model": model.name, "prompt": prompt, "language": "en"}
                chunks = []
                for key, value in fields.items():
                    chunks.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
                chunks += [
                    f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode(),
                    audio.read_bytes(), f"\r\n--{boundary}--\r\n".encode(),
                ]
                request = urllib.request.Request(
                    base + "/v1/audio/transcriptions", data=b"".join(chunks),
                    headers={"Authorization": "Bearer " + token,
                             "Content-Type": "multipart/form-data; boundary=" + boundary},
                )
                before = time.monotonic()
                with opener.open(request, timeout=120) as response:
                    payload = json.load(response)
                elapsed = time.monotonic() - before
                text = payload.get("text", "")
                words = set(text.lower().replace(".", "").replace(",", "").split())
                if not {"meeting", "release", "schedule"}.issubset(words):
                    raise AssertionError(f"Expected synthetic fixture wording; got {text!r}")
                results.append({"vocabulary": vocabulary, "text": text, "elapsedSeconds": elapsed})
            report = {
                "result": "passed", "scope": "native server smoke; not an accuracy or latency benchmark",
                "modelRevision": "df3833f5e22e7d51c3f5dfedd4726260f7ec7cb5",
                "runtimePin": "llama.cpp v0.7.0 / b11669",
                "runtimeSha256": hashlib.sha256(runtime.read_bytes()).hexdigest(),
                "audio": str(audio.relative_to(root)),
                "audioSha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
                "preparationSeconds": preparation, "calls": results,
            }
            args.output.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2), flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
