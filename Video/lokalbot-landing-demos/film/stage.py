#!/usr/bin/env python3
"""Stage what the landing demo takes film: fictional libraries, settings, audio, files, models.

    stage.py library <studio|pricing|empty> <new-dir>   seed a fictional library
    stage.py models <dir> [<library>...]          fetch the local models into <dir>, link them into each library
    stage.py settings <suite> <profile>           write the throwaway settings suite for a take
    stage.py audio <dir> <call|dictation>         write mic.wav (and system.wav) that stand in for a microphone and a call
    stage.py files <dir>                          write the folder the Files take searches
    stage.py wait-notes <library> <seeded-library> <seconds>   wait for a recorded meeting's notes, print its folder
    stage.py polish <meeting-folder>              title a recorded meeting, as a person would afterwards
    stage.py track <library>                      track the projects the Projects take opens with
    stage.py wait-note <library> <project> <seconds>   wait for the model's note on a tracked project, print it
    stage.py timezone                             print a zone where it is early afternoon now

Everything here is invented. Only the fixed model files leave the network; the
takes run with no account and no remote model.
"""
import array
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
import uuid
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
    # A detected call, so the recording binds the call's audio as well as the
    # microphone. Ask via notification is the app's default.
    "meeting": {
        "autoRecordMode": "Ask via notification",
        "trackingEnabled": True,
        "screenContextCaptureMode": "Text context",
        # This CPU-only Mac needs longer than the default budget's 10 minutes.
        "generationBudgetPreset": "unlimited",
    },
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
        "quickRecallEnabled": True,
        "menuBarOnly": True,
    },
}

# Tracked projects and their other names. Meetings join a project by these words.
# Northwind stays out of the list for the take to track it from the suggestions.
PROJECTS = {
    "Holiday shoot": ["holiday"],
    "Mac refresh": [],
    "Brand refresh": [],
}
# "SSD" comes up in enough meetings to be suggested, but it's a drive, not a project.
HIDDEN_SUGGESTIONS = ["ssd"]
CALL = [
    ("me", "Okay, let's lock the spring campaign. Are we shooting the video on location or in the studio?"),
    ("them", "The studio. It's half the budget, and we keep the whole crew."),
    ("me", "Agreed. Decision made: we shoot in the studio. Can you book it for the twelfth?"),
    ("them", "Yes. I'll book it today, and I'll send the shot list to the crew by Friday."),
    ("me", "Great. I'll get the final script to the client by Wednesday."),
    ("them", "Are we keeping the launch date on the twentieth?"),
    ("me", "Yes. We decided the launch stays on the twentieth."),
    ("them", "One open question. Do we need a second camera for the interviews?"),
    ("me", "Let's decide that after the test shoot on Monday."),
]
VOICES = {"me": "Samantha", "them": "Daniel"}
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
    elif kind == "empty":
        Path(root).mkdir(parents=True, exist_ok=True)
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


def conversation(lines, gap=0.5, tail=8.0):
    """One sample buffer per speaker, each line starting after the one before it ends."""
    spoken = [(who, say(text, VOICES[who])) for who, text in lines]
    length = sum(len(speech) for _, speech in spoken) + (int(gap * RATE) * 2) * len(spoken) + int(tail * RATE) * 2
    tracks = {who: bytearray(length) for who in VOICES}
    offset = 0
    for who, speech in spoken:
        tracks[who][offset:offset + len(speech)] = speech
        offset += len(speech) + int(gap * RATE) * 2
    return {who: room_tone(track) for who, track in tracks.items()}


def room_tone(track):
    """Faint noise under a track: speech recognition writes stray periods into digital silence."""
    samples = array.array("h", bytes(track))
    noise = random.Random(7)
    for index, sample in enumerate(samples):
        samples[index] = max(-32768, min(32767, sample + noise.randint(-6, 6)))
    return bytearray(samples.tobytes())


def audio(directory, kind):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    if kind == "call":
        tracks = conversation(CALL)
        write_wav(directory / "mic.wav", tracks["me"])
        write_wav(directory / "system.wav", tracks["them"])
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


def wait_notes(library_root, seeded_root, seconds):
    deadline = time.time() + float(seconds)
    root, seeded = Path(library_root), Path(seeded_root)
    known = {m.parent.relative_to(seeded) for m in seeded.rglob("meta.json")}
    before = None
    while time.time() < deadline:
        folders = [m.parent for m in root.rglob("meta.json") if m.parent.relative_to(root) not in known]
        for folder in folders:
            summary = folder / "summary.md"
            if summary.exists() and summary.stat().st_size > 40 and (folder / "transcript.json").exists():
                time.sleep(20)  # the pipeline writes its last files after the summary
                print(folder)
                return
        state = [(f.name, sorted(p.name for p in f.iterdir())) for f in folders]
        if state != before:
            print(f"waiting: {state}", file=sys.stderr)
            before = state
        time.sleep(5)
    raise SystemExit(f"no notes within {seconds}s")


def polish(folder):
    meta_path = Path(folder) / "meta.json"
    meta = json.loads(meta_path.read_text())
    meta["title"] = "Spring campaign"
    meta_path.write_text(json.dumps(meta, indent=2))
    print(folder)


def project_id(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"https://www.lokalbot.com/film/{name}")).upper()


def track(library_root):
    folder = Path(library_root) / "projects"
    folder.mkdir(parents=True, exist_ok=True)
    created = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    tracked = [{"id": project_id(name), "name": name, "otherNames": others, "createdAt": created}
               for name, others in PROJECTS.items()]
    curation = {"version": 1, "tracked": tracked, "hiddenNames": HIDDEN_SUGGESTIONS}
    (folder / "tracked.json").write_text(json.dumps(curation, indent=2))


def wait_note(library_root, name, seconds):
    root = Path(library_root)
    deadline = time.time() + float(seconds)
    while time.time() < deadline:
        try:
            notes = json.loads((root / "projects/summaries.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            notes = []
        # A project tracked during a take has an id the app chose, so look it up by name.
        try:
            tracked = json.loads((root / "projects/tracked.json").read_text())["tracked"]
        except (FileNotFoundError, json.JSONDecodeError):
            tracked = []
        ids = {project["id"].upper() for project in tracked if project["name"] == name}
        for note in notes:
            if note["projectID"].upper() in ids:
                print(json.dumps(note, indent=2))
                return
        # The app doesn't try a project again until it next launches.
        log = root / "debug.log"
        if log.exists():
            text = log.read_text(errors="replace")
            for failure in ("did not become healthy", "managed inference recovery failed"):
                if failure in text:
                    raise SystemExit(f"no note on {name}: {failure}")
        time.sleep(5)
    raise SystemExit(f"no note on {name} within {seconds}s")


def main():
    commands = {"library": library, "models": models, "settings": settings, "audio": audio, "files": files,
                "wait-notes": wait_notes, "polish": polish, "track": track, "wait-note": wait_note,
                "timezone": timezone_now}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    main()
