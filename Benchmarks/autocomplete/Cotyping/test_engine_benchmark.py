import unittest

from engine_benchmark import PRODUCTION, TYPING_PHRASES, accuracy, check_production, load_phrases, stats, typing_cases
from quality_replay import checkpoints


class EngineBenchmarkTests(unittest.TestCase):
    def test_typing_sends_only_what_was_typed(self):
        phrases = load_phrases()
        cases = typing_cases(phrases)
        by_id = {p["id"]: p for p in phrases}
        self.assertEqual(len(cases), sum(len(by_id[i]["text"]) for i in TYPING_PHRASES))
        first = by_id[TYPING_PHRASES[0]]
        prefix = first.get("scenario", {}).get("documentPrefix", "")
        self.assertEqual(cases[0]["prefix"], prefix + first["text"][0])
        self.assertEqual(cases[len(first["text"]) - 1]["prefix"], prefix + first["text"])

    def test_stats_use_nearest_rank(self):
        result = stats(list(range(1, 21)))
        self.assertEqual((result["medianMs"], result["p90Ms"], result["p95Ms"], result["maxMs"]), (10, 18, 19, 20))
        self.assertIsNone(stats([]))

    def test_replay_must_use_production_runtime(self):
        row = {"id": "a", **PRODUCTION, "healingMode": "prefixSearch"}
        check_production([row])
        with self.assertRaises(SystemExit):
            check_production([{**row, "searchExperiment": "baseline"}])
        with self.assertRaises(SystemExit):
            check_production([{**row, "healingMode": "wordBoundary"}])

    def test_accuracy_separates_coverage_from_precision(self):
        phrases = [{"id": "e", "category": "email", "text": "Please send it"},
                   {"id": "s", "category": "serbian-latin", "text": "Hvala ti puno"}]
        cases, references = checkpoints(phrases, "word")
        texts = {"e:1:0": "send", "e:2:0": "", "s:1:0": "vam", "s:2:0": "puno"}
        observations = [{"id": c["id"], "text": texts[c["id"]], "latencyMs": 50} for c in cases]
        result = accuracy(observations, references)
        self.assertEqual(result["overall"]["accuracy"], 0.5)
        self.assertEqual(result["overall"]["coverage"], 0.75)
        self.assertEqual(result["overall"]["precision"], 0.6667)
        self.assertEqual(result["english"]["checkpoints"], 2)
        self.assertEqual(result["otherLanguages"]["correct"], 1)


if __name__ == "__main__":
    unittest.main()
