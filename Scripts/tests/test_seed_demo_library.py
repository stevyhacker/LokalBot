#!/usr/bin/env python3
"""Regression tests for the demo library destination ownership boundary."""

from datetime import datetime
import glob
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "seed_demo_library.py"
SPEC = importlib.util.spec_from_file_location("seed_demo_library", SCRIPT)
SEEDER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SEEDER)


class DemoLibraryDestinationTests(unittest.TestCase):
    def run_main(self, *arguments):
        # The ownership decision happens before fixture generation. Stub the
        # expensive audio/data writers so these tests exercise that real CLI
        # boundary without depending on codecs or creating benchmark data.
        with mock.patch.object(sys, "argv", [str(SCRIPT), *map(str, arguments)]), \
             mock.patch.object(SEEDER, "build", return_value=[]), \
             mock.patch.object(SEEDER, "seed_chats"), \
             mock.patch.object(SEEDER, "seed_journal"), \
             mock.patch.object(SEEDER, "seed_activity"):
            SEEDER.main()

    def test_populated_unowned_directory_is_never_removed(self):
        with tempfile.TemporaryDirectory(prefix="lokalbot-demo-destination-") as temporary:
            root = Path(temporary) / "existing-library"
            root.mkdir()
            sentinel = root / "keep-me.txt"
            sentinel.write_text("user data\n", encoding="utf-8")

            for arguments in ((root,), ("--reset", root)):
                with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                    self.run_main(*arguments)
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "user data\n")
                self.assertFalse((root / SEEDER.OWNERSHIP_MARKER).exists())

    def test_marked_directory_requires_reset_and_then_only_its_contents_are_replaced(self):
        with tempfile.TemporaryDirectory(prefix="lokalbot-demo-destination-") as temporary:
            root = Path(temporary) / "owned-library"
            root.mkdir()
            marker = root / SEEDER.OWNERSHIP_MARKER
            marker.write_text("LokalBot synthetic demo library\n", encoding="utf-8")
            stale = root / "stale-fixture.txt"
            stale.write_text("old fixture\n", encoding="utf-8")

            with self.assertRaises(SystemExit):
                self.run_main(root)
            self.assertTrue(stale.exists())

            self.run_main("--reset", root)
            self.assertFalse(stale.exists())
            self.assertEqual(marker.read_text(encoding="utf-8"),
                             "LokalBot synthetic demo library\n")
            self.assertTrue((root / "meetings").is_dir())



class SeedProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = os.path.join(self.temp.name, "lib")

    def run_seed(self, *args):
        subprocess.run([sys.executable, str(SCRIPT), *args, self.root],
                       check=True, capture_output=True)

    def test_full_day_has_nine_hours_private_time_captures_and_untranscribed_meetings(self):
        self.run_seed("--profile", "full-day", "--day", "2026-08-04")
        con = sqlite3.connect(os.path.join(self.root, "lokalbotv3.sqlite"))
        tracked = con.execute("SELECT SUM(end - start) FROM activity_blocks").fetchone()[0]
        private = con.execute("SELECT SUM(end - start) FROM activity_blocks WHERE app = 'Private'").fetchone()[0]
        self.assertGreater(tracked, 8 * 3600)
        self.assertLess(private / tracked, 0.15)
        for app, seconds in con.execute("SELECT app, SUM(end - start) FROM activity_blocks WHERE app != 'Private' GROUP BY app"):
            if seconds >= 1800:
                count = con.execute("SELECT COUNT(*) FROM screenshots WHERE app = ?", (app,)).fetchone()[0]
                self.assertGreaterEqual(count, 3, app)
        metas = glob.glob(os.path.join(self.root, "meetings/*/*/*/meta.json"))
        self.assertEqual(len(metas), 2)
        for meta in metas:
            folder = os.path.dirname(meta)
            self.assertTrue(os.path.exists(os.path.join(folder, "mic.m4a")))
            self.assertFalse(os.path.exists(os.path.join(folder, "transcript.json")))

    def test_large_profile_is_big_and_deterministic(self):
        self.run_seed("--profile", "large")
        con = sqlite3.connect(os.path.join(self.root, "lokalbotv3.sqlite"))
        self.assertGreaterEqual(con.execute("SELECT COUNT(*) FROM activity_blocks").fetchone()[0], 50_000)
        self.assertGreaterEqual(con.execute("SELECT COUNT(*) FROM screenshots").fetchone()[0], 20_000)
        self.assertEqual(len(glob.glob(os.path.join(self.root, "meetings/*/*/*/meta.json"))), 200)

    def test_full_day_merged_meeting_is_covered_by_its_golden_transcript(self):
        # A merged source of 30 s or more with no transcript segment is a
        # merged gap, which the pipeline repairs by re-transcribing; the seeded
        # day must be healthy, so every source span holds golden speech.
        self.run_seed("--profile", "full-day", "--day", "2026-08-04")
        folder = glob.glob(os.path.join(self.root, "meetings/*/*/*-sprint-planning"))[0]
        with open(os.path.join(folder, "merge-manifest.json")) as f:
            manifest = json.load(f)
        self.assertEqual(manifest["version"], 2)
        golden = Path(__file__).resolve().parents[2] / "LokalBotTests/Fixtures/day-in-the-life/golden-transcripts"
        segments = []
        for track in ("mic", "system"):
            with open(golden / "sprint-planning" / f"{track}.json") as f:
                segments += json.load(f)["segments"]
        offset = 0
        for source in manifest["sources"]:
            for key in ("id", "title", "startedAt", "duration", "hasAudio", "hasTranscript"):
                self.assertIn(key, source)
            span = (offset, offset + source["duration"])
            self.assertTrue(any(s["end"] > span[0] and s["start"] < span[1] for s in segments), span)
            offset += source["duration"]

    def test_studio_profile_keeps_each_example_on_its_own_surface(self):
        # The website shows the holiday shoot meeting, a "MacBook" search and a
        # "captions" search. Each search must return only its own rows, and
        # nothing seeded for today may lie in the future of the capture.
        self.run_seed("--profile", "studio")
        now = time.time()
        folders = {}
        for path in glob.glob(os.path.join(self.root, "meetings/*/*/*/meta.json")):
            with open(path) as f:
                meta = json.load(f)
            started = datetime.fromisoformat(meta["startedAt"].replace("Z", "+00:00")).timestamp()
            self.assertLess(started, now, meta["title"])
            folders.setdefault(meta["title"], []).append(os.path.dirname(path))
        self.assertEqual(sum(map(len, folders.values())), 19)

        ids = set()
        for paths in folders.values():
            for folder in paths:
                with open(os.path.join(folder, "meta.json")) as f:
                    ids.add(json.load(f)["id"])
        chats = glob.glob(os.path.join(self.root, "chats/*.json"))
        self.assertEqual(len(chats), 2)
        for path in chats:
            with open(path) as f:
                cited = {match for message in json.load(f)["messages"]
                         for match in re.findall(r"\[meeting:([0-9a-f-]+)@", message["text"])}
            self.assertTrue(cited and cited <= ids, path)

        featured = folders["Holiday shoot planning"][0]
        for title, speaker in (("Holiday shoot planning", "Maya"), ("Podcast trailer review", "Leo")):
            folder = folders[title][0]
            for track in ("mic.m4a", "system.m4a"):
                self.assertTrue(os.path.exists(os.path.join(folder, track)), (title, track))
            with open(os.path.join(folder, "transcript.json")) as f:
                self.assertEqual(json.load(f)["speakerAliases"], {"them": speaker})

        def meetings_saying(word):
            titles = set()
            for title, paths in folders.items():
                for folder in paths:
                    with open(os.path.join(folder, "transcript.json")) as f:
                        if any(word in segment["text"].lower() for segment in json.load(f)["segments"]):
                            titles.add(title)
            return titles

        self.assertEqual(meetings_saying("macbook"), {"Mac refresh planning", "Studio check-in"})
        self.assertEqual(meetings_saying("captions"),
                         {"Client call - Northwind", "Weekly production sync", "Accessibility review"})
        self.assertEqual(meetings_saying("demo presentation"), {"Studio check-in", "Brand refresh sync"})

        con = sqlite3.connect(os.path.join(self.root, "lokalbotv3.sqlite"))
        self.addCleanup(con.close)

        def screens_showing(word):
            return {title for (title,) in con.execute(
                "SELECT window_title FROM ocr_fts WHERE text MATCH ?", (word,))}

        self.assertEqual(screens_showing("macbook"), {"Compare Mac models", "Studio budget 2026"})
        self.assertEqual(screens_showing("captions"), {"Delivery checklist"})
        self.assertEqual(screens_showing('"demo presentation"'),
                         {"Globex demo presentation", "Re: Globex demo presentation"})
        self.assertEqual({note for (note,) in con.execute("SELECT note FROM screen_bookmarks")},
                         {"Mac refresh budget", "Final demo presentation"})
        self.assertLess(con.execute("SELECT MAX(ts) FROM screenshots").fetchone()[0], now)
        self.assertLess(con.execute("SELECT MAX(end) FROM activity_blocks").fetchone()[0], now)
        for (path,) in con.execute("SELECT path FROM screenshots"):
            with open(path, "rb") as f:
                self.assertEqual(f.read(8), b"\x89PNG\r\n\x1a\n")

        # The Photos moment falls inside the featured call, so the meeting
        # window shows it under "On Screen During the Meeting".
        with open(os.path.join(featured, "meta.json")) as f:
            meta = json.load(f)
        start, end = (datetime.fromisoformat(meta[key].replace("Z", "+00:00")).timestamp()
                      for key in ("startedAt", "endedAt"))
        (photos,) = con.execute("SELECT ts FROM screenshots WHERE app = 'Photos'").fetchone()
        self.assertTrue(start < photos < end)

        # Nothing was on screen during the podcast call, which the README shows
        # without an "On Screen During the Meeting" section.
        with open(os.path.join(folders["Podcast trailer review"][0], "meta.json")) as f:
            meta = json.load(f)
        start, end = (datetime.fromisoformat(meta[key].replace("Z", "+00:00")).timestamp()
                      for key in ("startedAt", "endedAt"))
        self.assertEqual(con.execute("SELECT COUNT(*) FROM screenshots WHERE ts BETWEEN ? AND ?",
                                     (start, end)).fetchone()[0], 0)

if __name__ == "__main__":
    unittest.main()
