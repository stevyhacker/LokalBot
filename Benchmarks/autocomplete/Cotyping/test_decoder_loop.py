import unittest

from decoder_loop import add_character_references, confirmation_suite, metrics, paired_bootstrap


class DecoderLoopTests(unittest.TestCase):
    def testConfirmationRejectsOldTextAndKeepsReferencesOutOfInputs(self):
        phrase = {"id": "new", "category": "work", "text": "Please finish the revised schedule before lunch."}
        with self.assertRaisesRegex(ValueError, "reuses"):
            confirmation_suite({"phrases": [phrase]}, [dict(phrase, id="old")])
        cases, refs, selected = confirmation_suite({"phrases": [phrase]}, [])
        self.assertEqual(selected[0]["id"], "fresh-new")
        self.assertEqual([c["id"] for c in cases], list(refs))
        self.assertTrue(all("words" not in c and "category" not in c for c in cases))
        self.assertTrue(all("matchingCharacterCredits" in r for r in refs.values()))

    def testCharacterCreditStartsAtCaretAndRequiresWholeMatchingWords(self):
        refs = {"public-midword:p:1:3": {"phraseID": "p", "category": "work", "group": "midword",
                                              "typed": "tom", "words": ["tomorrow", "morning"]}}
        add_character_references(refs, [{"id": "p", "text": "Meet tomorrow morning"}])
        self.assertEqual(refs["public-midword:p:1:3"]["matchingCharacterCredits"], [5, 13])
        row = {"id": "public-midword:p:1:3", "text": "orrow evening", "latencyMs": 10}
        report = metrics([row], refs)
        self.assertEqual(report["overall"]["matchingCharacters"], 5)
        row["text"] = "ato morning"
        self.assertEqual(metrics([row], refs)["overall"]["matchingCharacters"], 0)
        row["text"] = ""
        self.assertEqual(metrics([row], refs)["overall"]["matchingCharacters"], 0)

    def testBootstrapCountsPhrasesAndKeepsPairedCasesTogether(self):
        control = [{"id": str(i), "phraseID": f"p{i // 2}", "correct": False,
                    "incorrectShown": 1, "matchingCharacters": 0} for i in range(6)]
        treatment = [dict(row, correct=True, incorrectShown=0, matchingCharacters=4) for row in control]
        result = paired_bootstrap(control, treatment, resamples=100)
        self.assertEqual(result["phrases"], 3)
        self.assertEqual(result["pairedPhraseBootstrap"]["matchingCharacters"]["ci95"], [4, 4])
        self.assertEqual(result["pairedPhraseBootstrap"]["incorrectShown"]["ci95"], [-1, -1])
        with self.assertRaisesRegex(ValueError, "Unpaired"):
            paired_bootstrap(control, treatment[::-1], resamples=100)
        with self.assertRaisesRegex(ValueError, "Unpaired"):
            paired_bootstrap(control, treatment[:-1], resamples=100)


if __name__ == "__main__":
    unittest.main()
