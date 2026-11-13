import unittest
from copy import deepcopy

from compare_cotabby import cotabby_observations
from quality_replay import checkpoints, predicted_words, score, selected_phrases


class QualityScoringTests(unittest.TestCase):
    def test_matches_exact_joined_word(self):
        self.assertEqual(predicted_words("ule tomorrow", "sched"), ["schedule", "tomorrow"])
        self.assertEqual(predicted_words(" ule tomorrow", "sched"), [])
        self.assertEqual(predicted_words("tomorrow", "tomor"), ["tomortomorrow"])
        self.assertEqual(predicted_words("... expected word"), [])
        self.assertEqual(predicted_words("can't wait"), ["can't", "wait"])
        self.assertEqual(predicted_words("can'"), [])
        self.assertEqual(predicted_words("high-quality"), ["high-quality"])

    def test_no_future_text_reaches_inference(self):
        phrases = [{"id": "a", "category": "work", "text": "Please send tomorrow",
                    "scenario": {"documentPrefix": "Dear Alex,\n", "screenText": "SECRET"}}]
        inputs, references = checkpoints(phrases, "word")
        self.assertEqual(inputs[0]["prefix"], "Dear Alex,\nPlease ")
        self.assertEqual(references["a:1:0"]["words"], ["send", "tomorrow"])
        self.assertNotIn("SECRET", str(inputs))
        self.assertNotIn("tomorrow", str(inputs))
        self.assertNotIn("expected", str(inputs))

    def test_suppression_and_errors_stay_in_denominator(self):
        references = {"a": {"phraseID": "p", "category": "work", "typed": "", "words": ["tomorrow"]},
                      "b": {"phraseID": "p", "category": "work", "typed": "", "words": ["today"]}}
        observations = [{"id": "a", "text": "tomorrow", "latencyMs": 4},
                        {"id": "b", "text": "", "latencyMs": 3}]
        self.assertEqual(score(observations, references)["overall"]["accuracy"], 0.5)
        with self.assertRaises(ValueError):
            score(observations[:1], references)

    def test_split_is_disjoint_and_stable(self):
        corpus = {"phrases": [{"id": str(i), "category": "work"} for i in range(80)]}
        screen = {p["id"] for p in selected_phrases(corpus, "screen")}
        heldout = {p["id"] for p in selected_phrases(corpus, "heldout")}
        self.assertEqual(len(screen), 20)
        self.assertFalse(screen & heldout)
        self.assertEqual(len(screen | heldout), 80)
        corpus["phrases"].reverse()
        self.assertEqual(screen, {p["id"] for p in selected_phrases(corpus, "screen")})


class CompetitorPairingTests(unittest.TestCase):
    def setUp(self):
        phrase = {"id": "a", "category": "work", "text": "Send tomorrow"}
        self.cases, self.references = checkpoints([phrase], "word")
        self.report = {"phrases": [{"condition": "none", "phrase": phrase, "observations": [{
            "checkpoint": {"prefix": "Send ", "wordIndex": 1, "typedCharacters": 0,
                           "expectedWord": "tomorrow"},
            "shown": "tomorrow", "correct": True, "latencyMilliseconds": 5,
        }]}]}

    def test_accepts_identical_checkpoints(self):
        observations = cotabby_observations(self.report, self.cases, self.references)
        self.assertEqual(score(observations, self.references)["overall"]["accuracy"], 1)

    def test_rejects_different_prefix_or_surface(self):
        altered = deepcopy(self.report)
        altered["phrases"][0]["observations"][0]["checkpoint"]["prefix"] = "Please send "
        with self.assertRaisesRegex(ValueError, "Different typed prefix"):
            cotabby_observations(altered, self.cases, self.references)
        altered = deepcopy(self.report)
        altered["phrases"][0]["phrase"]["scenario"] = {"windowTitle": "Different context"}
        with self.assertRaisesRegex(ValueError, "Different surface metadata"):
            cotabby_observations(altered, self.cases, self.references)

    def test_rejects_missing_and_duplicate_checkpoints(self):
        altered = deepcopy(self.report)
        altered["phrases"][0]["observations"] *= 2
        with self.assertRaisesRegex(ValueError, "duplicated checkpoint"):
            cotabby_observations(altered, self.cases, self.references)
        altered["phrases"][0]["observations"] = []
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            cotabby_observations(altered, self.cases, self.references)

    def test_rejects_scoring_disagreement(self):
        self.report["phrases"][0]["observations"][0]["correct"] = False
        with self.assertRaisesRegex(ValueError, "scorer disagrees"):
            cotabby_observations(self.report, self.cases, self.references)


if __name__ == "__main__":
    unittest.main()
