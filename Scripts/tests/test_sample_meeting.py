import importlib.util
import io
import json
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SAMPLE = ROOT / "LokalBot/Resources/SampleMeeting"
spec = importlib.util.spec_from_file_location("sample_meeting", ROOT / "Scripts/sample_meeting.py")
sample_meeting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sample_meeting)

# Spoken language → the interface language whose strings carry its Ask question.
LANGUAGES = {"en": "en", "de": "de", "zh": "zh-Hans", "sr-Latn": "sr-Latn"}


def load(name):
    return json.loads((SAMPLE / name).read_text(encoding="utf-8"))


class SampleMeetingFilesTests(unittest.TestCase):
    def test_every_script_has_its_files(self):
        scripts = sorted(p.name.split(".", 1)[1].removesuffix(".json") for p in SAMPLE.glob("script.*.json"))
        self.assertEqual(scripts, sorted(LANGUAGES))

    def test_reference_matches_the_script_and_audio(self):
        for lang in LANGUAGES:
            with self.subTest(lang=lang):
                script, reference = load(f"script.{lang}.json"), load(f"reference.{lang}.json")
                audio = SAMPLE / script["audio"]
                self.assertTrue(audio.is_file())
                self.assertLess(audio.stat().st_size, 1_250_000, "keep the recording near 1 MB")
                self.assertEqual(reference["sampleID"], script["sampleID"])
                self.assertEqual([t["id"] for t in reference["turns"]], [t["id"] for t in script["turns"]])
                self.assertEqual([t["text"] for t in reference["turns"]], [t["text"] for t in script["turns"]])
                starts = [t["start"] for t in reference["turns"]]
                self.assertEqual(starts, sorted(starts))
                self.assertTrue(all(t["end"] > t["start"] for t in reference["turns"]))
                self.assertTrue(180 <= reference["duration"] <= 300, "3 to 5 minutes")

    def test_translations_keep_the_english_meeting(self):
        english, english_expected = load("script.en.json"), load("expected.en.json")
        shape = [(t["id"], t["speaker"]) for t in english["turns"]]
        for lang in LANGUAGES:
            with self.subTest(lang=lang):
                script, expected = load(f"script.{lang}.json"), load(f"expected.{lang}.json")
                self.assertEqual(script["sampleID"], f"orders-api/{lang}")
                self.assertEqual(script["language"], lang)
                self.assertEqual(script["audio"], f"orders-api.{lang}.m4a")
                self.assertIn(script["tts"]["provider"], sample_meeting.VOICE_SERVICES)
                self.assertEqual(len({s["voice"] for s in script["speakers"].values()}), 2, "two distinct voices")
                self.assertEqual(script["speakers"].keys(), english["speakers"].keys())
                self.assertEqual([(t["id"], t["speaker"]) for t in script["turns"]], shape)
                self.assertEqual([(e["kind"], e["turn"]) for e in expected["entities"]],
                                 [(e["kind"], e["turn"]) for e in english_expected["entities"]])
                for key in ("decision", "openQuestion"):
                    self.assertEqual(expected[key]["turns"], english_expected[key]["turns"])
                for key in ("beforeTurns", "afterTurns"):
                    self.assertEqual(expected["changedDecision"][key], english_expected["changedDecision"][key])
                self.assertEqual(expected["ask"]["citesTurns"], english_expected["ask"]["citesTurns"])
                self.assertEqual(len(expected["ask"]["answerPoints"]), len(english_expected["ask"]["answerPoints"]))
                text = " ".join(t["text"] for t in script["turns"])
                for identifier in ("delivery window", "ETA", "Orders API"):
                    self.assertIn(identifier, text)

    def test_ask_question_is_the_one_the_apps_suggest(self):
        catalogs = (ROOT / "LinuxWindows/crates/lokalbot-i18n/src/catalogs.rs").read_text(encoding="utf-8")
        english = load("expected.en.json")["ask"]["question"]
        for lang, interface in LANGUAGES.items():
            with self.subTest(lang=lang):
                question = load(f"expected.{lang}.json")["ask"]["question"]
                strings = (ROOT / f"LokalBot/Resources/{interface}.lproj/Localizable.strings").read_text(encoding="utf-8")
                mac = re.search(rf'^"{re.escape(english)}" = "(.*)";$', strings, re.M)
                self.assertIsNotNone(mac)
                self.assertEqual(mac.group(1), question)
                self.assertIn(f'("{english}", "{question}")', catalogs)

    def test_checklist_points_at_turns_that_say_it(self):
        for lang in LANGUAGES:
            with self.subTest(lang=lang):
                script, expected = load(f"script.{lang}.json"), load(f"expected.{lang}.json")
                turns = {t["id"]: t["text"].lower() for t in script["turns"]}
                self.assertEqual(expected["sampleID"], script["sampleID"])
                for entity in expected["entities"]:
                    self.assertIn(entity["turn"], turns)
                    self.assertTrue(any(v in turns[entity["turn"]] for v in entity["any"]),
                                    f"{entity['label']} is not said in {entity['turn']}")
                for key in ("decision", "openQuestion"):
                    self.assertTrue(set(expected[key]["turns"]) <= set(turns))
                changed = expected["changedDecision"]
                self.assertTrue(set(changed["beforeTurns"] + changed["afterTurns"]) <= set(turns))
                self.assertTrue(set(expected["ask"]["citesTurns"]) <= set(changed["afterTurns"]))


