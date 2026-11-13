import json
from pathlib import Path
import unittest

from memory_replay import replay_input, score


class MemoryReplayTests(unittest.TestCase):
    def setUp(self):
        self.case = {"id": "atlas", "prefix": "Atlas owner is ", "expected": "Priya",
                     "expectedMemoryID": "fact", "kind": "relevant", "split": "heldout"}
        self.observation = {"id": "atlas", "text": "Priya", "prompt": "draft",
                            "memoryIDs": ["fact"], "latencyMs": 10, "usedPromptOverride": False}

    def testReferencesAndLabelsDoNotReachModel(self):
        fixture = replay_input({"memoryItems": [], "asOf": "2026-10-02T12:00:00Z"}, [self.case], True)
        self.assertEqual(fixture["cases"], [{"id": "atlas", "prefix": "Atlas owner is "}])

    def testScoresExactFirstWordAndSourceSelection(self):
        off = dict(self.observation, text="Alex", memoryIDs=[])
        result = score([self.case], [off], [self.observation])["summary"]
        self.assertEqual(result["offCorrect"], 0)
        self.assertEqual(result["onCorrect"], 1)
        self.assertEqual(result["exactSelections"], 1)
        invalid = dict(self.observation, error="failed")
        self.assertEqual(score([self.case], [off], [invalid])["summary"]["onCorrect"], 0)

    def testControlsCheckPromptAsWellAsText(self):
        control = {"id": "atlas", "kind": "irrelevant"}
        off = dict(self.observation, memoryIDs=[])
        on = dict(off, prompt="unexpected context")
        result = score([control], [off], [on])["summary"]
        self.assertEqual(result["unchangedControls"], 0)
        self.assertEqual(result["exactSelections"], 1)

    def testIgnoringIrrelevantMemoryIsScoredAlongsideRecall(self):
        distractor = {"id": "generic", "prefix": "I'll get back to ", "kind": "distractor", "split": "heldout"}
        cases = [self.case, distractor]
        off = [dict(self.observation, text="Alex", memoryIDs=[]),
               {"id": "generic", "text": "you soon", "prompt": "draft", "memoryIDs": [], "latencyMs": 10}]
        ignored = [self.observation, dict(off[1])]
        summary = score(cases, off, ignored)["summary"]
        self.assertEqual((summary["recallRate"], summary["abstentionRate"], summary["balancedRelevance"]), (1, 1, 1))
        self.assertEqual((summary["distractorCases"], summary["abstentions"], summary["falseRetrievals"]), (1, 1, 0))
        # Borrowing an unrelated fact fails the control even if the words look plausible.
        borrowed = [self.observation,
                    dict(off[1], text="you on Friday", prompt="facts + draft", memoryIDs=["sync-followup"])]
        summary = score(cases, off, borrowed)["summary"]
        self.assertEqual((summary["abstentions"], summary["falseRetrievals"]), (0, 1))
        self.assertEqual((summary["abstentionRate"], summary["balancedRelevance"]), (0, 0.5))
        # A lookup that changes nothing still counts as retrieving.
        retrieved = [self.observation, dict(off[1], memoryIDs=["sync-followup"])]
        self.assertEqual(score(cases, off, retrieved)["summary"]["abstentions"], 0)

    def testRatesAreAbsentWithoutCasesOfThatKindAndKindsAreChecked(self):
        off = dict(self.observation, text="Alex", memoryIDs=[])
        summary = score([self.case], [off], [self.observation])["summary"]
        self.assertIsNone(summary["abstentionRate"])
        self.assertIsNone(summary["balancedRelevance"])
        with self.assertRaises(ValueError):
            score([dict(self.case, kind="unlabelled")], [off], [self.observation])

    def testRelevanceSupplementIsWellFormed(self):
        corpus = json.loads(Path(__file__).with_name("memory-relevance-cases.json").read_text())
        facts = {item["id"] for item in corpus["memoryItems"]}
        ids = [case["id"] for case in corpus["cases"]]
        self.assertEqual(len(ids), len(set(ids)))
        for case in corpus["cases"]:
            self.assertIn(case["split"], {"development", "heldout"})
            if case["kind"] == "relevant":
                self.assertIn(case["expectedMemoryID"], facts)
                self.assertTrue(case["expected"])
            else:
                self.assertEqual(case["kind"], "distractor")
                self.assertNotIn("expected", case)
                self.assertNotIn("expectedMemoryID", case)
        for split in ["development", "heldout"]:
            kinds = {case["kind"] for case in corpus["cases"] if case["split"] == split}
            self.assertEqual(kinds, {"relevant", "distractor"})

    def testRejectsMissingResultsAndPromptOverrides(self):
        with self.assertRaises(ValueError):
            score([self.case], [], [self.observation])
        with self.assertRaises(ValueError):
            score([self.case], [self.observation], [dict(self.observation, usedPromptOverride=True)])


if __name__ == "__main__":
    unittest.main()
