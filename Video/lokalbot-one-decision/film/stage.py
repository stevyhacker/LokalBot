#!/usr/bin/env python3
"""Stage what the One Decision film records: a fictional library, settings, the call's audio.

    stage.py library <new-dir>            seed the fictional team's library
    stage.py models <library>             clone the on-device models from the installed LokalBot
    stage.py settings <suite> <profile>   write the throwaway settings suite for a take
    stage.py audio <dir>                  write mic.wav and system.wav, the two sides of the call
    stage.py spoken <dir> <audio-file>    write mic.wav from a recorded line, for the dictation take
    stage.py wait-notes <library> <seeded-library> <seconds>   wait for the recorded call's notes
    stage.py polish <meeting-folder>      title the recorded call, as a person would afterwards
    stage.py adopt <library> <meeting-folder>   put an already recorded call into a seeded library
    stage.py document <dir> [name] [text] write the TextEdit document a take types or dictates in
    stage.py timezone                     print a zone where it is early afternoon now

STAGE_NOW (an ISO time with its offset) seeds the library as of that moment instead of now,
so a take filmed later shows the same times as the takes before it.

Everything here is invented. The film follows one decision, "the offsite is in
Lisbon, May 12th to 14th", from the call where it is made to every place it
comes back. The library around it is a small team's ordinary fortnight, with a
different topic in every meeting.

The generic pieces (speech synthesis, the settings writer, the notes wait) are
the landing demos' and are loaded from there.
"""
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
REAL_MODELS = Path.home() / "Library/Application Support/me.dotenv.LokalBot/models"
MODELS = ["Qwen3.5-4B-Q4_K_M.gguf", "embeddinggemma-2-Q8_0.gguf", "gemma-4-E2B.i1-Q6_K.gguf"]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


landing = load("landing_stage", ROOT / "Video/lokalbot-landing-demos/film/stage.py")
seed = load("seed", ROOT / "Scripts/seed_demo_library.py")

CALL = [
    ("me", "Okay, let's settle the offsite. Lisbon or Porto?"),
    ("them", "Lisbon. The rooftop venue fits all forty of us, and it's under budget."),
    ("me", "Agreed. Decision made: the offsite is in Lisbon, May twelfth to fourteenth."),
    ("them", "Great. I'll pay the venue deposit by Friday."),
    ("me", "And I'll send the invitations on Monday."),
    ("them", "One open question. Do we fly everyone in on Sunday?"),
    ("me", "Let's decide that after we see the flight prices."),
]
TITLE = "Offsite planning"

PROFILES = {
    "fixture": {},
    "meeting": dict(landing.PROFILES["meeting"]),
    # Autocomplete in another app, on the default on-device model, reading the
    # meetings. Nothing that could learn from or capture the take is on.
    "autocomplete": {
        "cotypingEnabled": True,
        "cotypingBackend": "onDevice",
        "cotypingBuiltInModelID": "gemma4-e2b-base-q6",
        "cotypingInProcessRuntime": True,
        "cotypingUseMeetingMemory": True,
        "cotypingUseVisibleContext": False,
        "cotypingUseWindowText": False,
        "cotypingUseClipboard": False,
        "cotypingUseScreenMemory": False,
        "cotypingUseLocalLearning": False,
        "cotypingUserName": "",
        "cotypingAcceptGranularity": "word",
        "cotypingMaxWords": 8,
        "menuBarOnly": True,
    },
    # Compose: say what you need and LokalBot writes it at the cursor, from the meetings.
    # The shortcut is two modifiers held (the app's own kind of shortcut) that nothing else
    # on a working Mac listens for: Option-Space belongs to launchers there.
    "dictation": {
        **landing.PROFILES["dictation"],
        "dictationShortcut": {"modifiers": ["option", "shift"]},
        "dictationTriggerMode": "Push to talk",
    },
}


def utc(dt):
    return dt.astimezone(timezone.utc)


