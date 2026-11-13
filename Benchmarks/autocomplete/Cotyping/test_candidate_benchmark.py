import copy
from contextlib import redirect_stderr
import io
import unittest
from unittest.mock import patch

import quality_replay
from candidate_benchmark import summarize, validate_observations


class CandidateBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.references = {"a": {"phraseID": "p", "category": "work", "group": "public-word",
                                  "typed": "", "words": ["tomorrow", "morning"]}}
        self.control = [{"id": "a", "prompt": "See you ", "text": "today", "latencyMs": 10,
                         "usedPromptOverride": False, "decoderCandidates": 1}]
        self.candidate = copy.deepcopy(self.control)
        self.candidate[0].update(decoderCandidates=2, search={"width": 2, "peakActiveCandidates": 2,
                                                            "candidateTexts": ["today", "tomorrow morning"]})

    def testMismatchedPromptsAndWrongDecodersCannotBeCompared(self):
        validate_observations(self.candidate, self.references, 2, self.control)
        self.candidate[0]["prompt"] += "tomorrow"
        with self.assertRaisesRegex(ValueError, "prompt differs"):
            validate_observations(self.candidate, self.references, 2, self.control)
        with self.assertRaisesRegex(ValueError, "Wrong decoder"):
            validate_observations(self.control, self.references, 2)

    def testMissingNativeResultsErrorsAndIncompleteRunsFailClosed(self):
        self.candidate[0].pop("search")
        with self.assertRaisesRegex(ValueError, "Missing native"):
            validate_observations(self.candidate, self.references, 2)
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            validate_observations([], self.references, 1)
        self.control[0]["error"] = "decode failed"
        with self.assertRaisesRegex(ValueError, "failed request"):
            validate_observations(self.control, self.references, 1)

    def testOracleAlternativesAreNotCountedAsDisplayedQuality(self):
        result = summarize(self.candidate, self.references)["overall"]
        self.assertEqual(result["accuracy"], 0)
        self.assertEqual(result["incorrectShown"], 1)
        self.assertEqual(result["oracleFirstWordMatches"], 1)

    def testSuppressionRemainsInQualityDenominator(self):
        self.control[0].update(text="", suppression="lowConfidence")
        result = summarize(self.control, self.references)["overall"]
        self.assertEqual(result["checkpoints"], 1)
        self.assertEqual(result["accuracy"], 0)
        self.assertEqual(result["coverage"], 0)
        self.assertEqual(result["incorrectShown"], 0)

    def testNativeSearchCannotBeSilentlyIgnoredByRemoteCLI(self):
        for width in [2, 4]:
            arguments = ["quality_replay.py", "--app", __file__, "--corpus", __file__,
                         "--output", "unused-candidate-output", "--completions-url", "https://example.invalid/v1",
                         "--completions-model", "synthetic", "--api-key-env", "UNUSED_CANDIDATE_TEST_KEY",
                         "--decoder-candidates", str(width)]
            stderr = io.StringIO()
            with self.subTest(width=width), patch("sys.argv", arguments), redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as raised:
                    quality_replay.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("requires a local --model", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
