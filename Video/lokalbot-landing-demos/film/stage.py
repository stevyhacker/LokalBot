#!/usr/bin/env python3
"""Stage what the landing demo takes film: fictional libraries, settings, audio, files, models.

    stage.py library <studio|pricing> <new-dir>   seed a fictional library
    stage.py models <dir> [<library>...]          fetch the local models into <dir>, link them into each library
    stage.py settings <suite> <profile>           write the throwaway settings suite for a take
    stage.py audio <dir> <call|dictation>         write mic.wav (and system.wav) that stand in for a microphone and a call
    stage.py files <dir>                          write the folder the Files take searches
    stage.py wait-notes <library> <seconds>       wait for a recorded meeting's notes, print its folder
    stage.py polish <meeting-folder>              name the other speaker in a recorded meeting
    stage.py timezone                             print a zone where it is early afternoon now

Everything here is invented. Only the fixed model files leave the network; the
takes run with no account and no remote model.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import wave
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
CATALOG = ROOT / "LokalBot/Engines/ModelCatalog.swift"
EMBEDDING = ROOT / "LokalBot/Services/EmbeddingIndex.swift"
FILE_MODELS = ROOT / "LokalBot/Services/FileSearch/FileMediaEmbedderRuntime.swift"
RATE = 16_000

# What every take needs off: nothing captures, learns, or reaches past the library.
BASE = {
    "summarizerBackend": "Built-in (no setup)",
    "builtInModelID": "qwen3.5-4b",
    "transcriptionModel": "parakeet-v3",
    "transcriptionLanguage": "en",
    "multiSpeakerDiarization": False,
    "semanticSearchEnabled": False,
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
    "cotypingEnabled": False,
    "dictationEnabled": False,
    "quickRecallEnabled": False,
    "selectionActionsEnabled": False,
    "menuBarOnly": False,
}
PROFILES = {
    "fixture": {},
    "meeting": {},
    "ask": {},
    "dictation": {
        "dictationEnabled": True,
        "dictationIntent": "Compose",
        "dictationUseMeetingMemory": True,
        "dictationUseVisibleContext": False,
        "dictationUseScreenMemory": False,
        "dictationOutputMode": "Paste into focused app",
        "dictationShowOverlay": True,
        "dictationPlaysStartSound": False,
        "dictationLivePreview": True,
        "dictationRetainAudio": False,
        "menuBarOnly": True,
    },
    "files": {
        "semanticSearchEnabled": True,
        "fileSearchEnabled": True,
        "fileSearchIncludesMedia": True,
        "fileSearchReadsOnBattery": True,
    },
}

CALL = [
    (0.0, "me", "Okay, let's lock the spring campaign. Are we shooting the video in Lisbon or in the studio?"),
    (6.5, "them", "The studio. It's half the budget, and we keep the whole crew."),
    (11.5, "me", "Agreed. The studio it is. Can you book it for the twelfth?"),
    (16.5, "them", "I'll book it today, and I'll send the shot list by Friday."),
    (21.5, "me", "Great. I'll get the final script to the client by Wednesday."),
    (26.5, "them", "One open question. Do we need a second camera for the interviews?"),
]
DICTATION = "Write a short team update with the launch pricing."
LEASE_PAGES = [
    "HARBOR STREET STUDIO LEASE\n\nThis lease is between Harbor Street Properties and Northwind Studio.\nThe term runs for twenty-four months from the first of March.\n\n1. Premises\nThe second floor of 18 Harbor Street, including the loading bay.",
    "2. Rent\nRent is 3,200 per month, due on the first of each month.\nA late fee applies after the fifth.\n\n3. Deposit\nThe deposit equals two months of rent and is held in a separate account.",
    "4. Use\nThe premises may be used for photo and video production and related office work.\nLoud shoots are limited to weekdays between nine and six.",
    "5. Pets\nTenant may keep one dog or cat on the premises with the landlord's written approval.\nA pet deposit of 300 applies, and tenant repairs any damage the animal causes.\n\n6. Parking\nTwo marked spaces in the rear lot are included in the rent.",
    "7. Ending the lease\nEither side may end the lease with sixty days of written notice after the first year.\n\nSigned by both parties.",
]
CHECKLIST = "NORTHWIND DELIVERY CHECKLIST\n\nFinal cut approved by the client\nCaptions burned in for social, sidecar files for web\nThree vertical cuts, 30 seconds each\nColor pass signed off\nMusic licenses filed\nDelivery by Friday noon\n"
INTERVIEW = [
    "Welcome back. Today we're talking about how small studios plan a shoot.",
    "The first thing we changed was the call sheet. Everyone gets it the night before, on their phone.",
    "And the second thing was sleep. Honestly, the crew shoots better after eight hours than after any new camera.",
    "We stopped starting at six in the morning, and nobody asked to go back.",
    "Then we moved the color pass to the end of the week, so nothing gets rushed.",
    "That's it for today. Thanks for listening.",
]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def timezone_now():
    """A fixed-offset zone where it is about two in the afternoon, so today's seeded work looks like a workday."""
    offset = (14 - datetime.now(timezone.utc).hour + 12) % 24 - 12
    # POSIX reverses the sign: Etc/GMT-9 is nine hours ahead of UTC.
    print(f"Etc/GMT{-offset:+d}" if offset else "Etc/GMT")


