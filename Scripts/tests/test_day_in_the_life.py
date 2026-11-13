import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, SOURCE / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


scenario = load("scenario", "Scripts/test/day-in-the-life/scenario.py")
assertions = load("assertions", "Scripts/test/day-in-the-life/assertions.py")


class ScenarioTests(unittest.TestCase):
    def test_rules_cover_every_purpose_with_a_catch_all(self):
        rules = scenario.build(SOURCE / "LokalBotTests/Fixtures/model-recordings", "z-ai/glm-5.3-flash")
        markers = json.loads((SOURCE / "LokalBotTests/Fixtures/model-recordings/purpose-markers.json").read_text())
        catch_alls = {r["match"]["systemIncludes"] for r in rules if "nth" not in r["match"]}
        self.assertTrue({markers["digestFocus"], markers["digestAggregate"], markers["notes"]} <= catch_alls)

    def test_only_real_asr_answers_notes_repairs(self):
        # Nightly 2026-10-01: real Parakeet wording missed a recorded quote,
        # the app asked for a repair, and the stub had no rule (HTTP 500).
        root = SOURCE / "LokalBotTests/Fixtures/model-recordings"
        marker = json.loads((root / "purpose-markers.json").read_text())["notesRepair"]
        golden = scenario.build(root, "z-ai/glm-5.3-flash")
        self.assertFalse(any(r["match"]["systemIncludes"] == marker for r in golden))
        real = [r for r in scenario.build(root, "z-ai/glm-5.3-flash", real_asr=True)
                if r["match"]["systemIncludes"] == marker]
        self.assertEqual(len(real), 1)
        self.assertEqual(json.loads(real[0]["behaviour"]["content"]), {"notes": [], "actions": [], "has_more": False})


class AssertionTests(unittest.TestCase):
    def test_health_assertions(self):
        report = {"findings": [
            {"check": "activityClock", "status": "pass", "measurements": {}},
            {"check": "digestCoverage", "status": "pass", "measurements": {"coverage": 0.8}},
            {"check": "finishedRecordings", "status": "pass", "measurements": {}}]}
        self.assertEqual(assertions.health_problems(report), [])
        report["findings"][1]["measurements"]["coverage"] = 0.4
        self.assertTrue(assertions.health_problems(report))

    def test_owned_action(self):
        # outcomes.json as MeetingOutcomes encodes it: actionItems with the
        # resolved owner ("Me") and isForUser.
        with tempfile.TemporaryDirectory() as folder:
            outcomes = Path(folder, "outcomes.json")
            outcomes.write_text(json.dumps({"actionItems": [{"text": "Draft", "owner": "Ana", "isForUser": False}]}))
            self.assertFalse(assertions.has_action_owned_by_me(Path(folder)))
            outcomes.write_text(json.dumps({"actionItems": [{"text": "Draft", "owner": "Me", "isForUser": True}]}))
            self.assertTrue(assertions.has_action_owned_by_me(Path(folder)))

    def test_finished_notes_accept_any_owner(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertFalse(assertions.has_finished_notes(Path(folder)))
            outcomes = Path(folder, "outcomes.json")
            outcomes.write_text(json.dumps({"actionItems": []}))
            self.assertFalse(assertions.has_finished_notes(Path(folder)))
            outcomes.write_text(json.dumps({"actionItems": [{"text": "Draft", "isForUser": False}]}))
            self.assertTrue(assertions.has_finished_notes(Path(folder)))

    def test_word_error_rate_ignores_case_punctuation_and_hyphens(self):
        golden = SOURCE / "LokalBotTests/Fixtures/day-in-the-life/golden-transcripts/design-review"
        with tempfile.TemporaryDirectory() as folder:
            heard = [
                {"start": 0, "text": "let's lock the caching layer, I propose Redis for the pub sub support"},
                {"start": 7, "text": "Agreed on Redis. Open question: do we need cluster mode from day one?"},
                {"start": 16, "text": "I'll draft the eviction policy doc by Thursday"},
                {"start": 22, "text": "Please benchmark failover latency before we commit to a cluster."},
                {"start": 30, "text": "Fair. I'll borrow the load harness from the search team for that."},
            ]
            Path(folder, "transcript.json").write_text(json.dumps({"segments": heard}))
            self.assertEqual(assertions.transcript_word_error_rate(Path(folder), golden), 0)
            heard[3]["text"] = "Please benchmark fail over latency before we commit."
            Path(folder, "transcript.json").write_text(json.dumps({"segments": heard}))
            rate = assertions.transcript_word_error_rate(Path(folder), golden)
            self.assertGreater(rate, 0)
            self.assertLess(rate, 0.25)

    def test_word_error_rate_counts_every_edit(self):
        self.assertEqual(assertions.word_error_rate(["a", "b", "c", "d"], ["a", "x", "c"]), 0.5)
        self.assertEqual(assertions.word_error_rate(["a"], []), 1)

    def test_a_split_or_joined_compound_is_not_an_edit(self):
        self.assertEqual(assertions.word_edits(["cleanup", "tomorrow"], ["clean", "up", "tomorrow"]), 0)
        self.assertEqual(assertions.word_edits(["clean", "up", "tomorrow"], ["cleanup", "tomorrow"]), 0)
        self.assertEqual(assertions.word_edits(["pair", "on"], ["pare", "on"]), 1)
        self.assertEqual(assertions.word_edits(["clean", "up"], ["cleanups"]), 2)

    def test_day_rate_pools_meetings_so_one_short_meeting_cannot_decide_the_run(self):
        # Nightly 2026-10-01: Parakeet heard the 14-word sprint planning as
        # "...i'll pare on the tombstone clean up tomorrow" (21.4% per meeting
        # before compounds were ignored) and the design review exactly.
        fixtures = SOURCE / "LokalBotTests/Fixtures/day-in-the-life/golden-transcripts"
        heard = {
            "design-review": json.loads((fixtures / "design-review/mic.json").read_text())["segments"]
            + json.loads((fixtures / "design-review/system.json").read_text())["segments"],
            "sprint-planning": [
                {"start": 0, "text": "Sprint goal is the search index rebuild."},
                {"start": 121, "text": "I'll pare on the tombstone clean up tomorrow."},
            ],
        }
        with tempfile.TemporaryDirectory() as root:
            meetings = []
            for name, segments in heard.items():
                folder = Path(root, name)
                folder.mkdir()
                (folder / "transcript.json").write_text(json.dumps({"segments": segments}))
                meetings.append((folder, fixtures / name))
            self.assertAlmostEqual(assertions.transcript_word_error_rate(*meetings[1]), 1 / 14)
            self.assertAlmostEqual(assertions.day_word_error_rate(meetings), 1 / 70)


if __name__ == "__main__":
    unittest.main()
