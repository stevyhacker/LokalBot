#!/usr/bin/env python3
"""Stage the agent handoff demo: a fictional library, a just-finished call, and settings.

    stage.py library <new-empty-dir>          seed the launch-pricing library
    stage.py meeting <library>                add the follow-up call; prints its ID and folder
    stage.py warmup <new-empty-dir>           one short call to load transcription
    stage.py settings <suite> <model>         write the settings the film runs with

The follow-up call is two tracks, like a recording: the microphone carries the
person's lines and the system track Priya's. Only the microphone is the
person, so only the actions they take on are handed off. Everything here is
invented; the voices are macOS speech synthesis.
"""
import importlib.util
import json
import os
import subprocess
import sys
import uuid
import wave
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("seed", HERE.parent / "seed_demo_library.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)

RATE = 22_050
GAP = 1.0
TAIL = 4

# Priya owns the website; the four things the person takes on go to agents.
FOLLOW_UP = [
    ("them", "Hi! Thanks for making time. I know the week is packed, so this will be quick."),
    ("me", "No problem. I have the pricing sheet open, so let's go through what is left before the launch."),
    ("them", "Pricing is locked: fifteen dollars per seat, billed annually, "
             "plus the free plan for teams of up to three."),
    ("me", "Great. I'll draft the launch announcement email for our customers today."),
    ("them", "Support will get questions about annual billing and refunds."),
    ("me", "I'll write a short pricing FAQ that covers annual billing, refunds, and the free plan."),
    ("them", "Sales also wants the plans side by side."),
    ("me", "I'll put the plan comparison into a CSV table they can paste into the deck."),
    ("them", "Perfect. I'll update the pricing page on the website myself by Monday."),
    ("me", "And I'll write the release notes for the launch. That's everything from me."),
    ("them", "Thanks. Talk on Tuesday."),
    ("me", "Talk then. Bye!"),
]

WARMUP = [
    ("them", "Can you hear me?"),
    ("me", "Yes, loud and clear."),
]

# Everything that could capture, learn, or reach past the library stays off;
# the meeting is transcribed on this Mac and summarized, like the agents' work,
# by the OpenRouter model. Unlisted settings keep their defaults.
SETTINGS = {
    "summarizerBackend": "OpenAI-compatible server",
    "openAIBaseURL": "https://openrouter.ai/api/v1",
    "approvedRemoteInferenceOrigins": ["https://openrouter.ai"],
    "transcriptionModel": "parakeet-v3",
    "transcriptionLanguage": "en",
    "autoTranscribe": True,
    "autoSummarize": True,
    "multiSpeakerDiarization": False,
    "semanticSearchEnabled": False,
    "handOffActionsAfterSummary": True,
    "startHandoffsAutomatically": True,
    "windowHandoffEnabled": False,
    "trackingEnabled": False,
    "screenshotsEnabled": False,
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
    "personalLearningEnabled": False,
    "menuBarOnly": False,
}


def write_tracks(lines, folder):
    """Each line follows the last; both tracks run to the same length."""
    tracks = {"me": bytearray(), "them": bytearray()}
    cursor = 0
    clip = os.path.join(folder, "line.wav")
    for speaker, text in lines:
        speech = seed.say_speech(text, RATE, clip)
        track = tracks[speaker]
        track.extend(bytes(max(0, cursor - len(track))))
        track[cursor:cursor + len(speech)] = speech
        cursor += len(speech) + int(GAP * RATE) * 2
    cursor += TAIL * RATE * 2
    for speaker, name in (("me", "mic"), ("them", "system")):
        track = tracks[speaker]
        track.extend(bytes(max(0, cursor - len(track))))
        path = os.path.join(folder, f"{name}.wav")
        with wave.open(path, "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(RATE)
            writer.writeframes(bytes(track))
        subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", path,
                        os.path.join(folder, f"{name}.m4a")], check=True)
        os.remove(path)
    return cursor / (RATE * 2)


def write_call(root, title, slug, lines):
    """A call that ended twenty seconds ago, with audio and no transcript yet."""
    ended = datetime.now(timezone.utc) - timedelta(seconds=20)
    rel = seed.relpath(ended, slug)
    folder = os.path.join(root, rel)
    os.makedirs(folder, exist_ok=True)
    seconds = write_tracks(lines, folder)
    started = ended - timedelta(seconds=seconds)
    meeting_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"lokalbot-agent-handoff-demo-{slug}-{ended.isoformat()}"))
    meta = {"appName": "Zoom", "endedAt": seed.iso(ended), "hasSystemTrack": True, "id": meeting_id,
            "relativePath": rel, "startedAt": seed.iso(started), "title": title}
    with open(os.path.join(folder, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    return meeting_id, folder


def write_settings(suite, model):
    settings = dict(SETTINGS, openAIModel=model)
    blob = json.dumps(settings, separators=(",", ":")).encode()
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    for args in (["lokalbotv3.settings", "-data", blob.hex()],
                 ["lokalbotv3.onboarding.shown", "-bool", "YES"],
                 ["lokalbotv3.gettingStartedDismissed", "-bool", "YES"],
                 # Full access: no tool asks first, so the agents run unattended.
                 # In the narrower modes each lokalbot-cli lookup waits for a click.
                 ["lokalbotv3.agent.approvalMode", "-int", "3"]):
        subprocess.run(["defaults", "write", suite, *args], check=True)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    command, target = sys.argv[1], sys.argv[2]
    if command == "library":
        subprocess.run([sys.executable, str(HERE.parent / "readme-gif" / "seed_library.py"), target],
                       check=True, stdout=subprocess.DEVNULL)
        control = Path(target) / "control"
        control.mkdir(exist_ok=True)
        (control / "agent-access-enabled").write_text("agent-handoff-demo\n")
        print(target)
    elif command == "meeting":
        meeting_id, folder = write_call(target, "Launch follow-up", "launch-follow-up", FOLLOW_UP)
        print(meeting_id, folder)
    elif command == "warmup":
        os.makedirs(os.path.join(target, "meetings"), exist_ok=True)
        with open(os.path.join(target, seed.OWNERSHIP_MARKER), "w") as f:
            f.write("LokalBot synthetic demo library (agent handoff warm-up)\n")
        print(write_call(target, "Warm-up", "warm-up", WARMUP)[1])
    elif command == "settings" and len(sys.argv) == 4:
        write_settings(target, sys.argv[3])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
