#!/usr/bin/env python3
"""Prepare the fictional library and settings suite for the filming copy.

    python3 Scripts/readme-gif/prepare_filming.py <new-library-dir> <defaults-suite>

Seeds the same fictional library as the UI Test Host takes, clones the
on-device models it needs from the installed app's library (APFS clones, so no
extra disk space), turns on the one-time agent access the CLI and MCP server
check, and writes a settings blob for the filming copy. Nothing is read from
or written to the installed app's library or settings.
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REAL_MODELS = Path.home() / "Library/Application Support/me.dotenv.LokalBot/models"
MODELS = {
    "gemma-4-E2B.i1-Q6_K.gguf": "Autocomplete",
    "Qwen3.5-4B-Q4_K_M.gguf": "Think and Compose",
    "embeddinggemma-2-Q8_0.gguf": "Semantic search",
}

# Everything that could capture, learn from, or reach past this library is off;
# what the scenes need is on and local. Unlisted settings keep their defaults.
SETTINGS = {
    "summarizerBackend": "Built-in (no setup)",
    "builtInModelID": "qwen3.5-4b",
    "transcriptionModel": "parakeet-v3",
    "transcriptionLanguage": "en",
    "cotypingEnabled": True,
    "cotypingBackend": "onDevice",
    "cotypingBuiltInModelID": "gemma4-e2b-base-q6",
    "cotypingInProcessRuntime": True,
    "cotypingUseMeetingMemory": True,
    "cotypingUseVisibleContext": True,
    "cotypingUseClipboard": False,
    "cotypingUseScreenMemory": False,
    "cotypingUseLocalLearning": False,
    "cotypingUserName": "",
    "dictationEnabled": True,
    "dictationIntent": "Compose",
    "dictationUseMeetingMemory": True,
    "dictationUseVisibleContext": True,
    "dictationUseScreenMemory": False,
    "dictationOutputMode": "Paste into focused app",
    "dictationShowOverlay": True,
    "dictationPlaysStartSound": False,
    "dictationLivePreview": True,
    "dictationRetainAudio": False,
    "personalLearningEnabled": False,
    "personalLearningFromDictation": False,
    "trackingEnabled": False,
    "screenshotsEnabled": False,
    "screenContextCaptureMode": "Activity only",
    "calendarDetectionEnabled": False,
    "autoRecordMode": "Never auto-record",
    "dayDigestAutoEnabled": False,
    "dreamingEnabled": False,
    "memoryRoutinesEnabled": False,
    "codingAgentEvidenceEnabled": False,
    "dailyMemoryExportEnabled": False,
    "meetingNoteExportEnabled": False,
    "quickRecallEnabled": False,
    "selectionActionsEnabled": False,
    "menuBarOnly": False,
}


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    root, suite = Path(sys.argv[1]).resolve(), sys.argv[2]
    if not suite.startswith("lokalbot.readme-gif."):
        raise SystemExit("the defaults suite must be a throwaway lokalbot.readme-gif.* name")
    subprocess.run([sys.executable, str(HERE / "seed_library.py"), str(root)], check=True, stdout=subprocess.DEVNULL)
    (root / "models").mkdir(exist_ok=True)
    for name in MODELS:
        for file in (name, name + ".sha256"):
            source = REAL_MODELS / file
            if not source.exists():
                raise SystemExit(f"missing {source}: download it in LokalBot first")
            subprocess.run(["cp", "-c", str(source), str(root / "models" / file)], check=True)
    control = root / "control"
    control.mkdir(exist_ok=True)
    (control / "agent-access-enabled").write_text("readme-gif\n")
    blob = json.dumps(SETTINGS, separators=(",", ":")).encode()
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    subprocess.run(["defaults", "write", suite, "lokalbotv3.settings", "-data", blob.hex()], check=True)
    subprocess.run(["defaults", "write", suite, "lokalbotv3.onboarding.shown", "-bool", "YES"], check=True)
    subprocess.run(["defaults", "write", suite, "lokalbotv3.gettingStartedDismissed", "-bool", "YES"], check=True)
    print(root)


if __name__ == "__main__":
    main()
