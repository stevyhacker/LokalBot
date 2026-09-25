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
    python3 Scripts/seed_demo_library.py [--reset] <storage-root>

By default the destination must be new or empty. ``--reset`` is accepted only
for a directory previously marked as a LokalBot demo library.

Point the app at <storage-root> via LOKALBOT_STORAGE_ROOT. See
Scripts/capture-screenshots.sh for the full capture flow.
"""
import argparse, json, math, os, re, shutil, sqlite3, struct, subprocess, sys, time, wave, zlib
from datetime import datetime, timezone, timedelta

ENGINE = "on-device demo"
OWNERSHIP_MARKER = ".lokalbot-demo-library"

# Stable ids so chat citations and capture scripts can reference meetings.
DESIGN_REVIEW = "11111111-1111-4111-8111-111111111111"
STANDUP = "22222222-2222-4222-8222-222222222222"
ROADMAP = "33333333-3333-4333-8333-333333333333"
NORTHWIND = "44444444-4444-4444-8444-444444444444"


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


def write_demo_audio(folder):
    """Add a short, decodable source track for the detail-player happy path."""
    wav_path = os.path.join(folder, "demo-audio.wav")
    m4a_path = os.path.join(folder, "mic.m4a")
    sample_rate = 16_000
    duration = 140
    with wave.open(wav_path, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(sample_rate)
        frames = bytearray()
        for index in range(sample_rate * duration):
            seconds = index / sample_rate
            pulse = 0.25 + 0.75 * abs(math.sin(seconds * math.pi / 3.4))
            sample = int(1_600 * pulse * math.sin(2 * math.pi * 196 * seconds))
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


def seed_activity(root):
    con = sqlite3.connect(os.path.join(root, "lokalbotv3.sqlite"))
    cur = con.cursor()
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reset", action="store_true",
                        help="replace an existing directory created by this script")
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