def library(kind, root):
    if kind == "studio":
        run(sys.executable, ROOT / "Video/lokalbot-readme-hero/filming/seed_filming_library.py", root, stdout=subprocess.DEVNULL)
    elif kind == "pricing":
        run(sys.executable, ROOT / "Scripts/readme-gif/seed_library.py", root, stdout=subprocess.DEVNULL)
    else:
        raise SystemExit(f"unknown library {kind}")
    print(root)


def catalog_entry(model_id):
    match = re.search(r'Entry\(id: "' + re.escape(model_id) + r'",.*?fileName: "([^"]+)",\s*url: "([^"]+)",\s*sha256: "([0-9a-f]{64})"',
                      CATALOG.read_text(), re.S)
    if not match:
        raise SystemExit(f"cannot find {model_id} in {CATALOG}")
    return match.groups()


def embedding_entries():
    source = EMBEDDING.read_text()
    name = re.search(r'static let modelFile = "([^"]+)"', source).group(1)
    digest = re.search(r'modelSHA256 = "([0-9a-f]{64})"', source).group(1)
    url = re.search(r'modelURL =\s*"([^"]+)"', source)
    if url:
        url = url.group(1)
    else:
        url = re.search(r'modelURL =\s*\n?\s*"([^"]+)"\s*\+?\s*"?([^"\n]*)"?', source)
        url = url.group(1) + url.group(2)
    source = FILE_MODELS.read_text()
    projector = re.search(r'projectorFile = "([^"]+)"', source).group(1)
    projector_digest = re.search(r'projectorSHA256 = "([0-9a-f]{64})"', source).group(1)
    base = re.search(r'projectorURL = URL\(string:\s*"([^"]+)"', source, re.S).group(1)
    return [(name, url, digest), (projector, base + projector, projector_digest)]


def sha256(path):
    out = subprocess.run(["shasum", "-a", "256", str(path)], check=True, capture_output=True, text=True).stdout
    return out.split()[0]


def models(directory, *libraries):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    wanted = [catalog_entry("qwen3.5-4b"), *embedding_entries()]
    for name, url, digest in wanted:
        target = directory / name
        if not target.exists() or sha256(target) != digest:
            print(f"downloading {name}", file=sys.stderr)
            partial = target.with_suffix(".part")
            run("curl", "-fL", "--retry", "3", "--retry-delay", "5", "-sS", "-o", partial, url)
            if sha256(partial) != digest:
                raise SystemExit(f"{name} does not match its pinned SHA-256")
            partial.rename(target)
        (directory / f"{name}.sha256").write_text(digest)
    for lib in libraries:
        folder = Path(lib) / "models"
        folder.mkdir(parents=True, exist_ok=True)
        for name, _, digest in wanted:
            link = folder / name
            if not link.exists():
                os.link(directory / name, link)
            (folder / f"{name}.sha256").write_text(digest)