class ScoringTests(unittest.TestCase):
    SPOKEN_AND_WRITTEN = {
        "en": [
            ("forty-two partners", "42 partners"),
            ("November eighteenth", "November 18th"),
            ("release four point two", "release 4.2"),
            ("about a hundred and eighty milliseconds", "about 180 milliseconds"),
            ("two million open orders", "2,000,000 open orders"),
            ("p95 latency", "P 95 latency"),
        ],
        "de": [
            ("Zweiundvierzig Partner", "42 Partner"),
            ("bis zum achtzehnten November", "bis zum 18. November"),
            ("der achtzehnte November", "der 18. November"),
            ("statt bis zum achtzehnten.", "statt bis zum 18."),
            ("Neunzehn von zweiundvierzig. Das ist", "19 von 42. Das ist"),
            ("Release vier Punkt zwei", "Release 4.2"),
            ("etwa hundertachtzig Millisekunden", "etwa einhundertachtzig Millisekunden"),
            ("etwa hundertachtzig Millisekunden", "etwa 180 Millisekunden"),
            ("zwei Millionen offene Bestellungen", "2.000.000 offene Bestellungen"),
            ("die P95-Latenz", "die P 95 Latenz"),
        ],
        "sr-Latn": [
            ("Četrdeset dva partnera", "42 partnera"),
            ("do osamnaestog novembra", "do 18. novembra"),
            ("osamnaesti novembar", "18. novembar"),
            ("umesto do osamnaestog.", "umesto do 18."),
            ("Devetnaest od četrdeset dva. To je", "19 od 42. To je"),
            ("reliz četiri tačka dva", "reliz 4.2"),
            ("oko sto osamdeset milisekundi", "oko 180 milisekundi"),
            ("dva miliona otvorenih porudžbina", "2.000.000 otvorenih porudžbina"),
            ("Okej, P95 latencija", "ОК, П95 латенција"),
        ],
        "zh": [
            ("四十二个合作伙伴", "42个合作伙伴"),
            ("十一月十八号", "11月18号"),
            ("四点二版本", "4.2版本"),
            ("一百八十毫秒", "180毫秒"),
            ("两百万个未完成的订单", "200万个未完成的订单"),
            ("两百万个", "2,000,000个"),
            ("嗯。P95 延迟", "p95延迟"),
        ],
    }

    def test_spoken_and_written_numbers_agree(self):
        normalize = sample_meeting.normalize
        for lang, pairs in self.SPOKEN_AND_WRITTEN.items():
            for spoken, written in pairs:
                with self.subTest(lang=lang, written=written):
                    self.assertEqual(normalize(spoken, lang), normalize(written, lang))

    def check(self, lang, segments):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "transcript.json"
            path.write_text(json.dumps({"segments": segments}, ensure_ascii=False), encoding="utf-8")
            args = type("Args", (), {"lang": lang, "transcript": directory, "summary": None})
            out = io.StringIO()
            with redirect_stdout(out):
                sample_meeting.check(args)
        return out.getvalue()

    def test_the_reference_scores_perfectly_against_itself(self):
        for lang in LANGUAGES:
            with self.subTest(lang=lang):
                reference = load(f"reference.{lang}.json")
                segments = [{"start": t["start"], "end": t["end"], "speaker": t["speaker"], "text": t["text"]}
                            for t in reference["turns"]]
                report = self.check(lang, segments)
                self.assertIn(f"{'CER' if lang == 'zh' else 'WER'}: 0.0%", report)
                self.assertIn(f"{len(load(f'expected.{lang}.json')['entities'])}/", report)
                self.assertNotIn("✗", report)
                self.assertIn("100% of speech time on the right voice", report)

    def test_a_serbian_transcript_in_cyrillic_scores_like_latin(self):
        self.assertEqual(sample_meeting.normalize("Ћао, Данијеле. Четрдесет два партнера, 19 њих.", "sr-Latn"),
                         sample_meeting.normalize("Ćao, Danijele. Četrdeset dva partnera, devetnaest njih.", "sr-Latn"))

if __name__ == "__main__":
    unittest.main()
