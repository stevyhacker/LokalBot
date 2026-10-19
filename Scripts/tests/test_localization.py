"""Keep the interface translation tables aligned and format-safe."""

import json
from pathlib import Path
import re
import unittest


APP = Path(__file__).resolve().parents[2] / "LokalBot"
RESOURCES = APP / "Resources"
LANGUAGES = sorted(path.parent.stem for path in RESOURCES.glob("*.lproj/Localizable.strings"))


def read_strings(language):
    entries = {}
    for line in (RESOURCES / f"{language}.lproj" / "Localizable.strings").read_text().splitlines():
        if not line.strip() or line.startswith("//"):
            continue
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
        if match is None:
            raise ValueError(f"Invalid translation entry: {line}")
        key, value = map(json.loads, match.groups())
        if key in entries:
            raise ValueError(f"Duplicate translation key: {key}")
        entries[key] = value
    return entries


class LocalizationTests(unittest.TestCase):
    def test_supported_languages_and_catalogs_stay_in_sync(self):
        declared = set(re.findall(r'case \w+ = "([^"]+)"', (APP / "Models/AppLanguage.swift").read_text()))
        self.assertEqual(set(LANGUAGES), declared)
        self.assertTrue({"en", "zh-Hans", "hi", "es", "ar", "fr", "bn", "pt", "id", "ur",
                         "ru", "de", "ja", "pcm", "ar-EG", "mr", "vi", "te", "sw", "ha", "ko",
                         "zh-Hant", "it", "sr-Latn"} <= declared)

    def test_languages_have_matching_nonempty_entries(self):
        english = read_strings("en")
        for language in LANGUAGES:
            with self.subTest(language=language):
                translated = read_strings(language)
                self.assertEqual(english.keys(), translated.keys())
                self.assertTrue(all(value.strip() for value in translated.values()))
        self.assertEqual(read_strings("zh-Hans")["App language"], "界面语言")
        # English must be available even when the Mac uses another language.
        self.assertEqual(english["Settings"], "Settings")

    def test_format_arguments_survive_translation(self):
        english = read_strings("en")
        placeholders = re.compile(r"%(?:\d+\$)?(?:lld|ld|[diufgs@%])")
        for language in LANGUAGES:
            translated = read_strings(language)
            for key, source in english.items():
                with self.subTest(language=language, key=key):
                    self.assertEqual(placeholders.findall(source), placeholders.findall(translated[key]))

    def test_line_breaks_and_direction_controls(self):
        english = read_strings("en")
        # Direction belongs to the view environment, never hidden overrides or
        # marks in copy. Machine translation most often inserts LRM, RLM and ALM.
        overrides = re.compile("[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]")
        for language in LANGUAGES:
            for key, value in read_strings(language).items():
                with self.subTest(language=language, key=key):
                    self.assertEqual(english[key].count("\n"), value.count("\n"))
                    self.assertIsNone(overrides.search(value))


if __name__ == "__main__":
    unittest.main()