def settings(suite, profile):
    if not suite.startswith("lokalbot.landing-film."):
        raise SystemExit("the defaults suite must be a throwaway lokalbot.landing-film.* name")
    values = {**BASE, **PROFILES[profile]}
    if profile == "files":
        values["fileSearchFolders"] = [os.environ["FILM_FILES"]]
    blob = json.dumps(values, separators=(",", ":")).encode()
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    run("defaults", "write", suite, "lokalbotv3.settings", "-data", blob.hex())
    for key in ("lokalbotv3.onboarding.shown", "lokalbotv3.gettingStartedDismissed"):
        run("defaults", "write", suite, key, "-bool", "YES")


def say(text, voice, rate=RATE):
    clip = f"/tmp/landing-say-{os.getpid()}.wav"
    run("/usr/bin/say", "-v", voice, f"--data-format=LEI16@{rate}", "-o", clip, text, stderr=subprocess.DEVNULL)
    with wave.open(clip) as reader:
        data = reader.readframes(reader.getnframes())
    os.remove(clip)
    if not any(data):
        raise SystemExit(f"{voice} synthesized silence")
    return data


def write_wav(path, samples):
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(RATE)
        writer.writeframes(bytes(samples))


def track(lines, who, voice, length):
    samples = bytearray(int(length * RATE) * 2)
    for start, speaker, text in lines:
        if speaker != who:
            continue
        speech = say(text, voice)
        offset = int(start * RATE) * 2
        samples[offset:offset + len(speech)] = speech
    return samples


def audio(directory, kind):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    if kind == "call":
        length = CALL[-1][0] + 8
        write_wav(directory / "mic.wav", track(CALL, "me", "Samantha", length))
        write_wav(directory / "system.wav", track(CALL, "them", "Daniel", length))
    else:
        write_wav(directory / "mic.wav", bytes(int(0.5 * RATE) * 2) + say(DICTATION, "Samantha") + bytes(int(3 * RATE) * 2))
    print(directory)


def files(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    text = directory / "lease.txt"
    text.write_text("\f".join(LEASE_PAGES))
    with open(directory / "Harbor Street lease.pdf", "wb") as out:
        run("/usr/sbin/cupsfilter", text, stdout=out, stderr=subprocess.DEVNULL)
    text.unlink()
    (directory / "Northwind delivery checklist.txt").write_text(CHECKLIST)
    speech = bytearray()
    for line in INTERVIEW:
        speech += say(line, "Samantha") + bytes(int(0.7 * RATE) * 2)
    wav = directory / "episode.wav"
    write_wav(wav, speech)
    run("/usr/bin/afconvert", "-f", "m4af", "-d", "aac", wav, directory / "Small Studios podcast, episode 12.m4a")
    wav.unlink()
    print(directory)


def wait_notes(library_root, seconds):
    deadline = time.time() + float(seconds)
    root = Path(library_root)
    before = None
    while time.time() < deadline:
        folders = [m.parent for m in root.rglob("meta.json") if "demo" not in m.parent.name and is_new(m)]
        for folder in folders:
            summary = folder / "summary.md"
            if summary.exists() and summary.stat().st_size > 40 and (folder / "transcript.json").exists():
                print(folder)
                return
        state = [(f.name, sorted(p.name for p in f.iterdir())) for f in folders]
        if state != before:
            print(f"waiting: {state}", file=sys.stderr)
            before = state
        time.sleep(5)
    raise SystemExit(f"no notes within {seconds}s")


def is_new(meta):
    """A meeting the take recorded, not one the seed wrote."""
    try:
        return "recording" in meta.parent.name or json.loads(meta.read_text()).get("appName") in (None, "", "Manual")
    except (OSError, ValueError):
        return False


def polish(folder):
    path = Path(folder) / "transcript.json"
    data = json.loads(path.read_text())
    data["speakerAliases"] = {"them": "Maya"}
    path.write_text(json.dumps(data, indent=2))
    meta_path = Path(folder) / "meta.json"
    meta = json.loads(meta_path.read_text())
    meta["title"] = "Spring campaign"
    meta["appName"] = "FaceTime"
    meta_path.write_text(json.dumps(meta, indent=2))
    print(folder)


def main():
    commands = {"library": library, "models": models, "settings": settings, "audio": audio, "files": files,
                "wait-notes": wait_notes, "polish": polish, "timezone": timezone_now}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    main()
