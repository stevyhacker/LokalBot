import unittest

from claude_judge import blind_case, bootstrap_delta, first_word, policies, preference_disagreements, validate_judgments


class ClaudeJudgeTests(unittest.TestCase):
    def testHybridKeepsCurrentAndOnlyTruncatesNewSuggestions(self):
        self.assertEqual(policies("worth it.", "")["hybrid_one_word"], "worth it.")
        self.assertEqual(policies("", "the .")["hybrid_one_word"], "the")
        self.assertEqual(policies("same text", "same text")["intersection"], "same text")
        with self.assertRaises(ValueError):
            policies("a", "b")

    def testWordCapPreservesUnicodeAndDoesNotInventText(self):
        for text, expected in [("рока, чак и", "рока"), ("I'm here", "I'm"),
                               ("  next-generation test", "  next-generation"), ("...", "")]:
            self.assertEqual(first_word(text), expected)

    def testBlindPacketExcludesReferencePolicyAndPhraseIdentity(self):
        case = {"id": "secret-phrase", "prefix": "Please ", "reference": "hidden future",
                "policies": policies("", "send it")}
        packet = blind_case(case)
        repeat = blind_case(case, True)
        self.assertEqual(set(packet), {"id", "prefix", "options"})
        self.assertNotIn("secret", str(packet))
        self.assertNotIn("hidden", str(packet))
        self.assertNotIn("hybrid", str(packet))
        self.assertNotEqual(packet["id"], repeat["id"])
        self.assertEqual([o["continuation"] for o in packet["options"]],
                         list(reversed([o["continuation"] for o in repeat["options"]])))

    def testMissingAndContradictoryRatingsAreRejected(self):
        packet = {"cases": [{"id": "q", "options": [{"id": "o1", "continuation": "word"}]}]}
        rating = {"id": "o1", "utility": -1, "first_word": 1, "flags": [], "reason": "Weak."}
        result = {"cases": [{"id": "q", "ratings": [rating], "preferred": ["none"]}]}
        self.assertEqual(validate_judgments(packet, result), result)
        result["cases"][0]["preferred"] = ["o1"]
        with self.assertRaises(ValueError):
            validate_judgments(packet, result)
        self.assertEqual(validate_judgments(packet, result, strict_preference=False), result)
        self.assertEqual(preference_disagreements(result), [{"id": "q", "reportedPreferred": ["o1"], "preferredFromUtility": ["none"]}])
        self.assertEqual(result["cases"][0]["ratings"][0]["utility"], -1)
        with self.assertRaises(ValueError):
            validate_judgments(packet, {"cases": []})

    def testBootstrapIncludesUnchangedCasesAsZeroDelta(self):
        cases = [{"id": "a", "phraseID": "p", "kind": "newly_shown"},
                 {"id": "b", "phraseID": "p", "kind": "unchanged"}]
        scores = {"a": {"current": {"utility": 0}, "union": {"utility": 2}}}
        result = bootstrap_delta(cases, scores, "union", samples=100)
        self.assertEqual(result["deltaPerCheckpoint"], 1)
        self.assertEqual(result["ci95"], [1, 1])


if __name__ == "__main__":
    unittest.main()
