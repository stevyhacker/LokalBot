"""Seed the isolated, fictional library and settings suite for filming.

Writes only to a new library folder and the `me.dotenv.LokalBot.filming`
defaults suite. Settings start from the installed app's current settings so
model choice and writing defaults match what ships, then everything that could
capture, record, schedule work or read real data is switched off. Autocomplete
keeps meeting memory and visible text on; clipboard, screen memory and local
learning are off so nothing from the real Mac reaches a suggestion on camera.

Usage: python3 seed_library.py <new-library-dir>
"""
import importlib.util
import json
import plistlib
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SUITE = "me.dotenv.LokalBot.filming"
REAL_MODELS = Path.home() / "Library/Application Support/me.dotenv.LokalBot/models"
MODEL = "gemma-4-E2B.i1-Q6_K.gguf"

spec = importlib.util.spec_from_file_location("seed", REPO / "Scripts/seed_demo_library.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)

root = Path(sys.argv[1]).resolve()
if root.exists() and any(root.iterdir()):
    raise SystemExit(f"Refusing to overwrite a populated library: {root}")
root.mkdir(parents=True, exist_ok=True)

# The meeting autocomplete draws on in the film. Fictional people and project.
now = datetime.now().astimezone()
yesterday = (now - timedelta(days=1)).replace(hour=15, minute=0, second=0, microsecond=0).astimezone(timezone.utc)
harbor = seed.m(
    "77777777-7777-4777-8777-777777777777", "Harbor beta check-in", "Google Meet",
    yesterday, 22, True, [
        seed.seg(0, 9, "me", "How are we looking for the Harbor beta?"),
        seed.seg(9, 24, "them", "Good. The accessibility review is on Wednesday. If it passes, the beta ships Thursday morning."),
        seed.seg(24, 33, "me", "Perfect. I'll tell the team and update the release notes."),
        seed.seg(33, 45, "them", "The first fifty testers get their invites on Friday, together with the feedback form."),
        seed.seg(45, 54, "me", "Great. Then Friday is invite day."),
    ],
    "## TL;DR\nJohn confirmed the Harbor beta ships Thursday morning, right after Wednesday's accessibility review. "
    "The first fifty testers get their invites on Friday.\n\n"
    "## Decisions\n- The Harbor beta ships Thursday morning, after the accessibility review.\n"
    "- The first fifty testers get invites on Friday, with the feedback form.\n\n"
    "## Action items\n- [ ] Tell the team the beta date and update the release notes — Me\n"
    "- [ ] Prepare the feedback form by Thursday — John\n")
seed.write_meeting(str(root), harbor)
(root / seed.OWNERSHIP_MARKER).write_text("filming\n")
(root / "FILMING-CONTENT.json").write_text(json.dumps({
    "fictional": True, "purpose": "Autocomplete launch film", "createdAt": now.isoformat(),
    "meetingIDs": [harbor["id"]]}, indent=2) + "\n")

# Catalog GGUFs load from the library root; an APFS clone costs no space and
# leaves the real models folder untouched.
(root / "models").mkdir(exist_ok=True)
for name in (MODEL, MODEL + ".sha256"):
    subprocess.run(["cp", "-c", str(REAL_MODELS / name), str(root / "models" / name)], check=True)

real = plistlib.loads(subprocess.run(["defaults", "export", "me.dotenv.LokalBot", "-"],
                                     check=True, capture_output=True).stdout)
settings = json.loads(real["lokalbotv3.settings"])
settings.update({
    # Autocomplete as it ships, plus meeting memory and visible text.
    "cotypingEnabled": True,
    "cotypingBuiltInModelID": "gemma4-e2b-base-q6",
    "cotypingInProcessRuntime": True,
    "cotypingUseMeetingMemory": True,
    "cotypingUseVisibleContext": True,
    "cotypingUseAppContext": True,
    # New-install language default (auto), not the author's own hint.
    "cotypingLanguages": "",
    # Nothing from the real Mac on camera.
    "cotypingUseClipboard": False,
    "cotypingUseScreenMemory": False,
    "cotypingUseLocalLearning": False,
    # No capture, recording, scheduling or background model work.
    "autoRecordMode": "Never auto-record",
    "calendarDetectionEnabled": False,
    "useCalendarTitles": False,
    "useCalendarAgenda": False,
    "meetingNotesUseCalendarContext": False,
    "screenshotsEnabled": False,
    "trackingEnabled": False,
    "dictationEnabled": False,
    "quickRecallEnabled": False,
    "dayDigestAutoEnabled": False,
    "dreamingEnabled": False,
    "memoryRoutinesEnabled": False,
    "codingAgentEvidenceEnabled": False,
    "codingAgentReadsClaudeCode": False,
    "codingAgentReadsCodex": False,
    "semanticSearchEnabled": False,
    "menuBarOnly": True,
})
blob = json.dumps(settings, separators=(",", ":")).encode()
subprocess.run(["defaults", "delete", SUITE], capture_output=True)
subprocess.run(["defaults", "write", SUITE, "lokalbotv3.settings", "-data", blob.hex()], check=True)
print(root)
