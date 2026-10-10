import unittest

from ranking_audit import audit


class RankingAuditTests(unittest.TestCase):
    def testRerankedMarginsUseTheActualSelectionScore(self):
        refs = {"a": {"typed": "", "words": ["today"]}}
        search = {"ranking": "sum", "candidateTexts": ["today", "tomorrow"],
                  "candidateScores": [-1, -.5], "candidateLogProbabilities": [-1, -2.5],
                  "candidateFirstWordProbabilities": [.5, .4]}
        rows = [{"id": "a", "text": "today", "search": search}]
        self.assertEqual(audit(rows, refs)["scoreMarginBins"]["0.2+"]["count"], 1)
        search["ranking"] = "firstWord"
        self.assertEqual(audit(rows, refs)["scoreMarginBins"]["0.05-0.2"]["count"], 1)
        search.pop("candidateFirstWordProbabilities")
        with self.assertRaisesRegex(ValueError, "Missing scores"):
            audit(rows, refs)

    def testOracleRandomAndDedupStaySeparateFromTopOne(self):
        references = {"a": {"typed": "", "words": ["tomorrow"]}}
        rows = [{"id": "a", "text": "today", "search": {
            "candidateTexts": ["today", "today", "tomorrow"], "candidateScores": [-.5, -.6, -.9]}}]
        result = audit(rows, references)
        totals = result["totals"]
        self.assertEqual(totals["selectedMatches"], 0)
        self.assertEqual(totals["oracleMatches"], 1)
        self.assertEqual(totals["missedOracleSelections"], 1)
        self.assertAlmostEqual(totals["randomFinalistExpectedMatches"], 1 / 3)
        self.assertEqual(totals["dedupTopOneChanges"], 0)
        self.assertEqual(totals["duplicateNonemptyFinalists"], 1)
        self.assertTrue(result["missingDiagnostics"])

    def testSuppressionAndMidwordHaveCorrectDenominators(self):
        refs = {"a": {"typed": "", "words": ["later"]}, "b": {"typed": "tom", "words": ["tomorrow"]}}
        rows = [{"id": "a", "text": "", "cache": {"firstWordProbability": .04}}, {"id": "b", "text": "orrow"}]
        result = audit(rows, refs)
        self.assertEqual(result["totals"]["checkpoints"], 2)
        self.assertEqual(result["totals"]["selectedMatches"], 1)
        self.assertEqual(result["firstWordProbabilityBins"]["below-0.1"]["count"], 1)
        with self.assertRaises(ValueError):
            audit(rows[::-1], refs)


if __name__ == "__main__":
    unittest.main()
