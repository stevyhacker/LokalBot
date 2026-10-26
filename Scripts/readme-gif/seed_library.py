#!/usr/bin/env python3
"""Seed the fictional library filmed for the README hero GIF.

One small story, so every shot agrees: a team settles launch pricing on a
call, after looking at a competitor's pricing page and a pricing sheet.
Searching "pricing" finds what was seen and what was said; the meeting's
decision cites the transcript line. Everything here is invented.

Reuses the on-disk writers in Scripts/seed_demo_library.py, so the layout
matches what the app and its UI test fixtures read.

Usage: python3 Scripts/readme-gif/seed_library.py <new-empty-dir>
"""
import importlib.util
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("seed", HERE.parent / "seed_demo_library.py")
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)

LAUNCH = "a1a1a1a1-0000-4000-8000-000000000001"
SALES = "a1a1a1a1-0000-4000-8000-000000000002"


def utc(dt):
    return dt.astimezone(timezone.utc)


def meetings(now):
    day = lambda days, hour, minute=0: utc((now - timedelta(days=days)).replace(
        hour=hour, minute=minute, second=0, microsecond=0))
    s = seed.seg
    return [
        seed.m(LAUNCH, "Launch planning", "Zoom", utc(now - timedelta(minutes=75)), 20, True, [
            s(0, 6, "me", "Last item: what do we charge at launch?"),
            s(6, 14, "them", "Customers keep comparing us to Cobalt at $18 a seat."),
            s(14, 24, "me", "Then we come in under them. Final pricing: $15 per seat, billed annually."),
            s(24, 32, "them", "Agreed. And a free plan for teams of up to three."),
            s(32, 39, "me", "I'll update the website by Friday."),
            s(39, 47, "them", "I'll brief sales before Monday's calls."),
        ], "## TL;DR\nLaunch at $15 per seat, billed annually, with a free plan for teams of up to three.\n\n"
           "## Decisions\n- $15 per seat, billed annually.\n- Free plan for teams of up to three.\n\n"
           "## Action items\n- [ ] Update the website by Friday — Me"),
        seed.m(SALES, "Sales sync", "Google Meet", day(1, 16), 25, True, [
            s(0, 9, "them", "Two prospects asked whether the plan includes onboarding."),
            s(9, 18, "me", "It does. Onboarding is free for every paid team."),
            s(18, 26, "them", "Great, I'll add that to the FAQ."),
        ], "## TL;DR\nOnboarding is free for every paid team.\n\n"
           "## Action items\n- [ ] Add onboarding to the FAQ — Them"),
        seed.m("a1a1a1a1-0000-4000-8000-000000000003", "Design review", "FaceTime", day(1, 11), 30, True, [
            s(0, 10, "me", "The new sign-up screens look great."),
            s(10, 22, "them", "Thanks. I'd still cut the second step; nobody fills it in."),
            s(22, 30, "me", "Agreed, cut it. Ship the shorter flow next week."),
        ], "## TL;DR\nThe sign-up flow loses its second step and ships next week.\n\n"
           "## Decisions\n- Cut the second sign-up step.\n\n"
           "## Action items\n- [ ] Ship the shorter sign-up flow — Them"),
        seed.m("a1a1a1a1-0000-4000-8000-000000000004", "Weekly standup", "Google Meet", day(2, 9, 30), 15, False, [
            s(0, 9, "me", "Docs are done. I'm on the launch email next."),
            s(9, 18, "them", "Mobile build is in review, should land tomorrow."),
        ], "## TL;DR\nDocs are done; the mobile build lands tomorrow."),
        seed.m("a1a1a1a1-0000-4000-8000-000000000005", "1:1 with Sam", "FaceTime", day(3, 15), 30, True, [
            s(0, 12, "them", "I'd like to own the launch announcement."),
            s(12, 22, "me", "It's yours. Draft it by Thursday and I'll review."),
        ], "## TL;DR\nSam owns the launch announcement; draft due Thursday.\n\n"
           "## Action items\n- [ ] Draft the launch announcement — Them"),
    ]