def meetings(now):
    """The team's other calls. The offsite call itself is recorded live by the film."""
    day = lambda days, hour, minute=0: utc((now - timedelta(days=days)).replace(
        hour=hour, minute=minute, second=0, microsecond=0))
    s = seed.seg
    uid = lambda n: f"0dec1510-0000-4000-8000-{n:012d}"
    return [
        seed.m(uid(1), "Hiring sync", "FaceTime", day(0, 11, 30), 25, True, [
            s(0, 8, "them", "Both finalists for the designer role did well on the portfolio review."),
            s(8, 17, "me", "Ines had the stronger research work. I'd make her the offer."),
            s(17, 25, "them", "Agreed. I'll send the offer on Thursday."),
            s(25, 33, "me", "I'll write back to the other candidate myself."),
        ], "## TL;DR\nInes gets the offer for the designer role.\n\n"
           "## Decisions\n- Offer the designer role to Ines.\n\n"
           "## Action items\n- [ ] Send the offer on Thursday — Them\n- [ ] Write back to the other candidate — Me"),
        seed.m(uid(2), "Weekly team sync", "Google Meet", day(0, 10), 30, True, [
            s(0, 9, "me", "The spring newsletter goes out Wednesday. Anything blocking it?"),
            s(9, 19, "them", "Only the customer story. The interview is tomorrow morning."),
            s(19, 28, "me", "Then we hold the newsletter until the story is in."),
        ], "## TL;DR\nThe spring newsletter waits for the customer story.\n\n"
           "## Decisions\n- Hold the newsletter until the customer story is in.\n\n"
           "## Action items\n- [ ] Finish the customer interview — Them"),
        seed.m(uid(3), "Budget review", "Google Meet", day(1, 15), 40, True, [
            s(0, 10, "them", "Travel is the only line over plan this quarter."),
            s(10, 21, "me", "We keep it. The offsite is the one trip that pays for itself."),
            s(21, 30, "them", "Then I'll cap the travel budget at eighteen thousand."),
        ], "## TL;DR\nTravel stays in the budget, capped at 18,000.\n\n"
           "## Decisions\n- Cap the travel budget at 18,000.\n\n"
           "## Action items\n- [ ] Update the budget sheet — Them"),
        seed.m(uid(4), "1:1 with Jonas", "FaceTime", day(2, 16), 30, True, [
            s(0, 11, "them", "I'd like to run the customer workshop in June."),
            s(11, 20, "me", "It's yours. Send me an outline by next Friday."),
        ], "## TL;DR\nJonas runs the June customer workshop.\n\n"
           "## Action items\n- [ ] Send the workshop outline — Them"),
        seed.m(uid(5), "Website relaunch review", "Google Meet", day(3, 11), 45, True, [
            s(0, 10, "me", "The new homepage reads well. The pricing page is still too long."),
            s(10, 22, "them", "We can cut the comparison table and link to it instead."),
            s(22, 30, "me", "Do that. We relaunch on the first of the month."),
        ], "## TL;DR\nThe pricing page loses its comparison table; relaunch on the first.\n\n"
           "## Decisions\n- Cut the comparison table from the pricing page.\n- Relaunch on the first of the month.\n\n"
           "## Action items\n- [ ] Shorten the pricing page — Them"),
        seed.m(uid(6), "Print supplier call", "FaceTime", day(6, 14), 20, True, [
            s(0, 9, "them", "We can print the welcome kits in two weeks at the recycled stock."),
            s(9, 18, "me", "Good. Two hundred kits, recycled stock, delivered to the office."),
        ], "## TL;DR\n200 welcome kits on recycled stock, delivered in two weeks.\n\n"
           "## Decisions\n- Print 200 welcome kits on recycled stock."),
    ]


def screens(root, now):
    """What was on screen around the offsite: seen, not said."""
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    seed.ensure_activity_tables(cur)
    t = now.timestamp()
    # The day the Timeline shows: what was open, by the clock. It holds the film's own
    # story (the venue research, the update typed after the call, the agent's terminal), and
    # each block covers the screen moment seeded for it below. The calls are not blocks: the
    # Timeline lists each meeting itself.
    at = lambda hour, minute: now.replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()
    for app, title, start, end in [
        ("Mail", "Inbox", at(9, 10), at(9, 50)),
        ("Keynote", "Spring kickoff", at(10, 38), at(11, 22)),
        ("Safari", "Rooftop venues in Lisbon", at(11, 31), at(11, 56)),
        ("Numbers", "Offsite budget", at(11, 56), at(12, 16)),
        ("Pages", "Designer role", at(12, 26), at(12, 56)),
        ("Mail", "Re: Offsite dates", at(13, 56), at(14, 4)),
        ("Keynote", "Spring kickoff", at(14, 6), at(14, 36)),
        ("TextEdit", "Team update", at(15, 44), at(16, 6)),
        ("Terminal", "claude — offsite", at(16, 12), at(16, 34)),
    ]:
        cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)", (app, title, start, end))
    yesterday = t - 24 * 3600
    shots = [
        ("Safari", "Rooftop venues in Lisbon", t - 196 * 60,
         "Terraço Alfama: a rooftop venue in Lisbon for up to 45 guests, with a river view.", "web", (0, 122, 255)),
        ("Numbers", "Offsite budget", t - 171 * 60,
         "Lisbon: venue 2,400, hotel 11,200, flights 9,600. Porto: venue 3,100, hotel 12,500.", "sheet", (52, 199, 89)),
        ("Mail", "Re: Offsite dates", t - 56 * 60,
         "May 12 to 14 works for the venue in Lisbon. Please confirm by Friday.", "mail", (0, 122, 255)),
        ("Pages", "Designer role", t - 138 * 60,
         "Product designer: research, interface design, and one customer call a week.", "doc", (255, 149, 0)),
        ("Keynote", "Spring kickoff", t - 34 * 60,
         "Spring kickoff: three goals, one customer story, and the new website.", "slide", (255, 159, 10)),
        ("Maps", "Alfama, Lisbon", yesterday - 95 * 60,
         "Alfama, Lisbon. 12 minutes on foot from the hotel to the rooftop.", "web", (52, 199, 89)),
    ]
    for index, (app, title, ts, text, kind, accent) in enumerate(shots, start=1):
        folder = os.path.join(root, "activity", datetime.fromtimestamp(ts).strftime("%Y-%m-%d"), "demo")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"scene-{index}.png")
        seed.write_light_window_png(path, kind, accent)
        cur.execute("""INSERT INTO screenshots (ts, path, app, window_title, capture_trigger, perceptual_hash,
                       similarity_group, source_url, document_name, meeting_id, privacy_redactions)
                       VALUES (?, ?, ?, ?, 'window_change', '', ?, '', ?, '', 0)""",
                    (ts, path, app, title, index, title))
        cur.execute("""INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id)
                       VALUES (?, ?, ?, ?, 'accessibility', ?)""", (text, title, ts, app, cur.lastrowid))
    con.commit()
    con.close()


