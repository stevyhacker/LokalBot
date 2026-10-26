#!/usr/bin/env python3
"""Seed the studio demo library for filming, with every meeting on the local clock.

Scripts/seed_demo_library.py anchors today's studio meetings to now but builds
earlier days' times in UTC hours, and writes timestamps with a literal "Z".
Filmed early in the morning, that shows today's meetings at 2-5 AM and older
ones late at night. This runs the shared script unchanged on disk, with two
in-memory edits: the studio clock is the local one, and timestamps are
converted to UTC before they are written. Run it in the zone the host will use:

    TZ=Asia/Tokyo python3 seed_filming_library.py <storage-root>
"""
import os, sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
SEED = os.path.join(REPO, "Scripts", "seed_demo_library.py")
EDITS = [
    ("def seed_studio(root):\n    now = datetime.now(timezone.utc)",
     "def seed_studio(root):\n    now = datetime.now().astimezone()"),
    ('def iso(dt):\n    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")',
     'def iso(dt):\n    if dt.tzinfo is not None:\n        dt = dt.astimezone(timezone.utc)\n'
     '    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")'),
]

if len(sys.argv) != 2:
    sys.exit(__doc__)
with open(SEED) as f:
    source = f.read()
for old, new in EDITS:
    if old not in source:
        sys.exit(f"Scripts/seed_demo_library.py changed; update the edit for: {old.splitlines()[0]}")
    source = source.replace(old, new)
sys.argv = [SEED, "--reset", "--profile", "studio", sys.argv[1]]
exec(compile(source, SEED, "exec"), {"__name__": "__main__", "__file__": SEED})