def seed_screens(root, now):
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    seed.ensure_activity_tables(cur)
    t = now.timestamp()
    for app, title, start, end in [
        ("Safari", "Plans & Pricing — Cobalt", 110, 95),
        ("Numbers", "Revenue model", 95, 78),
        ("Zoom", "Launch planning", 75, 55),
        ("Keynote", "Launch plan", 50, 25),
        ("Mail", "Inbox", 25, 10),
    ]:
        cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)",
                    (app, title, t - start * 60, t - end * 60))
    shots = [
        ("Safari", "Plans & Pricing — Cobalt", t - 100 * 60,
         "Cobalt Pro: $18 per seat per month, billed annually. Free for up to 2 users.", "web", (0, 122, 255)),
        ("Numbers", "Revenue model", t - 88 * 60,
         "Pricing options: $12, $15 or $18 per seat. $15 keeps margin above 70%.", "sheet", (52, 199, 89)),
        ("Keynote", "Launch plan", t - 38 * 60,
         "Launch checklist: new website, docs, announcement email.", "slide", (255, 159, 10)),
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


def seed_extras(root, now):
    os.makedirs(os.path.join(root, "journal"), exist_ok=True)
    with open(os.path.join(root, "journal", f"{now.strftime('%Y-%m-%d')}.md"), "w") as f:
        f.write("## Today at a glance\n\nPricing is settled: $15 per seat, billed annually, with a free plan "
                "for teams of up to three. The launch checklist is next.\n\n"
                "## Next\n\n- Update the website by Friday.\n- Finish the launch email.\n")
    os.makedirs(os.path.join(root, "chats"), exist_ok=True)
    chat = {
        "id": "b2b2b2b2-0000-4000-8000-000000000001",
        "title": "Launch pricing",
        "createdAt": seed.iso(utc(now - timedelta(minutes=20))),
        "updatedAt": seed.iso(utc(now - timedelta(minutes=19))),
        "messages": [
            {"id": "b2b2b2b2-0000-4000-8000-000000000101", "role": "user",
             "text": "What did we decide on pricing?"},
            {"id": "b2b2b2b2-0000-4000-8000-000000000102", "role": "assistant",
             "text": f"$15 per seat, billed annually [meeting:{LAUNCH}@0:14], with a free plan for teams "
                     f"of up to three [meeting:{LAUNCH}@0:24].",
             "activity": [
                 {"id": "b2b2b2b2-0000-4000-8000-000000000201", "tool": "search_meetings",
                  "icon": "magnifyingglass", "text": "searched meetings for “pricing”", "done": True},
                 {"id": "b2b2b2b2-0000-4000-8000-000000000202", "tool": "get_meeting",
                  "icon": "doc.text", "text": "read “Launch planning”", "done": True},
             ]},
        ],
    }
    with open(os.path.join(root, "chats", f"{chat['id']}.json"), "w") as f:
        json.dump(chat, f, indent=2)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    root = os.path.abspath(sys.argv[1])
    if os.path.exists(root) and os.listdir(root):
        raise SystemExit(f"Refusing to overwrite a populated directory: {root}")
    os.makedirs(os.path.join(root, "meetings"), exist_ok=True)
    with open(os.path.join(root, seed.OWNERSHIP_MARKER), "w") as f:
        f.write("LokalBot synthetic demo library (README GIF)\n")
    now = datetime.now().astimezone()
    for mm in meetings(now):
        folder = seed.write_meeting(root, mm)
        if mm["id"] == LAUNCH:
            seed.write_demo_audio(folder)
            seed.write_demo_audio(folder, track="system", tone=247, beat=2.7, level=1_400)
            path = os.path.join(folder, "transcript.json")
            with open(path) as f:
                transcript = json.load(f)
            transcript["speakerAliases"] = {"them": "Priya"}
            with open(path, "w") as f:
                json.dump(transcript, f, indent=2)
    seed_screens(root, now)
    seed_extras(root, now)
    print(root)


if __name__ == "__main__":
    main()
