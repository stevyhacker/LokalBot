#!/usr/bin/env python3
"""Plant a self-contained demo meeting library for screenshots / manual QA.

Mirrors StorageManager's on-disk layout (the same shape the Swift UI-test
fixture writes) so the app indexes it on launch. Dates are anchored to *now*
so the meeting list always reads TODAY / YESTERDAY, and the library spans
three weeks so search, chat, and the meeting list look lived-in.

Also seeds:
  - chats/<uuid>.json    plaintext conversations (ChatStore loads and migrates
                         them to .enc) — the latest one shows an answered
                         question with [meeting:ID@M:SS] citation markers
  - activity_blocks      several weekdays of day-timeline data

Usage:
    python3 Scripts/seed_demo_library.py [--reset] [--profile PROFILE] <storage-root>

``--profile studio`` seeds a small video studio's library instead: Apple-app,
non-coding examples for the website and README hero images, with a different
topic for each surface (see Docs/screenshot-kit.md).

By default the destination must be new or empty. ``--reset`` is accepted only
for a directory previously marked as a LokalBot demo library.

Point the app at <storage-root> via LOKALBOT_STORAGE_ROOT. See
Scripts/capture-screenshots.sh for the full capture flow.
"""
import argparse, json, math, os, random, re, shutil, sqlite3, struct, subprocess, sys, time, uuid, wave, zlib
from datetime import date, datetime, timezone, timedelta

ENGINE = "on-device demo"
OWNERSHIP_MARKER = ".lokalbot-demo-library"

# Stable ids so chat citations and capture scripts can reference meetings.
DESIGN_REVIEW = "11111111-1111-4111-8111-111111111111"
STANDUP = "22222222-2222-4222-8222-222222222222"
ROADMAP = "33333333-3333-4333-8333-333333333333"
NORTHWIND = "44444444-4444-4444-8444-444444444444"
# The studio profile's featured meetings, the ones with playable audio: the
# holiday shoot (website and README hero) and the podcast trailer review
# (README meeting section).
STUDIO_SHOOT = "55555555-5555-4555-8555-555555555555"
STUDIO_PODCAST = "66666666-6666-4666-8666-666666666666"


def mid(n):
    return f"{n:08d}-0000-4000-8000-{n:012d}"


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(s):
    s = int(s)
    return f"{s // 60:02d}:{s % 60:02d}"


def relpath(dt, slug):
    return f"meetings/{dt.year}/{dt.month:02d}/{dt.day:02d}-{slug}"


def seg(a, b, sp, t):
    return {"start": a, "end": b, "speaker": sp, "text": t}


def m(id, title, app, started, minutes, sys, transcript, summary):
    return dict(id=id, title=title, app=app, started=started,
                ended=started + timedelta(minutes=minutes), sys=sys,
                transcript=transcript, summary=summary)


def build(now):
    def ago(days, hour, minute=0):
        base = now - timedelta(days=days)
        return base.replace(hour=hour, minute=minute, second=0, microsecond=0)

    return [
        # ---- Today ----
        m(DESIGN_REVIEW, "Design review", "Zoom", now - timedelta(minutes=70), 25, True,
          [
              seg(0, 12, "me", "Let's lock the caching layer. I propose Redis for the pub-sub support."),
              seg(12, 26, "them", "Agreed on Redis. Open question: do we need cluster mode from day one?"),
              seg(26, 38, "me", "I'll draft the eviction-policy doc by Thursday."),
              seg(38, 52, "them", "Please benchmark failover latency before we commit to a cluster."),
              seg(52, 66, "me", "Fair. I'll borrow the load harness from the search team for that."),
              seg(66, 82, "them", "While we're here: the session store. Does it move to Redis too, or stay in Postgres?"),
              seg(82, 96, "me", "Stay in Postgres for now. One migration at a time."),
              seg(96, 110, "them", "Okay. TTLs: product wants recaps cached for a week, search results for an hour."),
              seg(110, 124, "me", "That maps to two keyspaces with separate eviction. I'll put it in the doc."),
              seg(124, 138, "them", "Ship it. Let's reconvene once the failover numbers are in."),
          ],
          "## TL;DR\nThe team chose Redis for caching and deferred cluster mode pending a failover benchmark.\n\n## Decisions\n- Adopt Redis for the caching layer (pub-sub support won the comparison).\n- Session store stays in Postgres for now; one migration at a time.\n\n## Action items\n- [ ] Draft the eviction-policy document by Thursday — Me\n- [ ] Benchmark failover latency before committing to cluster mode — Them\n\n## Open questions\n- Do we need Redis cluster mode at launch, or can it wait?"),
        m(STANDUP, "Engineering standup", "Slack", now - timedelta(minutes=150), 15, False,
          [
              seg(0, 9, "me", "Quick standup. I'm picking up the Postgres migration today."),
              seg(9, 20, "me", "Blocker on the index rebuild — needs a review from the data team."),
              seg(20, 32, "me", "Also scheduling the Redis failover benchmark for Thursday morning."),
          ],
          "## TL;DR\nPostgres migration kicked off; the index rebuild is blocked on data-team review.\n\n## Action items\n- [ ] Unblock the index rebuild with the data team — Me\n- [ ] Run the Redis failover benchmark Thursday morning — Me"),

        # ---- Yesterday ----
        m(ROADMAP, "Q3 roadmap planning", "Google Meet", ago(1, 9, 57), 30, False,
          [
              seg(0, 20, "me", "We need to lock the Q3 roadmap. Onboarding is the top priority for new accounts."),
              seg(20, 42, "them", "Second is reliability — the alerting backlog has grown three quarters running."),
              seg(42, 60, "me", "Let's commit onboarding first, reliability second."),
          ],
          "## TL;DR\nQ3 priorities are onboarding (top) and reliability (alerting backlog).\n\n## Decisions\n- Onboarding ranks above reliability for Q3.\n\n## Action items\n- [ ] Scope the onboarding revamp epic — Me"),

        # ---- Earlier this week ----
        m(NORTHWIND, "Customer call - Northwind", "Microsoft Teams", ago(2, 9, 47), 40, True,
          [
              seg(0, 15, "them", "Our team loves the export feature, but we need SSO before we roll out company-wide."),
              seg(15, 30, "me", "SSO is on the Q3 roadmap. I'll send you the security overview this week."),
              seg(30, 45, "them", "Great. Pricing for 250 seats would help us get budget approved."),
          ],
          "## TL;DR\nNorthwind is happy with exports; SSO is the blocker for a company-wide rollout.\n\n## Decisions\n- Send the security overview and a 250-seat quote this week.\n\n## Action items\n- [ ] Email the SSO security overview — Me\n- [ ] Prepare a 250-seat pricing quote — Me\n\n## Open questions\n- Target rollout date once SSO ships?"),
        m(mid(5), "Design system sync", "Zoom", ago(2, 14, 0), 30, True,
          [
              seg(0, 16, "me", "The new list rows shipped. Remaining gap is the empty states."),
              seg(16, 34, "them", "I'll deliver empty-state illustrations for Meetings and Ask by Friday."),
              seg(34, 50, "me", "Then we can close the redesign epic next sprint."),
          ],
          "## TL;DR\nRedesign is nearly done; empty-state illustrations land Friday, epic closes next sprint.\n\n## Action items\n- [ ] Empty-state illustrations for Meetings and Ask — Them"),
        m(mid(6), "Sprint planning", "Google Meet", ago(3, 10, 0), 45, False,
          [
              seg(0, 18, "me", "Committing three things this sprint: eviction-policy doc, the failover benchmark, and onboarding scoping."),
              seg(18, 40, "them", "The Redis failover benchmark needs the load harness — search team said Thursday works."),
              seg(40, 58, "me", "Booked. Stretch goal is the alerting backlog triage."),
          ],
          "## TL;DR\nSprint committed: eviction-policy doc, Redis failover benchmark (Thursday, borrowed load harness), onboarding scoping. Alerting triage is stretch.\n\n## Action items\n- [ ] Eviction-policy doc — Me\n- [ ] Failover benchmark with the search team's harness — Me"),
        m(mid(7), "1:1 with Maya", "FaceTime", ago(3, 16, 0), 30, True,
          [
              seg(0, 20, "them", "The migration work is going well, but I want more design review exposure."),
              seg(20, 38, "me", "Let's rotate you into the Thursday design reviews starting next week."),
          ],
          "## TL;DR\nMaya joins the Thursday design-review rotation starting next week.\n\n## Action items\n- [ ] Add Maya to the design-review invite — Me"),
        m(mid(8), "Search outage postmortem", "Zoom", ago(4, 11, 30), 35, True,
          [
              seg(0, 18, "me", "Timeline: deploy at 9:12, stale cache served until 9:41, search results were empty for 29 minutes."),
              seg(18, 36, "them", "Root cause was the cache key not including the index version."),
              seg(36, 54, "me", "Fix is versioned keys — and this feeds straight into the Redis eviction-policy doc."),
          ],
          "## TL;DR\n29-minute search outage from a stale cache after deploy; fix is versioned cache keys.\n\n## Decisions\n- Cache keys carry the index version from now on.\n\n## Action items\n- [ ] Fold versioned keys into the eviction-policy doc — Me"),
        m(mid(9), "iOS hiring debrief", "Google Meet", ago(5, 15, 0), 25, False,
          [
              seg(0, 16, "me", "Strong on architecture, lighter on testing discipline. I'm a hire."),
              seg(16, 32, "them", "Same read. Let's move to references this week."),
          ],
          "## TL;DR\nBoth interviewers are a hire on the iOS candidate; references this week.\n\n## Action items\n- [ ] Request references — Them"),

        # ---- Last week ----
        m(mid(10), "Acme integration kickoff", "Microsoft Teams", ago(7, 10, 0), 45, True,
          [
              seg(0, 20, "them", "We want the meeting summaries flowing into our CRM within the quarter."),
              seg(20, 40, "me", "The export API covers it. I'll share the schema and a sandbox key today."),
          ],
          "## TL;DR\nAcme integration kicked off; export API covers the CRM flow, schema and sandbox key shared today.\n\n## Action items\n- [ ] Send export schema + sandbox key — Me"),
        m(mid(11), "API deprecation plan", "Zoom", ago(8, 13, 30), 30, False,
          [
              seg(0, 18, "me", "v1 export endpoints sunset at the end of Q3. Six customers still call them."),
              seg(18, 36, "them", "I'll draft the migration email and we give ninety days' notice."),
          ],
          "## TL;DR\nv1 export endpoints sunset end of Q3 with 90 days' notice; six customers to migrate.\n\n## Action items\n- [ ] Draft the migration notice — Them"),
        m(mid(12), "Weekly all-hands", "Zoom", ago(9, 9, 0), 30, False,
          [
              seg(0, 20, "me", "Headline: onboarding conversion is up four points since the new first-run flow."),
              seg(20, 40, "them", "Reminder that Q3 planning docs are due to leadership Friday."),
          ],
          "## TL;DR\nOnboarding conversion +4pts since the new first-run flow; Q3 planning docs due Friday."),
        m(mid(13), "Onboarding revamp workshop", "Google Meet", ago(10, 14, 0), 60, False,
          [
              seg(0, 22, "me", "Goal: first meeting captured within ten minutes of install."),
              seg(22, 44, "them", "Biggest drop-off is the permissions step — we should explain the mic prompt before it fires."),
              seg(44, 62, "me", "Agreed. Pre-prompt explainer screen, then the system dialog."),
          ],
          "## TL;DR\nOnboarding target: first captured meeting within 10 minutes of install; pre-prompt explainer added before the mic dialog.\n\n## Decisions\n- Explain the mic prompt before the system dialog fires."),
        m(mid(14), "1:1 with Maya", "FaceTime", ago(11, 16, 0), 30, True,
          [
              seg(0, 18, "them", "Index rebuild plan is ready — I'd like the data team review booked."),
              seg(18, 34, "me", "I'll book it for early next week and unblock the migration."),
          ],
          "## TL;DR\nIndex rebuild plan ready; data-team review to be booked early next week.\n\n## Action items\n- [ ] Book the data-team review — Me"),

        # ---- Two-three weeks back ----
        m(mid(15), "SSO security review", "Microsoft Teams", ago(14, 11, 0), 40, True,
          [
              seg(0, 20, "me", "Scope for Q3 SSO: SAML and OIDC, SCIM provisioning explicitly out."),
              seg(20, 40, "them", "Then the security overview doc needs the session-lifetime table updated before it goes to customers."),
          ],
          "## TL;DR\nSSO scope locked: SAML + OIDC in Q3, SCIM out. Security overview needs the session-lifetime table updated.\n\n## Decisions\n- SAML and OIDC in scope for Q3; SCIM provisioning out.\n\n## Action items\n- [ ] Update the session-lifetime table in the security overview — Me"),
        m(mid(16), "Budget review Q3", "Google Meet", ago(15, 10, 30), 30, False,
          [
              seg(0, 18, "them", "Infra spend is flat; the only new line is the load-testing cluster."),
              seg(18, 34, "me", "Approved. Everything else rolls over unchanged."),
          ],
          "## TL;DR\nQ3 budget approved; only new line is the load-testing cluster."),
        m(mid(17), "Launch retro - v0.9", "Zoom", ago(16, 15, 0), 45, False,
          [
              seg(0, 20, "me", "What went well: zero rollbacks, docs ready on day one."),
              seg(20, 42, "them", "What didn't: the announcement went out before the CDN cache had the new build."),
              seg(42, 60, "me", "Next launch we gate the announcement on a checksum check against the CDN."),
          ],
          "## TL;DR\nv0.9 shipped clean; next launch the announcement is gated on a CDN checksum check.\n\n## Decisions\n- Gate launch announcements on the CDN serving the new build."),
        m(mid(18), "Sales demo - Globex", "Webex", ago(18, 13, 0), 30, True,
          [
              seg(0, 16, "them", "The on-device angle is why we're here — legal blocked every cloud notetaker."),
              seg(16, 32, "me", "Then you'll want the verification walkthrough — I'll run it with your security team next week."),
          ],
          "## TL;DR\nGlobex is in because cloud notetakers are blocked by legal; verification walkthrough with their security team next week.\n\n## Action items\n- [ ] Schedule the verification walkthrough — Me"),
    ]