def library(root):
    root = os.path.abspath(root)
    if os.path.exists(root) and os.listdir(root):
        raise SystemExit(f"Refusing to overwrite a populated directory: {root}")
    os.makedirs(os.path.join(root, "meetings"), exist_ok=True)
    with open(os.path.join(root, seed.OWNERSHIP_MARKER), "w") as f:
        f.write("LokalBot synthetic demo library (One Decision film)\n")
    now = (datetime.fromisoformat(os.environ["STAGE_NOW"]) if os.environ.get("STAGE_NOW") else datetime.now()).astimezone()
    names = {"Hiring sync": "Dana", "Weekly team sync": "Omar", "Budget review": "Ruth",
             "1:1 with Jonas": "Jonas", "Website relaunch review": "Kai", "Print supplier call": "Vera"}
    for mm in meetings(now):
        folder = seed.write_meeting(root, mm)
        seed.write_demo_audio(folder)
        seed.write_demo_audio(folder, track="system", tone=247, beat=2.7, level=1_400)
        path = os.path.join(folder, "transcript.json")
        with open(path) as f:
            transcript = json.load(f)
        transcript["speakerAliases"] = {"them": names[mm["title"]]}
        with open(path, "w") as f:
            json.dump(transcript, f, indent=2)
    screens(root, now)
    os.makedirs(os.path.join(root, "journal"), exist_ok=True)
    os.makedirs(os.path.join(root, "control"), exist_ok=True)
    with open(os.path.join(root, "control", "agent-access-enabled"), "w") as f:
        f.write("one-decision-film\n")
    print(root)


def models(library_root):
    """APFS clones of the installed app's models, so nothing downloads and nothing is copied."""
    folder = Path(library_root) / "models"
    folder.mkdir(parents=True, exist_ok=True)
    for name in MODELS:
        for file in (name, name + ".sha256"):
            source = REAL_MODELS / file
            if not source.exists():
                raise SystemExit(f"missing {source}: download it in LokalBot first")
            if not (folder / file).exists():
                subprocess.run(["cp", "-c", str(source), str(folder / file)], check=True)
    print(folder)


def settings(suite, profile):
    if not suite.startswith("lokalbot.landing-film."):
        raise SystemExit("the defaults suite must be a throwaway lokalbot.landing-film.* name")
    values = {**landing.BASE, **PROFILES[profile]}
    blob = json.dumps(values, separators=(",", ":")).encode()
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    subprocess.run(["defaults", "write", suite, "lokalbotv3.settings", "-data", blob.hex()], check=True)
    for key in ("lokalbotv3.onboarding.shown", "lokalbotv3.gettingStartedDismissed"):
        subprocess.run(["defaults", "write", suite, key, "-bool", "YES"], check=True)


def audio(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    tracks = landing.conversation(CALL)
    landing.write_wav(directory / "mic.wav", tracks["me"])
    landing.write_wav(directory / "system.wav", tracks["them"])
    print(directory)


def polish(folder):
    meta_path = Path(folder) / "meta.json"
    meta = json.loads(meta_path.read_text())
    meta["title"] = TITLE
    meta_path.write_text(json.dumps(meta, indent=2))
    print(folder)


def adopt(library_root, folder):
    """A call recorded by an earlier `live` take, back in its place in a newly seeded library."""
    folder = Path(folder)
    meta = json.loads((folder / "meta.json").read_text())
    target = Path(library_root) / meta["relativePath"]
    if target.exists():
        raise SystemExit(f"{target} is already there")
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-R", str(folder), str(target)], check=True)
    print(target)


def spoken(directory, source):
    """mic.wav for a dictation: half a second of quiet, the recorded line, three seconds of quiet."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    speech = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(source), "-ac", "1", "-ar", str(landing.RATE),
                             "-f", "s16le", "-"], check=True, capture_output=True).stdout
    quiet = lambda seconds: bytes(int(seconds * landing.RATE) * 2)
    landing.write_wav(directory / "mic.wav", quiet(0.5) + speech + quiet(3))
    print(directory)


def document(directory, name="Team update.txt", text="Hi all,\n\n"):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_text(text)
    print(path)


def main():
    commands = {"library": library, "models": models, "settings": settings, "audio": audio, "spoken": spoken,
                "wait-notes": landing.wait_notes, "polish": polish, "adopt": adopt, "document": document,
                "timezone": landing.timezone_now}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        raise SystemExit(__doc__)
    commands[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    main()
