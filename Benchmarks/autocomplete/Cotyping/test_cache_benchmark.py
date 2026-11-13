import copy
import unittest

from cache_benchmark import dynamic_cases, paired_dynamic, validate_dynamic


class CacheBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.cases, self.meta = dynamic_cases({"phrases": [
            {"id": "synthetic", "split": "heldout", "text": "We can schedule another meeting."}]})

    def testDynamicFixtureIncludesEditsAndSeparateControlMetadata(self):
        actions = {m["action"] for m in self.meta.values()}
        self.assertTrue({"forward", "backspace", "branch", "cancel", "clear", "unscoped"} <= actions)
        self.assertEqual(len(self.cases), len({c["id"] for c in self.cases}))
        self.assertTrue(all("reference" not in c and "promptOverride" not in c for c in self.cases))
        unscoped = next(c for c in self.cases if self.meta[c["id"]]["action"] == "unscoped")
        self.assertNotIn("cacheScope", unscoped)

    def testEquivalenceAllowsOnlyExpectedCancelledStepsToDiffer(self):
        old = [{"id": c["id"], "prompt": c["prefix"], "text": "tomorrow"} for c in self.cases]
        new = copy.deepcopy(old)
        cancelled = next(i for i, c in enumerate(self.cases) if c.get("cancelAfterMs") is not None)
        new[cancelled].update(text="", suppression="cancelled")
        self.assertFalse(paired_dynamic(old, new, self.meta)["outputChanges"])
        new[0]["text"] = "today"
        self.assertEqual(paired_dynamic(old, new, self.meta)["outputChanges"], [old[0]["id"]])

    def testBoundViolationsAndReuseAfterClearFailClosed(self):
        case = {"id": "a", "resetCache": True}
        row = {"id": "a", "text": "", "latencyMs": 1, "decoderCandidates": 1, "cache": {
            "enabled": True, "entries": 0, "bytes": 0, "hits": 0}}
        validate_dynamic([row], [case], True)
        row["cache"]["hits"] = 1
        with self.assertRaisesRegex(ValueError, "invalidation"):
            validate_dynamic([row], [case], True)
        row["cache"].update(hits=0, bytes=33 * 1024 * 1024)
        with self.assertRaisesRegex(ValueError, "memory"):
            validate_dynamic([row], [case], True)

    def testUnexpectedCancellationCannotPublishText(self):
        row = {"id": "a", "text": "tomorrow", "cancelled": True, "latencyMs": 1, "decoderCandidates": 1}
        with self.assertRaisesRegex(ValueError, "Cancelled"):
            validate_dynamic([row], [{"id": "a", "cancelAfterMs": 2}], True)
        row.update(text="", cancelled=False)
        with self.assertRaisesRegex(ValueError, "did not occur"):
            validate_dynamic([row], [{"id": "a", "cancelAfterMs": 2}], True)


if __name__ == "__main__":
    unittest.main()