def write_meeting(root, mm):
    rel = relpath(mm["started"], mm["title"].lower().replace(" ", "-"))
    folder = os.path.join(root, rel)
    os.makedirs(folder, exist_ok=True)
    meta = {"appName": mm["app"], "endedAt": iso(mm["ended"]), "hasSystemTrack": mm["sys"],
            "id": mm["id"], "relativePath": rel, "startedAt": iso(mm["started"]), "title": mm["title"]}
    with open(os.path.join(folder, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    tj = {"engine": ENGINE, "segments": mm["transcript"]}
    with open(os.path.join(folder, "transcript.json"), "w") as f:
        json.dump(tj, f, indent=2)
    md = "\n\n".join(f"**[{stamp(s['start'])}] {s['speaker'].capitalize()}:** {s['text']}" for s in mm["transcript"])
    with open(os.path.join(folder, "transcript.md"), "w") as f:
        f.write(md)
    with open(os.path.join(folder, "summary.md"), "w") as f:
        f.write(mm["summary"])
    with open(os.path.join(folder, "outcomes.json"), "w") as f:
        json.dump(demo_outcomes(mm), f, indent=2)
    if mm["id"] == DESIGN_REVIEW:
        write_demo_audio(folder)
    return folder


def write_demo_audio(folder, track="mic", tone=196, beat=3.4, level=1_600):
    """Add a short, decodable source track for the detail-player happy path.
    A second call with track="system" makes the header read Mic + system."""
    wav_path = os.path.join(folder, f"demo-{track}.wav")
    m4a_path = os.path.join(folder, f"{track}.m4a")
    sample_rate = 16_000
    duration = 140
    with wave.open(wav_path, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(sample_rate)
        frames = bytearray()
        for index in range(sample_rate * duration):
            seconds = index / sample_rate
            pulse = 0.25 + 0.75 * abs(math.sin(seconds * math.pi / beat))
            sample = int(level * pulse * math.sin(2 * math.pi * tone * seconds))
            frames.extend(struct.pack("<h", sample))
        audio.writeframes(frames)
    try:
        subprocess.run(
            ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", wav_path, m4a_path],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
    finally:
        if os.path.exists(wav_path):
            os.remove(wav_path)


def demo_outcomes(mm):
    """Derive grounded workflow fixtures from the demo's authored summary.

    These are deterministic screenshot/test records, not a second production
    extractor. Every visible action/decision points back to a real transcript
    segment so the redesigned evidence controls can be exercised end to end.
    """
    sections = {"actionItems": [], "decisionRecords": [], "openQuestions": []}
    active = None
    headings = {
        "## Action items": "actionItems",
        "## Decisions": "decisionRecords",
        "## Open questions": "openQuestions",
    }
    for raw in mm["summary"].splitlines():
        line = raw.strip()
        if line.startswith("## "):
            active = headings.get(line)
            continue
        if active and line.startswith("-"):
            text = re.sub(r"^-\s*(?:\[.\]\s*)?", "", line).strip()
            if active == "openQuestions":
                sections[active].append(text)
                continue
            owner = None
            if active == "actionItems":
                owner_match = re.search(r"\s+[—-]\s+(Me|Them)$", text, re.I)
                paren_match = re.search(r"\s+\((Me|Them)\)\.?$", text, re.I)
                match = owner_match or paren_match
                if match:
                    owner = match.group(1).capitalize()
                    text = text[:match.start()].rstrip(" .")
            segment_index = best_segment(text, mm["transcript"])
            segment = mm["transcript"][segment_index]
            citation = {
                "meetingID": mm["id"],
                "segmentID": f"segment-{segment_index:04d}-{round(segment['start'] * 1000):010d}-{round(segment['end'] * 1000):010d}",
                "start": segment["start"],
                "end": segment["end"],
                "speaker": segment["speaker"],
                "excerpt": segment["text"][:220],
            }
            prefix = "action" if active == "actionItems" else "decision"
            record = {
                "id": f"demo-{prefix}-{mm['id'][:8]}-{len(sections[active]) + 1}",
                "schemaVersion": 2,
                "text": text,
                "citations": [citation],
            }
            if active == "actionItems":
                record.update({
                    "owner": owner,
                    "isForUser": owner == "Me",
                })
            sections[active].append(record)
    return {"schemaVersion": 2, **sections}


def best_segment(text, segments):
    words = set(re.findall(r"[a-z0-9]+", text.lower()))
    scored = []
    for index, segment in enumerate(segments):
        candidate = set(re.findall(r"[a-z0-9]+", segment["text"].lower()))
        scored.append((len(words & candidate), index))
    return max(scored, default=(0, 0))[1]


def seed_chats(root, now):
    """Plaintext Conversation JSON, one file per chat. ChatStore's loader reads
    legacy .json files directly (and migrates them to .enc on first launch), so
    the chat section opens on the latest seeded conversation with citations."""
    chats = os.path.join(root, "chats")
    os.makedirs(chats, exist_ok=True)

    def msg(mid_, role, text, activity=None):
        out = {"id": mid_, "role": role, "text": text}
        if activity:
            out["activity"] = activity
        return out

    def act(aid, tool, icon, text):
        return {"id": aid, "tool": tool, "icon": icon, "text": text, "done": True}

    redis = {
        "id": "aaaaaaa1-0000-4000-8000-000000000001",
        "title": "Redis decision",
        "createdAt": iso(now - timedelta(minutes=9)),
        "updatedAt": iso(now - timedelta(minutes=2)),
        "messages": [
            msg("aaaaaaa1-0000-4000-8000-000000000101", "user",
                "What did we decide about Redis last week?"),
            msg("aaaaaaa1-0000-4000-8000-000000000102", "assistant",
                "You settled it in the Design review: adopt Redis for the caching layer, "
                f"with pub-sub support as the deciding factor [meeting:{DESIGN_REVIEW}@0:12]. "
                f"Cluster mode was deferred until failover latency is benchmarked [meeting:{DESIGN_REVIEW}@0:38].\n\n"
                "Two follow-ups came out of it: you are drafting the eviction-policy document by Thursday, "
                f"and the failover benchmark is booked with the search team's load harness [meeting:{mid(6)}].",
                activity=[
                    act("aaaaaaa1-0000-4000-8000-000000000201", "search_meetings",
                        "magnifyingglass", "searched meetings for “Redis”"),
                    act("aaaaaaa1-0000-4000-8000-000000000202", "get_meeting",
                        "doc.text", "read “Design review”"),
                ]),
        ],
    }
    sso = {
        "id": "aaaaaaa2-0000-4000-8000-000000000002",
        "title": "Northwind rollout blocker",
        "createdAt": iso(now - timedelta(days=1, hours=2)),
        "updatedAt": iso(now - timedelta(days=1, hours=2)),
        "messages": [
            msg("aaaaaaa2-0000-4000-8000-000000000101", "user",
                "What is blocking the Northwind rollout?"),
            msg("aaaaaaa2-0000-4000-8000-000000000102", "assistant",
                f"SSO. Northwind loves the export feature but needs SSO before a company-wide rollout [meeting:{NORTHWIND}@0:00]. "
                "You owe them the security overview and a 250-seat quote this week. "
                f"SSO scope itself is already locked: SAML and OIDC in Q3, SCIM out [meeting:{mid(15)}@0:00].",
                activity=[
                    act("aaaaaaa2-0000-4000-8000-000000000201", "search_meetings",
                        "magnifyingglass", "searched meetings for “Northwind”"),
                    act("aaaaaaa2-0000-4000-8000-000000000202", "get_meeting",
                        "doc.text", "read “Customer call - Northwind”"),
                ]),
        ],
    }
    for convo in (redis, sso):
        with open(os.path.join(chats, f"{convo['id']}.json"), "w") as f:
            json.dump(convo, f, indent=2)


def seed_journal(root):
    """Give the Timeline inspector a useful, already-generated day digest.

    The screenshot fixture should demonstrate the finished local-memory flow,
    not a mostly empty pane with a Generate button. Keep the copy concise so it
    remains readable in the balanced marketing-capture layout.
    """
    journal = os.path.join(root, "journal")
    os.makedirs(journal, exist_ok=True)
    day = datetime.now().strftime("%Y-%m-%d")
    digest = """## Today at a glance

Redis stays the caching layer; cluster mode waits for Thursday's failover benchmark. The Postgres migration continues after the data-team review.

## Next

- Draft the eviction-policy document.
- Run the failover benchmark with the search team's load harness.
- Unblock the Postgres index rebuild.
"""
    with open(os.path.join(journal, f"{day}.md"), "w") as f:
        f.write(digest)


def write_demo_png(path, accent, variant):
    """Draw a small, dependency-free work-screen fixture for Context Rewind.

    The files are only consumed by the UI-test host. Production screenshots are
    encrypted by ScreenshotService; the host has an explicit capture-only seam
    for these deterministic plaintext fixtures.
    """
    width, height = 960, 600
    pixels = [bytearray((15, 20, 29) * width) for _ in range(height)]

    def rect(x, y, w, h, color):
        x0, x1 = max(0, x), min(width, x + w)
        y0, y1 = max(0, y), min(height, y + h)
        row = bytes(color) * max(0, x1 - x0)
        for py in range(y0, y1):
            pixels[py][x0 * 3:x1 * 3] = row

    def dot(cx, cy, radius, color):
        r2 = radius * radius
        for py in range(max(0, cy - radius), min(height, cy + radius + 1)):
            for px in range(max(0, cx - radius), min(width, cx + radius + 1)):
                if (px - cx) ** 2 + (py - cy) ** 2 <= r2:
                    start = px * 3
                    pixels[py][start:start + 3] = bytes(color)

    # Native-Mac window chrome and a distinct but non-branded work surface.
    rect(0, 0, width, 54, (27, 34, 46))
    dot(25, 27, 7, (255, 95, 87))
    dot(48, 27, 7, (255, 189, 46))
    dot(71, 27, 7, (40, 201, 64))
    rect(0, 54, 196, height - 54, (20, 27, 38))
    rect(24, 84, 148, 12, (78, 91, 111))
    rect(24, 118, 116, 10, (54, 66, 84))
    rect(24, 146, 132, 10, accent)
    rect(24, 174, 92, 10, (54, 66, 84))
    rect(220, 78, 706, 44, (25, 33, 45))
    rect(242, 94, 250 + variant * 34, 11, (110, 126, 148))

    if variant % 3 == 0:  # editor-like panes
        rect(220, 140, 150, 430, (18, 25, 35))
        for index in range(11):
            shade = accent if index in (2, 7) else (65, 77, 96)
            rect(398, 154 + index * 32, 410 - (index % 4) * 54, 11, shade)
            rect(378, 154 + index * 32, 8, 11, (44, 55, 71))
    elif variant % 3 == 1:  # browser / document cards
        rect(242, 148, 660, 90, (27, 36, 49))
        rect(268, 172, 360, 18, accent)
        rect(268, 204, 520, 10, (83, 97, 116))
        for index in range(3):
            rect(242, 262 + index * 96, 660, 72, (24, 32, 44))
            rect(266, 281 + index * 96, 132, 12, accent if index == 1 else (93, 107, 127))
            rect(266, 305 + index * 96, 490 - index * 55, 9, (68, 81, 100))
    else:  # chat / collaboration rows
        for index in range(5):
            dot(270, 174 + index * 76, 18, accent if index % 2 == 0 else (91, 104, 123))
            rect(308, 158 + index * 76, 180, 12, (111, 126, 146))
            rect(308, 181 + index * 76, 470 - index * 32, 10, (62, 75, 94))
            rect(308, 201 + index * 76, 330 + index * 18, 10, (62, 75, 94))

    write_rgb_png(path, pixels, width, height)


def write_rgb_png(path, pixels, width, height):
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as handle:
        handle.write(png)


def ensure_activity_tables(cur):
    cur.execute("""CREATE TABLE IF NOT EXISTS activity_blocks (id INTEGER PRIMARY KEY AUTOINCREMENT,
        app TEXT NOT NULL, title TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);""")
    cur.executescript("""
        CREATE TABLE IF NOT EXISTS screenshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, path TEXT NOT NULL, app TEXT NOT NULL,
            window_title TEXT NOT NULL DEFAULT '',
            capture_trigger TEXT NOT NULL DEFAULT 'interval',
            perceptual_hash TEXT NOT NULL DEFAULT '',
            similarity_group INTEGER NOT NULL DEFAULT 0,
            source_url TEXT NOT NULL DEFAULT '',
            document_name TEXT NOT NULL DEFAULT '',
            meeting_id TEXT NOT NULL DEFAULT '',
            privacy_redactions INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS screen_bookmarks (
            snapshot_id INTEGER PRIMARY KEY,
            note TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(
            text, window_title, ts UNINDEXED, app UNINDEXED,
            text_source UNINDEXED, snapshot_id UNINDEXED,
            tokenize='unicode61 remove_diacritics 2');
    """)


def seed_activity(root):
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    ensure_activity_tables(cur)
    days = {
        0: [("Xcode", "TimelineView.swift", 9 * 60, 10 * 60 + 30),
            ("Safari", "Pull request #42 - caching", 10 * 60 + 30, 11 * 60 + 15),
            ("Slack", "#engineering", 11 * 60 + 15, 11 * 60 + 40),
            ("Zoom", "Design review", 11 * 60 + 40, 12 * 60 + 5),
            ("Notion", "Q3 planning doc", 13 * 60, 14 * 60 + 20),
            ("Terminal", "lokalbot build", 14 * 60 + 20, 15 * 60)],
        1: [("Notion", "Onboarding revamp scoping", 9 * 60, 10 * 60 + 15),
            ("Google Meet", "Q3 roadmap planning", 10 * 60 + 15, 10 * 60 + 45),
            ("Xcode", "EvictionPolicy.swift", 11 * 60, 12 * 60 + 30),
            ("Safari", "Redis failover docs", 13 * 60 + 30, 14 * 60 + 45),
            ("Slack", "#incidents", 14 * 60 + 45, 15 * 60 + 10)],
        2: [("Microsoft Teams", "Customer call - Northwind", 9 * 60 + 45, 10 * 60 + 25),
            ("Pages", "SSO security overview", 10 * 60 + 30, 12 * 60),
            ("Zoom", "Design system sync", 14 * 60, 14 * 60 + 30),
            ("Figma", "Empty states", 14 * 60 + 30, 16 * 60)],
        3: [("Google Meet", "Sprint planning", 10 * 60, 10 * 60 + 45),
            ("Xcode", "SearchIndex.swift", 11 * 60, 13 * 60),
            ("FaceTime", "1:1 with Maya", 16 * 60, 16 * 60 + 30)],
        4: [("Zoom", "Incident review", 11 * 60 + 30, 12 * 60 + 5),
            ("Terminal", "load harness", 13 * 60, 14 * 60 + 30),
            ("Safari", "postmortem template", 14 * 60 + 30, 15 * 60)],
    }
    for offset, rows in days.items():
        midnight = time.mktime((datetime.now() - timedelta(days=offset))
                               .replace(hour=0, minute=0, second=0, microsecond=0).timetuple())
        for app, title, a, b in rows:
            cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)",
                        (app, title, midnight + a * 60, midnight + b * 60))

    today = time.mktime(datetime.now().replace(hour=0, minute=0, second=0,
                                               microsecond=0).timetuple())
    shot_dir = os.path.join(root, "activity", datetime.now().strftime("%Y-%m-%d"), "demo")
    os.makedirs(shot_dir, exist_ok=True)
    shots = [
        ("Xcode", "TimelineView.swift", 9 * 60 + 24,
         "Context rewind keeps the selected screen moment attached to the workday timeline.",
         (74, 128, 232)),
        ("Safari", "Pull request #42 — caching", 10 * 60 + 47,
         "Redis caching layer review. Benchmark failover latency before enabling cluster mode.",
         (242, 108, 144)),
        ("Slack", "#engineering", 11 * 60 + 26,
         "Redis failover benchmark is booked for Thursday with the search team's load harness.",
         (69, 196, 174)),
        ("Notion", "Q3 planning doc", 13 * 60 + 38,
         "Postgres migration timeline, Q3 priorities, onboarding first and reliability second.",
         (88, 185, 156)),
        ("Terminal", "lokalbot build", 14 * 60 + 34,
         "Build succeeded. Local model, screen memory, dictation, and cotyping checks passed.",
         (203, 151, 88)),
    ]
    snapshot_ids = []
    for index, (app, title, minute, text, accent) in enumerate(shots, start=1):
        path = os.path.join(shot_dir, f"scene-{index}.png")
        write_demo_png(path, accent, index - 1)
        timestamp = today + minute * 60
        cur.execute("""
            INSERT INTO screenshots (
                ts, path, app, window_title, capture_trigger, perceptual_hash,
                similarity_group, source_url, document_name, meeting_id,
                privacy_redactions)
            VALUES (?, ?, ?, ?, ?, '', ?, '', ?, '', 0)
            """, (timestamp, path, app, title, "window_change", index, title))
        snapshot_id = cur.lastrowid
        snapshot_ids.append(snapshot_id)
        cur.execute("""
            INSERT INTO ocr_fts (
                text, window_title, ts, app, text_source, snapshot_id)
            VALUES (?, ?, ?, ?, 'accessibility', ?)
            """, (text, title, timestamp, app, snapshot_id))
    cur.execute("INSERT INTO screen_bookmarks (snapshot_id, note, created_at) VALUES (?, ?, ?)",
                (snapshot_ids[2], "Redis benchmark decision", today + 12 * 60 * 60))
    con.commit()
    con.close()


FULL_DAY_BLOCKS = [  # (app, title, start minute, end minute) on the seeded day
    ("Xcode", "EvictionPolicy.swift", 8 * 60 + 30, 10 * 60 + 40),
    ("Google Chrome", "Pull request #42 - caching layer", 10 * 60 + 40, 11 * 60),
    ("Microsoft Teams", "Design review", 11 * 60, 11 * 60 + 6),
    ("Slack", "#engineering", 11 * 60 + 6, 11 * 60 + 45),
    ("Private", "", 11 * 60 + 45, 12 * 60 + 20),
    ("Notion", "Q3 planning doc", 13 * 60, 14 * 60 + 10),
    ("Terminal", "load harness", 14 * 60 + 10, 15 * 60),
    ("Microsoft Teams", "Sprint planning", 15 * 60, 15 * 60 + 4),
    ("Xcode", "SearchIndex.swift", 15 * 60 + 4, 17 * 60 + 30),
    ("Google Chrome", "Redis failover docs", 17 * 60 + 30, 18 * 60 + 30),
]

FULL_DAY_TEXT = {
    "Xcode": "func evict(olderThan cutoff: Date) LRU eviction for the Redis cache; 12 tests passed",
    "Google Chrome": "Review: approve after benchmarking failover latency. Merge blocked on cluster mode decision.",
    "Slack": "Redis failover benchmark is booked for Thursday with the search team's load harness.",
    "Notion": "Postgres migration timeline, Q3 priorities, onboarding first and reliability second.",
    "Terminal": "failover p95 1.8s to 0.9s after connection pool change; benchmark complete",
}

# (start seconds, speaker, text). The lines are SyntheticModelPrompts'
# standupTranscript() lines; the start times match the golden transcripts in
# LokalBotTests/Fixtures/day-in-the-life/golden-transcripts.
DESIGN_REVIEW_LINES = [
    (0, "me", "Let's lock the caching layer. I propose Redis for the pub-sub support."),
    (7, "them", "Agreed on Redis. Open question: do we need cluster mode from day one?"),
    (16, "me", "I'll draft the eviction-policy doc by Thursday."),
    (22, "them", "Please benchmark failover latency before we commit to a cluster."),
    (30, "me", "Fair. I'll borrow the load harness from the search team for that."),
]

# Sprint planning merges two 2-minute sources; one line falls in each.
SPRINT_LINES = [
    (0, "them", "Sprint goal is the search index rebuild."),
    (121, "me", "I'll pair on the tombstone cleanup tomorrow."),
]


def say_track(lines, speaker, path):
    """Synthesize one speaker's lines at their start times (silence between) into
    an m4a. Both tracks of a meeting run to the same length, like a recording."""
    rate = 22_050
    samples = bytearray()
    for start, who, text in lines:
        if who != speaker:
            continue
        clip = path + ".line.wav"
        subprocess.run(["/usr/bin/say", f"--data-format=LEI16@{rate}", "-o", clip, text], check=True)
        with wave.open(clip) as reader:
            speech = reader.readframes(reader.getnframes())
        os.remove(clip)
        offset = int(start * rate) * 2
        samples.extend(bytes(max(0, offset - len(samples))))
        samples[offset:offset + len(speech)] = speech
    length = int((max(start for start, _, _ in lines) + 8) * rate) * 2
    samples.extend(bytes(max(0, length - len(samples))))
    track = path + ".wav"
    with wave.open(track, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(bytes(samples))
    subprocess.run(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", track, path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(track)


def seed_full_day(root, day):
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    ensure_activity_tables(cur)
    midnight = time.mktime(day.timetuple())
    for app, title, start, end in FULL_DAY_BLOCKS:
        cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)",
                    (app, title, midnight + start * 60, midnight + end * 60))
        text = FULL_DAY_TEXT.get(app)
        if text and end - start >= 30:
            for offset in range(3):
                ts = midnight + (start + 5 + offset * (end - start - 10) / 3) * 60
                cur.execute("""INSERT INTO screenshots (ts, path, app, window_title, capture_trigger,
                               perceptual_hash, similarity_group, source_url, document_name, meeting_id,
                               privacy_redactions) VALUES (?, '', ?, ?, 'window_change', '', 0, '', ?, '', 0)""",
                            (ts, app, title, title))
                cur.execute("""INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id)
                               VALUES (?, ?, ?, ?, 'accessibility', ?)""", (text, title, ts, app, cur.lastrowid))
    con.commit()
    con.close()
    for slug, title, hour, minutes, lines, merged in [
            ("design-review", "Design review", 11, 6, DESIGN_REVIEW_LINES, False),
            ("sprint-planning", "Sprint planning", 15, 4, SPRINT_LINES, True)]:
        # Local wall-clock time, like the activity blocks.
        started = datetime(day.year, day.month, day.day, hour, 0).astimezone(timezone.utc)
        rel = relpath(started, slug)
        folder = os.path.join(root, rel)
        os.makedirs(folder, exist_ok=True)
        meta = {"appName": "Microsoft Teams", "endedAt": iso(started + timedelta(minutes=minutes)),
                "hasSystemTrack": True, "id": str(uuid.uuid5(uuid.NAMESPACE_URL, slug)),
                "relativePath": rel, "startedAt": iso(started), "title": title}
        with open(os.path.join(folder, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)
        say_track(lines, "me", os.path.join(folder, "mic.m4a"))
        say_track(lines, "them", os.path.join(folder, "system.m4a"))
        if merged:
            half = minutes * 30
            sources = [{"id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{slug}-{part}")),
                        "title": f"{title} (part {part})",
                        "startedAt": iso(started + timedelta(seconds=half * (part - 1))),
                        "duration": half, "hasAudio": True, "hasTranscript": False} for part in (1, 2)]
            with open(os.path.join(folder, "merge-manifest.json"), "w") as f:
                json.dump({"version": 2, "sources": sources}, f, indent=2, sort_keys=True)


def seed_large(root):
    rng = random.Random(7)
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    ensure_activity_tables(cur)
    apps = ["Xcode", "Google Chrome", "Slack", "Terminal", "Notion", "Microsoft Teams", "Figma", "Private"]
    now = time.time()
    blocks = []
    for index in range(50_000):
        start = now - 180 * 86400 + index * (180 * 86400 / 50_000)
        blocks.append((rng.choice(apps), f"Window {index % 97}", start, start + rng.randint(60, 240)))
    cur.executemany("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)", blocks)
    for index in range(20_000):
        ts = now - 180 * 86400 + index * (180 * 86400 / 20_000)
        app = rng.choice(apps[:-1])
        cur.execute("""INSERT INTO screenshots (ts, path, app, window_title, capture_trigger, perceptual_hash,
                       similarity_group, source_url, document_name, meeting_id, privacy_redactions)
                       VALUES (?, '', ?, 'Window', 'interval', '', 0, '', '', '', 0)""", (ts, app))
        cur.execute("INSERT INTO ocr_fts (text, window_title, ts, app, text_source, snapshot_id) VALUES (?, ?, ?, ?, 'accessibility', ?)",
                    (f"synthetic screen text {index}", "Window", ts, app, cur.lastrowid))
    con.commit()
    con.close()
    base = datetime.now(timezone.utc)
    for index in range(200):
        started = base - timedelta(days=180 * index / 200, hours=rng.randint(0, 8))
        write_meeting(root, m(str(uuid.UUID(int=rng.getrandbits(128), version=4)), f"Meeting {index}", "Zoom",
                              started, 30, True,
                              [seg(0, 10, "me", f"Synthetic topic {index} update."), seg(10, 20, "them", "Noted.")],
                              "## TL;DR\nSynthetic meeting.\n"))


def build_studio(now):
    """A small video studio's meetings: FaceTime calls and Apple apps instead of
    engineering work. Each captured surface gets its own topic: the holiday
    shoot (website meeting and README hero), the podcast trailer (README
    meeting section), the Globex demo presentation (the website's "demo
    presentation" search), the Mac refresh ("MacBook" search) and delivery
    captions ("captions" search). Keep "MacBook", "captions" and "demo
    presentation" out of other meetings so those searches return the intended
    rows."""
    def ago(days, hour, minute=0):
        base = now - timedelta(days=days)
        return base.replace(hour=hour, minute=minute, second=0, microsecond=0)

    return [
        # ---- Today ----
        m(STUDIO_SHOOT, "Holiday shoot planning", "FaceTime", now - timedelta(minutes=60), 25, True,
          [
              seg(0, 12, "me", "Let's lock the holiday shoot. Everything gets shot on iPhone this year."),
              seg(12, 26, "them", "Agreed on iPhone for stills and video. Open question: gimbal or handheld?"),
              seg(26, 38, "me", "I'll book the photo studio for Thursday morning."),
              seg(38, 52, "them", "Please send the Freeform shot list to the crew tonight."),
              seg(52, 66, "me", "Fair. I'll add the props list while I'm at it."),
              seg(66, 82, "them", "While we're here: footage handoff. AirDrop on set, or the shared SSD?"),
              seg(82, 96, "me", "AirDrop for selects, the SSD for the full day."),
              seg(96, 110, "them", "Okay. The client also wants three vertical cuts for social."),
              seg(110, 124, "me", "Then we frame wide and crop in Final Cut. I'll note it on the call sheet."),
              seg(124, 138, "them", "Ship it. Final walkthrough on Wednesday."),
          ],
          "## TL;DR\nThe holiday shoot is all iPhone, Thursday at the photo studio.\n\n"
          "## Decisions\n- Shoot stills and video on iPhone for one consistent look.\n"
          "- AirDrop for selects, the shared SSD for full shoot days.\n\n"
          "## Action items\n- [ ] Book the photo studio for Thursday morning — Me\n"
          "- [ ] Send the Freeform shot list to the crew tonight — Them\n\n"
          "## Open questions\n- Gimbal or handheld for the walk-and-talk shots?"),
        m(mid(21), "Mac refresh planning", "FaceTime", now - timedelta(minutes=102), 25, True,
          [
              seg(0, 12, "me", "Let's settle the Mac refresh. Exports take forty minutes on the old laptops."),
              seg(12, 26, "them", "Agreed on MacBook Pro for the editors. Open question: what does sales need?"),
              seg(26, 38, "me", "I'll request a business quote from Apple by Thursday."),
              seg(38, 52, "them", "Please check trade-in values for the old machines before we order."),
              seg(52, 66, "me", "Fair. Trade-ins should cover most of the AppleCare+ cost."),
              seg(66, 82, "them", "While we're here: the edit suite. Do we add a Studio Display now or next quarter?"),
              seg(82, 96, "me", "Next quarter. One purchase at a time."),
              seg(96, 110, "them", "Okay. Sales mostly lives in Keynote and Mail, so the Air is plenty for them."),
              seg(110, 124, "me", "Then sales stays on the Air. I'll put the final list in the Numbers sheet."),
              seg(124, 138, "them", "Ship it. Let's place the order once the quote is in."),
          ],
          "## TL;DR\nThe editors move to MacBook Pro now; sales stays on MacBook Air until Apple's quote is in.\n\n"
          "## Decisions\n- MacBook Pro for both video editors (export times won the argument).\n"
          "- Studio Display waits until next quarter; one purchase at a time.\n\n"
          "## Action items\n- [ ] Request a business quote from Apple by Thursday — Me\n"
          "- [ ] Check trade-in values for the old machines — Them\n\n"
          "## Open questions\n- Does sales need anything more than an Air?"),
        m(mid(22), "Studio check-in", "FaceTime", now - timedelta(minutes=182), 15, True,
          [
              seg(0, 9, "me", "Quick check-in. I'm finishing the Northwind holiday cut today."),
              seg(9, 20, "me", "Blocker: 4K exports still crawl on the old laptops."),
              seg(20, 32, "me", "Also pricing two MacBook Pro configs for the edit suite before the call."),
              seg(32, 44, "me", "And I'm sending Globex the demo presentation slides this morning."),
          ],
          "## TL;DR\nThe Northwind holiday cut wraps today; slow exports on the old laptops are the blocker.\n\n"
          "## Action items\n- [ ] Finish the Northwind holiday cut — Me\n- [ ] Price two laptop configs for the edit suite — Me"),

        # ---- Yesterday ----
        m(STUDIO_PODCAST, "Podcast trailer review", "Google Meet", ago(1, 9, 57), 30, True,
          [
              seg(0, 12, "me", "The podcast trailer is two weeks late. Let's fix the cut today."),
              seg(12, 26, "them", "Agreed on a sixty-second cut. Open question: lead with the guest or the host?"),
              seg(26, 38, "me", "I'll re-cut the intro in Logic by Friday."),
              seg(38, 52, "them", "Please duck the music under the voiceover; it fights the first line."),
              seg(52, 66, "me", "Fair. I'll check the mix on AirPods and on the studio monitors."),
              seg(66, 82, "them", "While we're here: artwork. Does the square cover work as the trailer art?"),
              seg(82, 96, "me", "It works. We reuse the episode art instead of designing a new one."),
              seg(96, 110, "them", "Okay. Subtitles too? Half of the clips get watched on mute."),
              seg(110, 124, "me", "Then we burn subtitles into the social clips and ship the trailer Friday."),
              seg(124, 138, "them", "Ship it. Let's publish the trailer with Monday's episode."),
          ],
          "## TL;DR\nThe podcast trailer becomes a sixty-second cut and ships Friday with the music under the voiceover.\n\n"
          "## Decisions\n- A sixty-second trailer cut that reuses the episode artwork.\n"
          "- Duck the music under the voiceover and check the mix on AirPods and studio monitors.\n\n"
          "## Action items\n- [ ] Re-cut the trailer intro in Logic by Friday — Me\n"
          "- [ ] Publish the trailer with Monday's episode — Them\n\n"
          "## Open questions\n- Lead with the guest or the host?"),

        # ---- Earlier this week ----
        m(mid(24), "Client call - Northwind", "Microsoft Teams", ago(2, 9, 47), 40, True,
          [
              seg(0, 15, "them", "We love the first cut, but legal needs captions before it goes on our site."),
              seg(15, 30, "me", "Captions are easy. I'll send a version with subtitles this week."),
              seg(30, 45, "them", "Great. A quote for three social cut-downs would help us get budget approved."),
          ],
          "## TL;DR\nNorthwind likes the first cut; captions are required before it goes live.\n\n"
          "## Decisions\n- Send a captioned version and a quote for three cut-downs this week.\n\n"
          "## Action items\n- [ ] Deliver the captioned cut — Me\n- [ ] Quote three social cut-downs — Me\n\n"
          "## Open questions\n- Which platforms get the vertical cut-downs?"),
        m(mid(25), "Brand refresh sync", "FaceTime", ago(2, 14, 0), 30, True,
          [
              seg(0, 16, "me", "The new logo lockups shipped. The remaining gap is the motion version."),
              seg(16, 34, "them", "I'll deliver the animated logo in Keynote and as a ProRes file by Friday."),
              seg(34, 50, "me", "Then we can close the brand refresh next week."),
              seg(50, 64, "them", "Put the animated logo on the first slide of the Globex demo presentation."),
          ],
          "## TL;DR\nThe brand refresh is nearly done; the animated logo lands Friday.\n\n"
          "## Action items\n- [ ] Animated logo in Keynote and ProRes — Them"),
        m(mid(26), "Weekly production sync", "Google Meet", ago(3, 10, 0), 45, False,
          [
              seg(0, 18, "me", "Three things this week: Northwind captions, the trade-in list, and the shoot schedule."),
              seg(18, 40, "them", "The iPhone shoot needs the big softbox. The photo studio said Thursday works."),
              seg(40, 58, "me", "Booked. Stretch goal is cleaning up the shared photo library."),
          ],
          "## TL;DR\nThis week: Northwind captions, the trade-in list, and Thursday's iPhone shoot with a borrowed softbox.\n\n"
          "## Action items\n- [ ] Captioned Northwind cut — Me\n- [ ] Shoot with the photo studio's softbox Thursday — Me"),
        m(mid(27), "1:1 with Maya", "FaceTime", ago(3, 16, 0), 30, True,
          [
              seg(0, 20, "them", "The editing is going well, but I'd like to direct a shoot myself."),
              seg(20, 38, "me", "Let's have you lead the iPhone shoot on Thursday."),
          ],
          "## TL;DR\nMaya leads Thursday's iPhone shoot.\n\n## Action items\n- [ ] Add Maya to the call sheet — Me"),
        m(mid(28), "Export failure review", "Zoom", ago(4, 11, 30), 35, True,
          [
              seg(0, 18, "me", "Timeline: the client export started at 9:12 and the laptop ran out of disk at 9:41."),
              seg(18, 36, "them", "Root cause: the render cache sits on the internal drive, and it's nearly full."),
              seg(36, 54, "me", "Fix is moving caches to the external SSD. One more reason for the Mac refresh."),
          ],
          "## TL;DR\nA client export failed when an old laptop ran out of disk; render caches move to the external SSD.\n\n"
          "## Decisions\n- Render caches live on the external SSD from now on.\n\n"
          "## Action items\n- [ ] Move render caches to the external SSD — Me"),
        m(mid(29), "Editor hiring debrief", "Google Meet", ago(5, 15, 0), 25, False,
          [
              seg(0, 16, "me", "Great storytelling, a little slow in Final Cut. I'm a hire."),
              seg(16, 32, "them", "Same read. Let's check references this week."),
          ],
          "## TL;DR\nBoth interviewers are a hire on the editor candidate; references this week.\n\n"
          "## Action items\n- [ ] Request references — Them"),

        # ---- Last week ----
        m(mid(30), "Acme podcast kickoff", "Microsoft Teams", ago(7, 10, 0), 45, True,
          [
              seg(0, 20, "them", "We want episode clips on Apple Podcasts and YouTube every week."),
              seg(20, 40, "me", "We record in Logic, cut in Final Cut, and deliver both formats."),
          ],
          "## TL;DR\nThe Acme podcast kicked off: weekly episodes for Apple Podcasts and YouTube.\n\n"
          "## Action items\n- [ ] Send the episode template — Me"),
        m(mid(31), "Equipment budget review", "Zoom", ago(8, 13, 30), 30, False,
          [
              seg(0, 18, "me", "The old laptops turn five this year, and AppleCare ran out on three of them."),
              seg(18, 36, "them", "Then let's price a refresh before the end of the quarter."),
          ],
          "## TL;DR\nThree laptops are out of AppleCare; price a refresh before quarter end.\n\n"
          "## Action items\n- [ ] Price a laptop refresh — Them"),
        m(mid(32), "Weekly all-hands", "Zoom", ago(9, 9, 0), 30, False,
          [
              seg(0, 20, "me", "Headline: the Northwind teaser passed a million views in a week."),
              seg(20, 40, "them", "Reminder that holiday campaign plans are due Friday."),
          ],
          "## TL;DR\nThe Northwind teaser passed a million views; holiday plans are due Friday."),
        m(mid(33), "Footage workflow workshop", "Google Meet", ago(10, 14, 0), 60, False,
          [
              seg(0, 22, "me", "Goal: iPhone footage on the edit timeline within ten minutes of the last take."),
              seg(22, 44, "them", "AirDrop works for a few clips; full shoot days need a shared SSD."),
              seg(44, 62, "me", "Agreed. AirDrop for selects, the SSD for full days."),
          ],
          "## TL;DR\nTarget: iPhone footage on the timeline within ten minutes; AirDrop for selects, a shared SSD for full days.\n\n"
          "## Decisions\n- AirDrop for selects, a shared SSD for full shoot days."),
        m(mid(34), "1:1 with Maya", "FaceTime", ago(11, 16, 0), 30, True,
          [
              seg(0, 18, "them", "The holiday shot list is ready in Freeform."),
              seg(18, 34, "me", "Great. I'll review it before Monday's planning call."),
          ],
          "## TL;DR\nThe holiday shot list is ready in Freeform; review before Monday.\n\n"
          "## Action items\n- [ ] Review the shot list — Me"),

        # ---- Two-three weeks back ----
        m(mid(35), "Accessibility review", "Microsoft Teams", ago(14, 11, 0), 40, True,
          [
              seg(0, 20, "me", "Every client video ships with captions and audio descriptions from now on."),
              seg(20, 40, "them", "Then the delivery checklist needs an accessibility section."),
          ],
          "## TL;DR\nCaptions and audio descriptions on every client video; the delivery checklist gets an accessibility section.\n\n"
          "## Decisions\n- Captions and audio descriptions ship with every client video."),
        m(mid(36), "Budget review Q4", "Google Meet", ago(15, 10, 30), 30, False,
          [
              seg(0, 18, "them", "Spend is flat. The only new line is the laptop refresh."),
              seg(18, 34, "me", "Approved in principle. We'll size it after the trade-in quote."),
          ],
          "## TL;DR\nQ4 budget approved; the laptop refresh is sized after the trade-in quote."),
        m(mid(37), "Launch retro - spring campaign", "Zoom", ago(16, 15, 0), 45, False,
          [
              seg(0, 20, "me", "What went well: every asset delivered on time."),
              seg(20, 42, "them", "What didn't: the vertical cuts went out at the wrong frame rate."),
              seg(42, 60, "me", "Next launch we check export presets before anything is sent."),
          ],
          "## TL;DR\nThe spring campaign delivered on time; next launch checks export presets first.\n\n"
          "## Decisions\n- Check export presets before any delivery."),
        m(mid(38), "Sales call - Globex", "Webex", ago(18, 13, 0), 30, True,
          [
              seg(0, 16, "them", "We picked you because you shoot everything on iPhone. It fits our brand."),
              seg(16, 32, "me", "Then you'll love the behind-the-scenes reel. I'll send it next week."),
          ],
          "## TL;DR\nGlobex chose the studio for its iPhone-first shoots; the behind-the-scenes reel goes out next week.\n\n"
          "## Action items\n- [ ] Send the behind-the-scenes reel — Me"),
    ]


def write_light_window_png(path, kind, accent):
    """Light-appearance counterpart of write_demo_png for the studio profile:
    a non-branded sketch of a Numbers sheet, Safari page, Keynote deck, Pages
    document, Mail inbox, or Photos library."""
    width, height = 960, 600
    pixels = [bytearray((255, 255, 255) * width) for _ in range(height)]

    def rect(x, y, w, h, color):
        x0, x1 = max(0, x), min(width, x + w)
        y0, y1 = max(0, y), min(height, y + h)
        row = bytes(color) * max(0, x1 - x0)
        for py in range(y0, y1):
            pixels[py][x0 * 3:x1 * 3] = row

    def dot(cx, cy, radius, color):
        for py in range(max(0, cy - radius), min(height, cy + radius + 1)):
            for px in range(max(0, cx - radius), min(width, cx + radius + 1)):
                if (px - cx) ** 2 + (py - cy) ** 2 <= radius * radius:
                    pixels[py][px * 3:px * 3 + 3] = bytes(color)

    line, text, faint, sidebar = (222, 222, 227), (120, 124, 134), (190, 193, 200), (246, 246, 248)
    rect(0, 0, width, 54, (236, 236, 239))
    dot(25, 27, 7, (255, 95, 87))
    dot(48, 27, 7, (255, 189, 46))
    dot(71, 27, 7, (40, 201, 64))
    rect(0, 54, width, 1, line)

    if kind == "sheet":  # Numbers: a table with a tinted header row
        rect(40, 92, 260, 18, text)
        rect(40, 140, 880, 44, accent)
        for index in range(8):
            y = 184 + index * 46
            strong = index in (0, 1)
            rect(40, y + 45, 880, 1, line)
            rect(64, y + 17, 210 - (index % 3) * 30, 11, text if strong else faint)
            rect(380, y + 17, 40, 11, faint)
            rect(520, y + 17, 90, 11, faint)
            rect(720, y + 17, 120, 11, text if strong else faint)
        for x in (340, 480, 680):
            rect(x, 140, 1, 412, line)
    elif kind == "web":  # Safari: address bar and two comparison cards
        rect(330, 15, 300, 24, (226, 226, 230))
        rect(300, 92, 360, 26, text)
        rect(360, 130, 240, 12, faint)
        for x in (90, 500):
            rect(x, 176, 370, 380, (245, 245, 247))
            rect(x + 95, 214, 180, 112, (205, 208, 214))
            rect(x + 80, 326, 210, 12, (182, 186, 194))
            rect(x + 115, 370, 140, 16, text)
            for index in range(4):
                rect(x + 70, 410 + index * 30, 230 - index * 20, 10, faint)
            rect(x + 140, 528, 90, 14, accent)
    elif kind == "slide":  # Keynote: slide navigator and canvas
        rect(0, 55, 170, height - 55, sidebar)
        for index in range(4):
            rect(28, 80 + index * 112, 114, 72, accent if index == 1 else (225, 227, 232))
        rect(210, 90, 710, 440, (250, 250, 251))
        rect(260, 140, 380, 30, (40, 44, 52))
        rect(260, 188, 260, 14, faint)
        rect(560, 250, 310, 230, accent)
        for index in range(3):
            rect(260, 270 + index * 34, 230, 11, text)
    elif kind == "doc":  # Pages: one page with a heading and a checklist
        rect(0, 55, width, height - 55, (240, 240, 243))
        rect(250, 80, 460, 520, (255, 255, 255))
        rect(290, 120, 250, 22, (40, 44, 52))
        rect(290, 160, 340, 11, faint)
        for index in range(6):
            y = 210 + index * 50
            rect(290, y, 18, 18, accent if index < 3 else line)
            rect(326, y + 4, 300 - (index % 3) * 40, 11, text if index < 3 else faint)
    elif kind == "mail":  # Mail: mailbox list, messages, body
        rect(0, 55, 190, height - 55, sidebar)
        for index in range(6):
            rect(24, 90 + index * 34, 120 - (index % 3) * 20, 11, faint)
        rect(190, 55, 1, height - 55, line)
        for index in range(6):
            y = 70 + index * 86
            selected = index == 1
            if selected:
                rect(191, y - 10, 320, 82, accent)
            rect(214, y + 4, 150, 12, (255, 255, 255) if selected else text)
            rect(214, y + 28, 250, 9, (225, 236, 255) if selected else faint)
            rect(214, y + 46, 210, 9, (225, 236, 255) if selected else faint)
        rect(511, 55, 1, height - 55, line)
        rect(550, 92, 280, 18, text)
        for index in range(8):
            rect(550, 140 + index * 30, 340 - (index % 3) * 50, 10, faint)
    else:  # photos: a library grid
        rect(0, 55, 170, height - 55, sidebar)
        palette = [accent, (120, 170, 220), (230, 190, 120), (150, 200, 160), (210, 140, 150), (180, 170, 230)]
        for row in range(4):
            for column in range(6):
                rect(196 + column * 124, 80 + row * 124, 116, 116, palette[(row * 2 + column) % len(palette)])

    write_rgb_png(path, pixels, width, height)


def seed_studio_activity(root):
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
    ensure_activity_tables(cur)
    now = time.time()
    # Today's blocks and moments are minutes before now, so a capture never
    # shows the future and the screen moments line up with today's meetings.
    today = [("Keynote", "Northwind pitch deck", 250, 190),
             ("FaceTime", "Studio check-in", 182, 167),
             ("Safari", "Compare Mac models", 167, 128),
             ("Numbers", "Studio budget 2026", 128, 102),
             ("FaceTime", "Mac refresh planning", 102, 77),
             ("Pages", "Delivery checklist", 77, 68),
             ("Mail", "Trade-in estimate", 68, 60),
             ("FaceTime", "Holiday shoot planning", 60, 52),
             ("Photos", "Northwind selects", 52, 12)]
    for app, title, start, end in today:
        cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)",
                    (app, title, now - start * 60, now - end * 60))
    earlier = {
        1: [("Freeform", "Holiday shot list", 9 * 60, 10 * 60 + 15),
            ("Google Meet", "Podcast trailer review", 10 * 60 + 15, 10 * 60 + 45),
            ("Keynote", "Holiday campaign deck", 11 * 60, 12 * 60 + 30),
            ("Safari", "AppleCare for business", 13 * 60 + 30, 14 * 60 + 45),
            ("Messages", "Studio team", 14 * 60 + 45, 15 * 60 + 10),
            ("Keynote", "Globex demo presentation", 15 * 60 + 15, 15 * 60 + 35),
            ("Mail", "Re: Globex demo presentation", 16 * 60, 16 * 60 + 15)],
        2: [("Microsoft Teams", "Client call - Northwind", 9 * 60 + 45, 10 * 60 + 25),
            ("Pages", "Delivery checklist", 10 * 60 + 30, 12 * 60),
            ("FaceTime", "Brand refresh sync", 14 * 60, 14 * 60 + 30),
            ("Keynote", "Logo animation", 14 * 60 + 30, 16 * 60)],
        3: [("Google Meet", "Weekly production sync", 10 * 60, 10 * 60 + 45),
            ("Photos", "Holiday selects", 11 * 60, 13 * 60),
            ("FaceTime", "1:1 with Maya", 16 * 60, 16 * 60 + 30)],
        4: [("Zoom", "Export failure review", 11 * 60 + 30, 12 * 60 + 5),
            ("Finder", "Render cache cleanup", 13 * 60, 14 * 60 + 30),
            ("Safari", "External SSD reviews", 14 * 60 + 30, 15 * 60)],
    }
    for offset, rows in earlier.items():
        midnight = time.mktime((datetime.now() - timedelta(days=offset))
                               .replace(hour=0, minute=0, second=0, microsecond=0).timetuple())
        for app, title, a, b in rows:
            cur.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES (?,?,?,?)",
                        (app, title, midnight + a * 60, midnight + b * 60))

    yesterday = time.mktime((datetime.now() - timedelta(days=1))
                            .replace(hour=0, minute=0, second=0, microsecond=0).timetuple())
    # (app, window title, time, screen text, thumbnail, accent, bookmark note).
    # Yesterday's demo presentation moments stay outside the podcast call, so
    # its meeting window has no "On Screen During the Meeting" section.
    shots = [
        ("Keynote", "Northwind pitch deck", now - 236 * 60,
         "Northwind holiday campaign: three hero shots, one story, all shot on iPhone.",
         "slide", (255, 159, 10), None),
        ("Safari", "Compare Mac models", now - 147 * 60,
         "MacBook Air vs MacBook Pro: displays, battery life, ports and price, side by side.",
         "web", (0, 122, 255), None),
        ("Numbers", "Studio budget 2026", now - 118 * 60,
         "Two MacBook Pro for editors, three MacBook Air for sales, AppleCare+ on all.",
         "sheet", (52, 199, 89), "Mac refresh budget"),
        ("Pages", "Delivery checklist", now - 74 * 60,
         "Every client video ships with captions, an audio description track, and a vertical cut.",
         "doc", (255, 149, 0), None),
        ("Mail", "Trade-in estimate", now - 64 * 60,
         "Your trade-in estimate for five laptops is ready and valid for 14 days.",
         "mail", (0, 122, 255), None),
        ("Photos", "Northwind selects", now - 49 * 60,
         "Northwind selects: 42 photos, 6 favorites, shared with the studio.",
         "photos", (255, 149, 0), None),
        ("Keynote", "Globex demo presentation", yesterday + (15 * 60 + 24) * 60,
         "Globex demo presentation: case studies and the launch timeline.",
         "slide", (0, 122, 255), "Final demo presentation"),
        ("Mail", "Re: Globex demo presentation", yesterday + (16 * 60 + 5) * 60,
         "Great demo presentation. Could you share the slides with our team?",
         "mail", (0, 122, 255), None),
    ]
    for index, (app, title, timestamp, text, kind, accent, note) in enumerate(shots, start=1):
        shot_dir = os.path.join(root, "activity", datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d"), "demo")
        os.makedirs(shot_dir, exist_ok=True)
        path = os.path.join(shot_dir, f"scene-{index}.png")
        write_light_window_png(path, kind, accent)
        cur.execute("""
            INSERT INTO screenshots (
                ts, path, app, window_title, capture_trigger, perceptual_hash,
                similarity_group, source_url, document_name, meeting_id,
                privacy_redactions)
            VALUES (?, ?, ?, ?, ?, '', ?, '', ?, '', 0)
            """, (timestamp, path, app, title, "window_change", index, title))
        snapshot_id = cur.lastrowid
        cur.execute("""
            INSERT INTO ocr_fts (
                text, window_title, ts, app, text_source, snapshot_id)
            VALUES (?, ?, ?, ?, 'accessibility', ?)
            """, (text, title, timestamp, app, snapshot_id))
        if note:
            cur.execute("INSERT INTO screen_bookmarks (snapshot_id, note, created_at) VALUES (?, ?, ?)",
                        (snapshot_id, note, timestamp + 8 * 60))
    con.commit()
    con.close()
    return len(shots)


def seed_studio_chats(root, now):
    """Two answered Ask conversations that cite the studio meetings."""
    chats = os.path.join(root, "chats")
    os.makedirs(chats, exist_ok=True)

    def msg(mid_, role, text, activity=None):
        out = {"id": mid_, "role": role, "text": text}
        if activity:
            out["activity"] = activity
        return out

    def act(aid, tool, icon, text):
        return {"id": aid, "tool": tool, "icon": icon, "text": text, "done": True}

    northwind = mid(24)
    shoot = {
        "id": "bbbbbbb1-0000-4000-8000-000000000001",
        "title": "Holiday shoot plan",
        "createdAt": iso(now - timedelta(minutes=9)),
        "updatedAt": iso(now - timedelta(minutes=2)),
        "messages": [
            msg("bbbbbbb1-0000-4000-8000-000000000101", "user",
                "What did we decide for the holiday shoot?"),
            msg("bbbbbbb1-0000-4000-8000-000000000102", "assistant",
                "Everything is shot on iPhone, stills and video, for one consistent look "
                f"[meeting:{STUDIO_SHOOT}@0:12]. Footage moves by AirDrop for selects and on the shared SSD "
                f"for full shoot days [meeting:{STUDIO_SHOOT}@1:22].\n\n"
                f"You're booking the photo studio for Thursday morning [meeting:{STUDIO_SHOOT}@0:26], "
                f"and Maya is sending the Freeform shot list to the crew tonight [meeting:{STUDIO_SHOOT}@0:38].",
                activity=[
                    act("bbbbbbb1-0000-4000-8000-000000000201", "search_meetings",
                        "magnifyingglass", "searched meetings for “holiday shoot”"),
                    act("bbbbbbb1-0000-4000-8000-000000000202", "get_meeting",
                        "doc.text", "read “Holiday shoot planning”"),
                ]),
        ],
    }
    captions = {
        "id": "bbbbbbb2-0000-4000-8000-000000000002",
        "title": "Northwind captions",
        "createdAt": iso(now - timedelta(days=1, hours=2)),
        "updatedAt": iso(now - timedelta(days=1, hours=2)),
        "messages": [
            msg("bbbbbbb2-0000-4000-8000-000000000101", "user",
                "What does Northwind need before the cut goes live?"),
            msg("bbbbbbb2-0000-4000-8000-000000000102", "assistant",
                "Captions. Their legal team won't put the cut on the site without them "
                f"[meeting:{northwind}@0:00]. You promised a subtitled version this week "
                f"[meeting:{northwind}@0:15], and they asked for a quote on three social cut-downs "
                f"[meeting:{northwind}@0:30].",
                activity=[
                    act("bbbbbbb2-0000-4000-8000-000000000201", "search_meetings",
                        "magnifyingglass", "searched meetings for “Northwind”"),
                    act("bbbbbbb2-0000-4000-8000-000000000202", "get_meeting",
                        "doc.text", "read “Client call - Northwind”"),
                ]),
        ],
    }
    for convo in (shoot, captions):
        with open(os.path.join(chats, f"{convo['id']}.json"), "w") as f:
            json.dump(convo, f, indent=2)


def seed_studio(root):
    now = datetime.now(timezone.utc)
    meetings = build_studio(now)
    speakers = {STUDIO_SHOOT: "Maya", STUDIO_PODCAST: "Leo"}
    for mm in meetings:
        folder = write_meeting(root, mm)
        if mm["id"] not in speakers:
            continue
        write_demo_audio(folder)
        write_demo_audio(folder, track="system", tone=247, beat=2.7, level=1_400)
        # A named speaker keeps the "speaker needs a name" prompt out of the
        # featured meetings' summaries.
        path = os.path.join(folder, "transcript.json")
        with open(path) as f:
            transcript = json.load(f)
        transcript["speakerAliases"] = {"them": speakers[mm["id"]]}
        with open(path, "w") as f:
            json.dump(transcript, f, indent=2)
    journal = os.path.join(root, "journal")
    os.makedirs(journal, exist_ok=True)
    with open(os.path.join(journal, f"{datetime.now().strftime('%Y-%m-%d')}.md"), "w") as f:
        f.write("""## Today at a glance

The holiday shoot is all iPhone on Thursday, and the editors move to MacBook Pro once Apple's quote is in. The Northwind holiday cut wraps today.

## Next

- Book the photo studio for Thursday morning.
- Request the business quote from Apple.
- Deliver the captioned Northwind cut.
""")
    seed_studio_chats(root, now)
    moments = seed_studio_activity(root)
    return len(meetings), moments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reset", action="store_true",
                        help="replace an existing directory created by this script")
    parser.add_argument("--profile", choices=["demo", "studio", "full-day", "large"], default="demo",
                        help="demo (default): the screenshot library; studio: the website and README "
                             "hero library; full-day: one untranscribed 9-hour day; large: 180 days "
                             "for scale checks")
    parser.add_argument("--day", help="YYYY-MM-DD for full-day (default: yesterday)")
    parser.add_argument("storage_root")
    args = parser.parse_args()
    root = os.path.abspath(args.storage_root)
    marker = os.path.join(root, OWNERSHIP_MARKER)
    if os.path.exists(root):
        entries = os.listdir(root)
        if entries:
            if not args.reset:
                raise SystemExit(f"Refusing to overwrite populated directory: {root}")
            if not os.path.isfile(marker):
                raise SystemExit(f"Refusing to reset unowned directory: {root}")
            shutil.rmtree(root)
    os.makedirs(root, exist_ok=True)
    with open(marker, "w", encoding="utf-8") as owned:
        owned.write("LokalBot synthetic demo library\n")
    os.makedirs(os.path.join(root, "meetings"), exist_ok=True)
    if args.profile == "full-day":
        day = date.fromisoformat(args.day) if args.day else date.today() - timedelta(days=1)
        seed_full_day(root, day)
        print(f"Seeded full-day library at {root} for {day.isoformat()}")
        return
    if args.profile == "large":
        seed_large(root)
        print(f"Seeded large library at {root}")
        return
    if args.profile == "studio":
        meetings, moments = seed_studio(root)
        print(f"Seeded studio library at {root} ({meetings} meetings, 2 chats, {moments} screen moments)")
        return
    now = datetime.now(timezone.utc)
    for mm in build(now):
        write_meeting(root, mm)
    seed_chats(root, now)
    seed_journal(root)
    seed_activity(root)
    print(f"Seeded demo library at {root} "
          f"({len(build(now))} meetings, 2 chats, 5 days of activity, 5 screen moments)")


if __name__ == "__main__":
    main()
